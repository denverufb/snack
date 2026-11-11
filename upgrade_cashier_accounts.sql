-- Panther Pantry: administrator-managed student cashier accounts and audit views.
-- Run once in Supabase SQL Editor AFTER ADMIN_UPGRADE_RUN_ONCE.sql.
-- This migration does not create Auth users by itself. Deploy the accompanying
-- create-cashier Edge Function after running it; see CASHIER_SETUP.md.
BEGIN;

DO $prerequisites$
BEGIN
  IF to_regprocedure('public.is_pantry_admin()') IS NULL
     OR to_regprocedure('public.checkout_snack_v2(text,text,uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION 'Run ADMIN_UPGRADE_RUN_ONCE.sql before this migration';
  END IF;
END;
$prerequisites$;

ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS email text;
CREATE UNIQUE INDEX IF NOT EXISTS staff_email_unique
  ON public.staff (lower(email)) WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS transactions_cashier_purchase_recent
  ON public.transactions (staff_id,created_at DESC) WHERE kind='purchase';
CREATE INDEX IF NOT EXISTS pantry_tab_cashier_purchase_recent
  ON public.pantry_tab_charges (staff_id,created_at DESC);

-- At most 15 regular cashier accounts can be active at one time. The
-- administrator is not counted. Disabled cashiers retain their audit history.
CREATE OR REPLACE FUNCTION public.enforce_active_cashier_limit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE active_cashiers integer;
BEGIN
  IF NEW.role='staff' AND NEW.active THEN
    IF TG_OP='UPDATE' AND OLD.role='staff' AND OLD.active THEN
      RETURN NEW;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('pantry-active-cashiers')::bigint);
    SELECT count(*) INTO active_cashiers
    FROM public.staff
    WHERE role='staff' AND active
      AND id<>NEW.id;
    IF active_cashiers>=15 THEN
      RAISE EXCEPTION 'All 15 active cashier account slots are in use';
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS staff_active_cashier_limit ON public.staff;
CREATE TRIGGER staff_active_cashier_limit
  BEFORE INSERT OR UPDATE ON public.staff
  FOR EACH ROW EXECUTE FUNCTION public.enforce_active_cashier_limit();
REVOKE ALL ON FUNCTION public.enforce_active_cashier_limit() FROM PUBLIC,anon,authenticated;

-- Summary used by the Admin tab. Purchase totals include valid point sales and
-- valid administrator-tab sales, attributed to the signed-in cashier staff_id.
CREATE OR REPLACE FUNCTION public.get_admin_cashiers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE result jsonb;
BEGIN
  IF NOT public.is_pantry_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
  WITH sale_events AS (
    SELECT t.staff_id,t.created_at,
      coalesce(t.sale_price,(-t.delta_points)::numeric) AS amount
    FROM public.transactions t
    WHERE t.kind='purchase' AND t.archived_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.transactions r
        WHERE r.kind='refund' AND r.archived_at IS NULL
          AND r.related_transaction_id=t.id
      )
    UNION ALL
    SELECT c.staff_id,c.created_at,c.amount
    FROM public.pantry_tab_charges c
    WHERE c.voided_at IS NULL
  ),
  sale_stats AS (
    SELECT staff_id,count(*)::integer AS purchase_count,
      coalesce(sum(amount),0)::numeric AS sales_total,
      max(created_at) AS last_sale
    FROM sale_events WHERE staff_id IS NOT NULL GROUP BY staff_id
  ),
  cashier_rows AS (
    SELECT s.id,s.display_name,s.email,s.active,s.created_at,
      coalesce(x.purchase_count,0) AS purchase_count,
      coalesce(x.sales_total,0) AS sales_total,x.last_sale
    FROM public.staff s LEFT JOIN sale_stats x ON x.staff_id=s.id
    WHERE s.role='staff'
  )
  SELECT jsonb_build_object(
    'limit',15,
    'active_count',(SELECT count(*) FROM public.staff WHERE role='staff' AND active),
    'cashiers',coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id',id,'display_name',display_name,'email',email,'active',active,
        'created_at',created_at,'purchase_count',purchase_count,
        'sales_total',round(sales_total,2),'last_sale',last_sale
      ) ORDER BY active DESC,display_name ASC)
      FROM cashier_rows
    ),'[]'::jsonb)
  ) INTO result;
  RETURN result;
