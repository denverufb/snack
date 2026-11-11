-- Panther Pantry: read-only Activity and Finances access for Krish Patel.
-- Supabase Auth UUID: dfe4bf1b-feae-4fcf-b7c9-7ce039e3ab18
--
-- Run this once in Supabase SQL Editor AFTER ADMIN_UPGRADE_RUN_ONCE.sql.
-- Krish remains regular staff. This does not grant the Admin tab, account-mode
-- controls, snack/student editing, stock changes, or any removal RPC.
BEGIN;

DO $prerequisites$
BEGIN
  IF to_regprocedure('public.is_pantry_admin()') IS NULL
     OR to_regprocedure('public.get_pantry_role()') IS NULL
     OR to_regprocedure('public.get_snack_finances()') IS NULL THEN
    RAISE EXCEPTION 'Run ADMIN_UPGRADE_RUN_ONCE.sql before this migration';
  END IF;
END;
$prerequisites$;

-- The auth.users foreign key makes the transaction fail safely if this UUID
-- does not exist in the current Supabase project.
INSERT INTO public.staff(id,display_name,active,role)
VALUES (
  'dfe4bf1b-feae-4fcf-b7c9-7ce039e3ab18'::uuid,
  'Krish Patel',
  true,
  'staff'
)
ON CONFLICT(id) DO UPDATE
SET display_name='Krish Patel',active=true,role='staff';

