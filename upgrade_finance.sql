-- Snack Pass finance, inventory, student management and FBLA pricing upgrade.
-- RUN ONCE in Supabase SQL Editor BEFORE using the new web controls.
-- Existing students, snacks, points, purchases and staff are retained.
-- Staff-only operations; do not put database secret/service role keys on GitHub.
BEGIN;

ALTER TABLE public.snacks
  ADD COLUMN IF NOT EXISTS pack_cost numeric(12,2),
  ADD COLUMN IF NOT EXISTS pack_size integer,
  ADD COLUMN IF NOT EXISTS fbla_price integer;
ALTER TABLE public.snacks
  DROP CONSTRAINT IF EXISTS snacks_pack_cost_valid;
ALTER TABLE public.snacks
  ADD CONSTRAINT snacks_pack_cost_valid CHECK (pack_cost IS NULL OR pack_cost >= 0);
ALTER TABLE public.snacks
  DROP CONSTRAINT IF EXISTS snacks_pack_size_valid;
ALTER TABLE public.snacks
  ADD CONSTRAINT snacks_pack_size_valid CHECK (pack_size IS NULL OR pack_size > 0);
ALTER TABLE public.snacks
  DROP CONSTRAINT IF EXISTS snacks_fbla_price_valid;
ALTER TABLE public.snacks
  ADD CONSTRAINT snacks_fbla_price_valid CHECK (fbla_price IS NULL OR fbla_price IN (1,2));

ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS sale_price numeric(12,2),
  ADD COLUMN IF NOT EXISTS unit_cost_at_sale numeric(12,4);

-- Remove a student without erasing anonymous, financial transaction totals.
ALTER TABLE public.transactions ALTER COLUMN student_id DROP NOT NULL;
ALTER TABLE public.transactions DROP CONSTRAINT IF EXISTS transactions_student_id_fkey;
ALTER TABLE public.transactions ADD CONSTRAINT transactions_student_id_fkey
  FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE SET NULL;

-- Cost from PACK TOTAL / PACK COUNT (not rounded Cost/Ct estimates).
-- Only fill missing fields on EXISTING snacks with a matching name.
WITH catalog(name, pack_size, pack_cost, sell_points) AS (
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
)
UPDATE public.snacks s
SET pack_size = COALESCE(s.pack_size,c.pack_size),
    pack_cost = COALESCE(s.pack_cost,c.pack_cost),
    fbla_price = COALESCE(s.fbla_price, LEAST(s.price,1)),
    updated_at = now()
FROM catalog c
WHERE lower(regexp_replace(s.name,'[^a-z0-9]','','g')) =
      lower(regexp_replace(c.name,'[^a-z0-9]','','g'));

