-- Financial reporting includes ordinary point purchases AND unpaid/paid
-- administrator tab purchases exactly once, excluding archived or voided sales.
-- Run AFTER upgrade_admin_tab_checkout.sql and upgrade_admin_barcode_removals.sql.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_snack_finances()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE report jsonb;
BEGIN
 IF NOT public.is_pantry_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
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