END;
$fn$;

-- Detailed, immutable cashier audit view. Removed and refunded sales remain
-- visible here with their status even when excluded from finance totals.
CREATE OR REPLACE FUNCTION public.get_admin_cashier_purchases(
  p_staff_id uuid,p_limit integer DEFAULT 250
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE cashier_name text; result jsonb; row_limit integer;
BEGIN
  IF NOT public.is_pantry_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
  SELECT display_name INTO cashier_name
  FROM public.staff WHERE id=p_staff_id AND role='staff';
  IF NOT FOUND THEN RAISE EXCEPTION 'Cashier account not found'; END IF;
  row_limit:=greatest(1,least(coalesce(p_limit,250),500));

  WITH purchases AS (
    SELECT t.id,t.created_at,
      coalesce(st.full_name,'Removed student') AS student_name,
      coalesce(sn.name,nullif(t.note,''),'Removed snack') AS snack_name,
      coalesce(t.sale_price,(-t.delta_points)::numeric) AS amount,
      'points'::text AS payment_type,
      CASE
        WHEN t.archived_at IS NOT NULL THEN 'removed'
        WHEN EXISTS (
          SELECT 1 FROM public.transactions r
          WHERE r.kind='refund' AND r.archived_at IS NULL
            AND r.related_transaction_id=t.id
        ) THEN 'refunded'
        ELSE 'completed'
      END AS status
    FROM public.transactions t
    LEFT JOIN public.students st ON st.id=t.student_id
    LEFT JOIN public.snacks sn ON sn.id=t.snack_id
    WHERE t.kind='purchase' AND t.staff_id=p_staff_id
    UNION ALL
    SELECT c.id,c.created_at,
      coalesce(st.full_name,'Administrator account') AS student_name,
      c.snack_name, c.amount,'admin tab'::text AS payment_type,
      CASE WHEN c.voided_at IS NULL THEN 'completed' ELSE 'removed' END AS status
    FROM public.pantry_tab_charges c
    LEFT JOIN public.students st ON st.id=c.admin_student_id
    WHERE c.staff_id=p_staff_id
  ),
  limited AS (
    SELECT * FROM purchases ORDER BY created_at DESC LIMIT row_limit
  )
  SELECT jsonb_build_object(
    'cashier',jsonb_build_object('id',p_staff_id,'display_name',cashier_name),
    'purchases',coalesce(jsonb_agg(jsonb_build_object(
      'id',id,'created_at',created_at,'student_name',student_name,
      'snack_name',snack_name,'amount',round(amount,2),
      'payment_type',payment_type,'status',status
    ) ORDER BY created_at DESC),'[]'::jsonb)
  ) INTO result FROM limited;
  RETURN result;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.set_cashier_active(
  p_staff_id uuid,p_active boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE cashier public.staff;
BEGIN
  IF NOT public.is_pantry_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
  IF p_active IS NULL THEN RAISE EXCEPTION 'Choose active or disabled'; END IF;
  UPDATE public.staff SET active=p_active
  WHERE id=p_staff_id AND role='staff'
  RETURNING * INTO cashier;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cashier account not found'; END IF;
  RETURN jsonb_build_object(
    'id',cashier.id,'display_name',cashier.display_name,'active',cashier.active
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.get_admin_cashiers() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_admin_cashier_purchases(uuid,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.set_cashier_active(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_admin_cashiers() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_cashier_purchases(uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_cashier_active(uuid,boolean) TO authenticated;

COMMIT;

SELECT count(*) AS active_cashiers,15 AS active_cashier_limit
FROM public.staff WHERE role='staff' AND active;