CREATE TABLE IF NOT EXISTS public.pantry_staff_permissions (
  staff_id uuid PRIMARY KEY REFERENCES public.staff(id) ON DELETE CASCADE,
  can_view_activity boolean NOT NULL DEFAULT false,
  can_view_finances boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pantry_staff_permissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pantry_staff_permissions FROM PUBLIC,anon,authenticated;

INSERT INTO public.pantry_staff_permissions(
  staff_id,can_view_activity,can_view_finances,updated_at
)
VALUES (
  'dfe4bf1b-feae-4fcf-b7c9-7ce039e3ab18'::uuid,true,true,now()
)
ON CONFLICT(staff_id) DO UPDATE
SET can_view_activity=EXCLUDED.can_view_activity,
    can_view_finances=EXCLUDED.can_view_finances,
    updated_at=now();

CREATE OR REPLACE FUNCTION public.can_view_pantry_activity()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
  SELECT public.is_pantry_admin() OR EXISTS (
    SELECT 1
    FROM public.staff s
    JOIN public.pantry_staff_permissions p ON p.staff_id=s.id
    WHERE s.id=auth.uid() AND s.active AND s.role='staff'
      AND p.can_view_activity
  );
$fn$;

CREATE OR REPLACE FUNCTION public.can_view_pantry_finances()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
  SELECT public.is_pantry_admin() OR EXISTS (
    SELECT 1
    FROM public.staff s
    JOIN public.pantry_staff_permissions p ON p.staff_id=s.id
    WHERE s.id=auth.uid() AND s.active AND s.role='staff'
      AND p.can_view_finances
  );
$fn$;

REVOKE ALL ON FUNCTION public.can_view_pantry_activity() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.can_view_pantry_finances() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_view_pantry_activity() TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_view_pantry_finances() TO authenticated;

-- Activity uses direct SELECTs, so RLS is the server-side enforcement point.
DROP POLICY IF EXISTS staff_transactions_read ON public.transactions;
DROP POLICY IF EXISTS admin_transactions_read ON public.transactions;
DROP POLICY IF EXISTS pantry_activity_transactions_read ON public.transactions;
CREATE POLICY pantry_activity_transactions_read ON public.transactions
  FOR SELECT TO authenticated
  USING (public.can_view_pantry_activity());

-- Return UI capabilities without changing the user's staff role.
CREATE OR REPLACE FUNCTION public.get_pantry_role()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE admin_access boolean;
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff account required'; END IF;
  admin_access:=public.is_pantry_admin();
  RETURN jsonb_build_object(
    'role',CASE WHEN admin_access THEN 'admin' ELSE 'staff' END,
    'can_view_activity',public.can_view_pantry_activity(),
    'can_view_finances',public.can_view_pantry_finances()
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.get_pantry_role() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pantry_role() TO authenticated;

-- Finances are returned only through this checked SECURITY DEFINER RPC. Direct
-- access to administrator tab-ledger tables remains administrator-only by RLS.
CREATE OR REPLACE FUNCTION public.get_snack_finances()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE report jsonb;
BEGIN
 IF NOT public.can_view_pantry_finances() THEN RAISE EXCEPTION 'Finance access required'; END IF;
 WITH sales AS (
   SELECT t.id, t.snack_id,
      coalesce(t.sale_price,(-t.delta_points)::numeric) AS revenue,
      coalesce(t.unit_cost_at_sale,
        CASE WHEN sn.pack_size>0 THEN round(sn.pack_cost/sn.pack_size,4)
          ELSE NULL END) AS unit_cost,
      (t.unit_cost_at_sale IS NULL AND sn.pack_size>0
        AND sn.pack_cost IS NOT NULL) AS estimated
   FROM public.transactions t
   LEFT JOIN public.snacks sn ON sn.id=t.snack_id
   WHERE t.kind='purchase' AND t.archived_at IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.transactions r
       WHERE r.kind='refund' AND r.archived_at IS NULL
         AND r.related_transaction_id=t.id
     )
   UNION ALL
   SELECT c.id,c.snack_id,c.amount,c.unit_cost,false
   FROM public.pantry_tab_charges c
   WHERE c.voided_at IS NULL
 ),
 totals AS (
   SELECT count(*)::integer AS units,
      coalesce(sum(revenue),0)::numeric AS revenue,
      coalesce(sum(unit_cost),0)::numeric AS costs,
      count(*) FILTER (WHERE unit_cost IS NULL)::integer AS unknown_cost_sales,
      count(*) FILTER (WHERE estimated)::integer AS legacy_sales
   FROM sales
 ),
 inventory AS (
  SELECT coalesce(sum(stock*pack_cost/nullif(pack_size,0)),0)::numeric AS cost,
         coalesce(sum(stock*price),0)::numeric AS retail,
         count(*) FILTER (
           WHERE stock IS NULL OR pack_cost IS NULL OR pack_size IS NULL
         )::integer AS incomplete
  FROM public.snacks WHERE active=true
 ),
 reloads AS (
  SELECT coalesce(sum(delta_points),0)::numeric AS cash
  FROM public.transactions WHERE kind='reload' AND archived_at IS NULL
 ),
 tab_totals AS (
  SELECT
    (SELECT coalesce(sum(amount),0) FROM public.pantry_tab_charges
       WHERE voided_at IS NULL)::numeric AS charged,
    (SELECT coalesce(sum(amount),0) FROM public.pantry_tab_payments
       WHERE voided_at IS NULL)::numeric AS collected
 ),
 popularity AS (
  SELECT sn.id,sn.barcode,sn.name,sn.stock,sn.price,sn.fbla_price,
      sn.pack_cost,sn.pack_size,count(s.id)::integer AS sold,
      coalesce(sum(s.revenue),0)::numeric AS revenue,
      coalesce(sum(s.unit_cost),0)::numeric AS cost_sold,
      count(s.id) FILTER(WHERE s.unit_cost IS NULL)::integer AS unknown_cost_sales
  FROM public.snacks sn LEFT JOIN sales s ON s.snack_id=sn.id
  GROUP BY sn.id
 ),
 products AS (
  SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',id,'barcode',barcode,'name',name,'stock',stock,'price',price,
   'fbla_price',fbla_price,'pack_cost',pack_cost,'pack_size',pack_size,
   'sold',sold,'revenue',round(revenue,2),
   'gross_profit',round(revenue-cost_sold,2),
   'unknown_cost_sales',unknown_cost_sales
  ) ORDER BY sold DESC,name ASC),'[]'::jsonb) AS rows
  FROM popularity
 )
 SELECT jsonb_build_object(
  'units_sold',totals.units,
  'sales_revenue',round(totals.revenue,2),
  'cost_of_goods',round(totals.costs,2),
  'gross_profit',round(totals.revenue-totals.costs,2),
  'unknown_cost_sales',totals.unknown_cost_sales,
  'estimated_legacy_sales',totals.legacy_sales,
  'reload_cash',round(reloads.cash,2),
  'tab_charges',round(tab_totals.charged,2),
  'tab_payments',round(tab_totals.collected,2),
  'tab_balance',round(tab_totals.charged-tab_totals.collected,2),
  'inventory_cost',round(inventory.cost,2),
  'inventory_retail',round(inventory.retail,2),
  'unvalued_products',inventory.incomplete,
  'products',products.rows
 ) INTO report
 FROM totals CROSS JOIN reloads CROSS JOIN inventory
 CROSS JOIN tab_totals CROSS JOIN products;
 RETURN report;
END;
$fn$;
REVOKE ALL ON FUNCTION public.get_snack_finances() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_snack_finances() TO authenticated;

COMMIT;

-- Expected result: role=staff and both view permissions=true.
SELECT s.id,s.display_name,s.role,s.active,
       p.can_view_activity,p.can_view_finances
FROM public.staff s
JOIN public.pantry_staff_permissions p ON p.staff_id=s.id
WHERE s.id='dfe4bf1b-feae-4fcf-b7c9-7ce039e3ab18'::uuid;