-- Existing non-catalog snacks can also use 1 point as the FBLA price,
-- but only after staff edits their snack pricing.
CREATE OR REPLACE FUNCTION public.save_snack_v2(
  p_barcode text, p_name text, p_price integer, p_stock integer,
  p_pack_cost numeric, p_pack_size integer, p_fbla_price integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE r public.snacks;
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
  p_barcode := trim(coalesce(p_barcode,''));
  p_name := trim(coalesce(p_name,''));
  IF length(p_barcode) NOT BETWEEN 1 AND 100
    OR length(p_name) NOT BETWEEN 1 AND 150
    OR p_price NOT IN (1,2)
    OR (p_stock IS NOT NULL AND p_stock < 0)
    OR (p_pack_cost IS NOT NULL AND p_pack_cost < 0)
    OR (p_pack_size IS NOT NULL AND p_pack_size <= 0)
    OR (p_pack_cost IS NULL) <> (p_pack_size IS NULL)
    OR (p_fbla_price IS NOT NULL AND (p_fbla_price NOT IN (1,2) OR p_fbla_price > p_price)) THEN
    RAISE EXCEPTION 'Check snack barcode, name, prices, pack cost/quantity and stock';
  END IF;
  INSERT INTO public.snacks(barcode,name,price,stock,pack_cost,pack_size,fbla_price)
  VALUES(p_barcode,p_name,p_price,p_stock,p_pack_cost,p_pack_size,p_fbla_price)
  ON CONFLICT(barcode) DO UPDATE SET name=excluded.name, price=excluded.price,
    stock=excluded.stock, pack_cost=excluded.pack_cost, pack_size=excluded.pack_size,
    fbla_price=excluded.fbla_price, active=true, updated_at=now()
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_student_v2(
  p_student_id bigint, p_barcode text, p_full_name text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE r public.students;
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
  p_barcode := trim(coalesce(p_barcode,''));
  p_full_name := trim(coalesce(p_full_name,''));
  IF length(p_barcode) NOT BETWEEN 1 AND 100 OR length(p_full_name) NOT BETWEEN 1 AND 150 THEN
    RAISE EXCEPTION 'Provide a valid ID and name';
  END IF;
  UPDATE public.students SET barcode=p_barcode,full_name=p_full_name,updated_at=now()
  WHERE id=p_student_id RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'Student not found'; END IF;
  RETURN to_jsonb(r);
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_student_v2(p_student_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE r public.students; n integer;
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
  SELECT * INTO r FROM public.students WHERE id=p_student_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Student not found'; END IF;
  -- Remove any possibly identifying freeform notes before unlinking the account.
  UPDATE public.transactions SET note='' WHERE student_id=r.id;
  SELECT count(*) INTO n FROM public.transactions WHERE student_id=r.id;
  DELETE FROM public.students WHERE id=r.id;
  -- FK sets transaction.student_id NULL, preserving anonymous financial records.
  RETURN jsonb_build_object('deleted',true,'prior_balance',r.points,'transactions_anonymized',n);
END;
$$;

-- New point reload supports any positive whole-number amount up to 500.
CREATE OR REPLACE FUNCTION public.reload_points_custom(
  p_student_barcode text, p_points integer, p_note text, p_request_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE st public.students; tx public.transactions;
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
  IF p_points IS NULL OR p_points NOT BETWEEN 1 AND 500 OR p_request_id IS NULL THEN
    RAISE EXCEPTION 'Reload must be 1 to 500 whole points';
  END IF;
  SELECT * INTO tx FROM public.transactions WHERE request_id=p_request_id;
  IF FOUND THEN
    IF tx.kind <> 'reload' THEN RAISE EXCEPTION 'Request ID already used'; END IF;
    RETURN jsonb_build_object('balance',tx.balance_after,'duplicate',true);
  END IF;
  SELECT * INTO st FROM public.students WHERE barcode=trim(p_student_barcode) FOR UPDATE;
  IF NOT FOUND OR NOT st.active THEN RAISE EXCEPTION 'Student not found or inactive'; END IF;
  UPDATE public.students SET points=points+p_points,updated_at=now()
  WHERE id=st.id RETURNING * INTO st;
  INSERT INTO public.transactions(request_id,kind,student_id,delta_points,balance_after,staff_id,note)
  VALUES(p_request_id,'reload',st.id,p_points,st.points,auth.uid(),left(coalesce(p_note,''),500));
  RETURN jsonb_build_object('balance',st.points,'duplicate',false);
END;
$$;

-- One-scan FBLA price: use per-snack special point rate for this purchase only.
-- Pricing and cost at sale are snapshotted so later price edits do not rewrite profits.
CREATE OR REPLACE FUNCTION public.checkout_snack_v2(
  p_student_barcode text, p_snack_barcode text, p_request_id uuid, p_fbla boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE st public.students; sn public.snacks; tx public.transactions; charge integer;
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'Missing request ID'; END IF;
  SELECT * INTO tx FROM public.transactions WHERE request_id=p_request_id;
  IF FOUND THEN
    IF tx.kind <> 'purchase' THEN RAISE EXCEPTION 'Request ID already used'; END IF;
    RETURN jsonb_build_object('balance',tx.balance_after,
      'charged',-tx.delta_points,'transaction_id',tx.id,'duplicate',true);
  END IF;
  SELECT * INTO st FROM public.students WHERE barcode=trim(p_student_barcode) FOR UPDATE;
  IF NOT FOUND OR NOT st.active THEN RAISE EXCEPTION 'Student not found or inactive'; END IF;
  SELECT * INTO sn FROM public.snacks WHERE barcode=trim(p_snack_barcode) FOR UPDATE;
  IF NOT FOUND OR NOT sn.active THEN RAISE EXCEPTION 'Snack not found or inactive'; END IF;
  IF sn.stock=0 THEN RAISE EXCEPTION 'Snack is out of stock'; END IF;
  IF coalesce(p_fbla,false) AND sn.fbla_price IS NULL THEN
    RAISE EXCEPTION 'Set the FBLA price for this snack first';
  END IF;
  charge := CASE WHEN coalesce(p_fbla,false) THEN sn.fbla_price ELSE sn.price END;
  IF st.points < charge THEN RAISE EXCEPTION 'Insufficient points. Reload first.'; END IF;
  UPDATE public.students SET points=points-charge,updated_at=now()
  WHERE id=st.id RETURNING * INTO st;
  IF sn.stock IS NOT NULL THEN
    UPDATE public.snacks SET stock=stock-1,updated_at=now() WHERE id=sn.id RETURNING * INTO sn;
  END IF;
  INSERT INTO public.transactions(
    request_id,kind,student_id,snack_id,delta_points,balance_after,staff_id,
    note,sale_price,unit_cost_at_sale
  )
  VALUES(
    p_request_id,'purchase',st.id,sn.id,-charge,st.points,auth.uid(),
    CASE WHEN coalesce(p_fbla,false) THEN 'FBLA price' ELSE '' END,
    charge::numeric,
    CASE WHEN sn.pack_size IS NOT NULL THEN round(sn.pack_cost/sn.pack_size,4) ELSE NULL END
  ) RETURNING * INTO tx;
  RETURN jsonb_build_object('balance',st.points,'stock',sn.stock,
    'charged',charge,'transaction_id',tx.id,'duplicate',false);
END;
$$;

-- Lifetime metrics from ALL rows, not just the most recent 200 displayed in Activity.
-- Profit is gross merchandise margin, excluding overhead; reload cash is reported
-- separately and never added to earned product sales.
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
   WHERE t.kind='purchase'
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
   FROM public.transactions WHERE kind='reload'
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

REVOKE ALL ON FUNCTION public.save_snack_v2(text,text,integer,integer,numeric,integer,integer) FROM public,anon;
REVOKE ALL ON FUNCTION public.edit_student_v2(bigint,text,text) FROM public,anon;
REVOKE ALL ON FUNCTION public.delete_student_v2(bigint) FROM public,anon;
REVOKE ALL ON FUNCTION public.reload_points_custom(text,integer,text,uuid) FROM public,anon;
REVOKE ALL ON FUNCTION public.checkout_snack_v2(text,text,uuid,boolean) FROM public,anon;
REVOKE ALL ON FUNCTION public.get_snack_finances() FROM public,anon;
GRANT EXECUTE ON FUNCTION public.save_snack_v2(text,text,integer,integer,numeric,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_student_v2(bigint,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_student_v2(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reload_points_custom(text,integer,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.checkout_snack_v2(text,text,uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_snack_finances() TO authenticated;
COMMIT;
