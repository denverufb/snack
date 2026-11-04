-- Panther Pantry: preserve audit history but hide test transactions from
-- Activity and finance totals. Run AFTER the finance, catalog, and PIN SQL.
-- No transactions are automatically hidden when this file is installed.
BEGIN;
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS archived_by uuid;
CREATE INDEX IF NOT EXISTS transactions_visible_recent_idx
  ON public.transactions (created_at DESC) WHERE archived_at IS NULL;

CREATE OR REPLACE FUNCTION snack_private.require_activity_pin(p_pin text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $pin$
DECLARE v_salt text; v_hash bytea;
BEGIN
  IF auth.uid() IS DISTINCT FROM '2d8cbbb9-e980-48bf-96bd-de29acbf5473'::uuid
     OR NOT public.is_staff() THEN
    RAISE EXCEPTION 'Only the original administrator can remove activity';
  END IF;
  SELECT salt,pin_hash INTO v_salt,v_hash
  FROM snack_private.void_pin WHERE id=1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Set the administrator PIN in Supabase first'; END IF;
  IF p_pin IS NULL OR
     v_hash IS DISTINCT FROM sha256(convert_to(v_salt||p_pin,'UTF8')) THEN
    RAISE EXCEPTION 'Incorrect administrator PIN';
  END IF;
END;
$pin$;
REVOKE ALL ON FUNCTION snack_private.require_activity_pin(text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.remove_activity_entry(
 p_transaction_id uuid, p_pin text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $fn$
DECLARE v_tx public.transactions;
BEGIN
  PERFORM snack_private.require_activity_pin(p_pin);
  UPDATE public.transactions
  SET archived_at=COALESCE(archived_at,now()),
      archived_by=COALESCE(archived_by,auth.uid())
  WHERE id=p_transaction_id
  RETURNING * INTO v_tx;
  IF NOT FOUND THEN RAISE EXCEPTION 'Activity entry not found'; END IF;
  RETURN jsonb_build_object('removed',true,'id',v_tx.id,'type',v_tx.kind);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.preview_activity_cleanup(
 p_keep_student_name text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $fn$
DECLARE v_keep integer; v_remove integer;
BEGIN
  IF auth.uid() IS DISTINCT FROM '2d8cbbb9-e980-48bf-96bd-de29acbf5473'::uuid
    OR NOT public.is_staff() THEN
    RAISE EXCEPTION 'Administrator access required';
  END IF;
  IF length(trim(coalesce(p_keep_student_name,''))) < 2 THEN
    RAISE EXCEPTION 'Enter the exact saved student full name';
  END IF;
  SELECT count(*) FILTER (
     WHERE EXISTS (SELECT 1 FROM public.students s
        WHERE s.id=t.student_id AND
        lower(trim(s.full_name))=lower(trim(p_keep_student_name)))
   ),
   count(*) FILTER (
     WHERE NOT EXISTS (SELECT 1 FROM public.students s
        WHERE s.id=t.student_id AND
        lower(trim(s.full_name))=lower(trim(p_keep_student_name)))
   )
  INTO v_keep,v_remove
  FROM public.transactions t WHERE t.archived_at IS NULL;
  RETURN jsonb_build_object('kept',v_keep,'would_remove',v_remove);
END;
$fn$;

-- Bulk clean-up runs only when there are EXACTLY three unarchived
-- transactions for the entered student name. Otherwise nothing changes.
CREATE OR REPLACE FUNCTION public.keep_only_three_activity(
 p_keep_student_name text, p_pin text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $fn$
DECLARE v_keep integer; v_removed integer;
BEGIN
  PERFORM snack_private.require_activity_pin(p_pin);
  SELECT count(*) INTO v_keep FROM public.transactions t
  JOIN public.students s ON s.id=t.student_id
  WHERE t.archived_at IS NULL
    AND lower(trim(s.full_name))=lower(trim(coalesce(p_keep_student_name,'')));
  IF v_keep <> 3 THEN
     RAISE EXCEPTION 'Found % active records with that exact name, not 3. Nothing removed.',v_keep;
  END IF;
  UPDATE public.transactions t
     SET archived_at=now(),archived_by=auth.uid()
  WHERE t.archived_at IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.students s
      WHERE s.id=t.student_id
      AND lower(trim(s.full_name))=lower(trim(p_keep_student_name))
    );
  GET DIAGNOSTICS v_removed=ROW_COUNT;
  RETURN jsonb_build_object('retained',v_keep,'removed',v_removed);
END;
$fn$;

-- Recover mistakenly hidden records (SQL Editor only; no public button).
CREATE OR REPLACE FUNCTION public.restore_activity_entry(
 p_transaction_id uuid,p_pin text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $fn$
BEGIN
  PERFORM snack_private.require_activity_pin(p_pin);
  UPDATE public.transactions SET archived_at=NULL,archived_by=NULL
  WHERE id=p_transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  RETURN jsonb_build_object('restored',true);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.set_snack_stock_count(
 p_barcode text,p_stock integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $fn$
DECLARE v_snack public.snacks;
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
  IF p_stock IS NULL OR p_stock NOT BETWEEN 0 AND 100000 THEN
    RAISE EXCEPTION 'Enter an actual stock count from 0 to 100000';
  END IF;
  UPDATE public.snacks SET stock=p_stock, updated_at=now()
  WHERE barcode=trim(p_barcode) RETURNING * INTO v_snack;
  IF NOT FOUND THEN RAISE EXCEPTION 'Snack not found'; END IF;
  RETURN jsonb_build_object('barcode',v_snack.barcode,
    'name',v_snack.name,'stock',v_snack.stock);
END;
$fn$;

-- Cross-reference the supplied pack costs and original sell prices.
-- This does NOT reset stock to the pack count; stock is live inventory.
WITH catalog (label, pack_qty, pack_total, sale_points) AS (
  VALUES
 ('Pringles',27,13.98::numeric,1),
 ('Nerd Clusters',24,29.53::numeric,2),
 ('Rice Krispies',40,10.99::numeric,1),
 ('Mothers Circus',30,15.64::numeric,1),
 ('Miss Vickies',28,18.49::numeric,2),
 ('Goldfish',30,15.99::numeric,1),
 ('Chip Pack',40,22.43::numeric,2),
 ('Gushers',42,22.95::numeric,2),
 ('Welches',80,16.00::numeric,1),
 ('Veggie Straw',24,32.00::numeric,2),
 ('Oreo',60,18.65::numeric,1),
 ('Skinny Pop',30,18.20::numeric,1),
 ('Yoggies',30,23.99::numeric,1),
 ('Skittles and Starbursts',30,27.99::numeric,2),
 ('Blakes Bars',24,29.99::numeric,2)
),
aliases(alias,canonical) AS (
 VALUES
 ('nerdsclusters','nerdclusters'),
 ('nerdsgummyclusters','nerdclusters'),
 ('ricekrispiestreats','ricekrispies'),
 ('motherscircuscookies','motherscircus'),
 ('missvickieschips','missvickies'),
 ('welchs','welches'),
 ('welchsfruitsnacks','welches'),
 ('veggiestraws','veggiestraw'),
 ('oreocookies','oreo'),
 ('blakesseedbars','blakesbars')
)
UPDATE public.snacks s SET
 pack_size=c.pack_qty,
 pack_cost=c.pack_total,
 price=c.sale_points,
 updated_at=now()
FROM catalog c
WHERE regexp_replace(lower(c.label),'[^a-z0-9]','','g') =
 coalesce(
  (SELECT a.canonical FROM aliases a
   WHERE a.alias=regexp_replace(lower(s.name),'[^a-z0-9]','','g')
   LIMIT 1),
  regexp_replace(lower(s.name),'[^a-z0-9]','','g')
 );

-- Reporting excludes hidden test purchases and hidden cash reload entries.
CREATE OR REPLACE FUNCTION public.get_snack_finances()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE result jsonb;
BEGIN
 IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
 WITH valid_sales AS (
   SELECT t.*, s.name AS current_name, s.pack_cost, s.pack_size,
     coalesce(t.sale_price,(-t.delta_points)::numeric) AS revenue,
     coalesce(t.unit_cost_at_sale,
       CASE WHEN s.pack_size > 0 THEN round(s.pack_cost/s.pack_size,4) ELSE NULL END
     ) AS cost_per_unit
   FROM public.transactions t
   LEFT JOIN public.snacks s ON s.id=t.snack_id
   WHERE t.kind='purchase' AND t.archived_at IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.transactions r
       WHERE r.kind='refund' AND r.related_transaction_id=t.id
     )
 ),
 totals AS (
   SELECT count(*)::integer AS units,
     coalesce(sum(revenue),0)::numeric AS sales,
     coalesce(sum(cost_per_unit),0)::numeric AS cogs,
     count(*) FILTER (WHERE cost_per_unit IS NULL)::integer AS unknown_cost_sales,
     count(*) FILTER (WHERE unit_cost_at_sale IS NULL AND cost_per_unit IS NOT NULL)::integer AS estimated_legacy_sales
   FROM valid_sales
 ),
 cash AS (
   SELECT coalesce(sum(delta_points),0)::numeric AS reloaded
   FROM public.transactions WHERE kind='reload' AND archived_at IS NULL
 ),
 inventory AS (
   SELECT coalesce(sum(stock * pack_cost / nullif(pack_size,0)),0)::numeric AS cost,
     coalesce(sum(stock * price),0)::numeric AS retail,
     count(*) FILTER (WHERE stock IS NULL OR pack_cost IS NULL OR pack_size IS NULL)::integer AS unvalued_products
   FROM public.snacks WHERE active=true
 ),
 popularity AS (
   SELECT s.id, s.name, s.barcode, s.stock, s.price,
     s.fbla_price, s.pack_cost, s.pack_size,
     count(v.id)::integer AS units_sold,
     coalesce(sum(v.revenue),0)::numeric AS revenue,
     coalesce(sum(v.cost_per_unit),0)::numeric AS cost_sold,
     count(v.id) FILTER (WHERE v.cost_per_unit IS NULL)::integer AS unknown_cost_sales
   FROM public.snacks s LEFT JOIN valid_sales v ON v.snack_id=s.id
   GROUP BY s.id
 ),
 entries AS (
   SELECT coalesce(jsonb_agg(jsonb_build_object(
       'id',id,'name',name,'barcode',barcode,'stock',stock,'price',price,
       'fbla_price',fbla_price,'pack_cost',pack_cost,'pack_size',pack_size,
       'sold',units_sold,'revenue',round(revenue,2),
       'gross_profit',round(revenue-cost_sold,2),
       'unknown_cost_sales',unknown_cost_sales
     ) ORDER BY units_sold DESC,name ASC),'[]'::jsonb) AS products
   FROM popularity
 )
 SELECT jsonb_build_object(
   'units_sold',totals.units,
   'sales_revenue',round(totals.sales,2),
   'cost_of_goods',round(totals.cogs,2),
   'gross_profit',round(totals.sales-totals.cogs,2),
   'unknown_cost_sales',totals.unknown_cost_sales,
   'estimated_legacy_sales',totals.estimated_legacy_sales,
   'reload_cash',cash.reloaded,
   'inventory_cost',round(inventory.cost,2),
   'inventory_retail',round(inventory.retail,2),
   'unvalued_products',inventory.unvalued_products,
   'products',entries.products
 ) INTO result
 FROM totals CROSS JOIN cash CROSS JOIN inventory CROSS JOIN entries;
 RETURN result;
END;
$$;


REVOKE ALL ON FUNCTION public.remove_activity_entry(uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.preview_activity_cleanup(text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.keep_only_three_activity(text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.restore_activity_entry(uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.set_snack_stock_count(text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.remove_activity_entry(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preview_activity_cleanup(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.keep_only_three_activity(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_activity_entry(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_snack_stock_count(text,integer) TO authenticated;
COMMIT;

-- Verify actual current stock and calculated unit costs.
SELECT name,barcode,pack_size AS items_per_pack,pack_cost AS pack_purchase_price,
 round(pack_cost/nullif(pack_size,0),4) AS cost_per_unit,
 price AS sell_price_points,stock AS current_stock
FROM public.snacks ORDER BY name;
