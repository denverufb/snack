-- Panther Pantry: catalog unit costs, sale prices, and safe snack removal.
-- Run AFTER upgrade_finance.sql. Existing student accounts, barcodes, stock,
-- purchases, staff, points, and payment history stay intact.
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='snacks' AND column_name='pack_cost'
  ) THEN
    RAISE EXCEPTION 'First run upgrade_finance.sql, then run this file.';
  END IF;
END
$$;

-- Preserve product labels even when a snack is permanently removed.
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS product_name_at_sale text;

-- Keep transaction audit records when deleting a product.
ALTER TABLE public.transactions
  DROP CONSTRAINT IF EXISTS transactions_snack_id_fkey;
ALTER TABLE public.transactions
  ADD CONSTRAINT transactions_snack_id_fkey
  FOREIGN KEY (snack_id) REFERENCES public.snacks(id)
  ON DELETE SET NULL;

-- Your 15 provided products. Pack cost / pack quantity is the precise
-- purchase cost per unit. Selling price is in points, with 1 point = $1.
-- Existing barcodes and CURRENT stock quantities are never changed.
-- Matches existing snacks by name, ignoring spaces, apostrophes, dashes.
WITH catalog(name, pack_qty, pack_total, sell_points) AS (
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
aliases(alias, canonical) AS (
  VALUES
    ('nerdsclusters','nerdclusters'),
    ('nerdsgummyclusters','nerdclusters'),
    ('motherscircuscookies','motherscircus'),
    ('welchs','welches'),
    ('welchsfruitssnacks','welches'),
    ('welchsfruitsnacks','welches'),
    ('missvickieschips','missvickies'),
    ('veggiestraws','veggiestraw'),
    ('oreocookies','oreo'),
    ('blakesseedbars','blakesbars')
),
normalized AS (
  SELECT name,pack_qty,pack_total,sell_points,
         lower(regexp_replace(name,'[^a-zA-Z0-9]','','g')) AS key
  FROM catalog
)
UPDATE public.snacks s
SET pack_cost=c.pack_total,
    pack_size=c.pack_qty,
    price=c.sell_points,
    updated_at=now()
FROM normalized c
WHERE c.key=coalesce(
  (SELECT a.canonical FROM aliases a
   WHERE a.alias=lower(regexp_replace(s.name,'[^a-zA-Z0-9]','','g'))),
  lower(regexp_replace(s.name,'[^a-zA-Z0-9]','','g'))
);

-- Preserve a name for existing purchases and snapshot price/cost for
-- purchases made using the original checkout before the finance upgrade.
UPDATE public.transactions t
SET product_name_at_sale = coalesce(t.product_name_at_sale,s.name)
FROM public.snacks s
WHERE t.kind='purchase' AND t.snack_id=s.id
  AND t.product_name_at_sale IS NULL;

-- The backend checks authorization; the website never gets direct DELETE
-- privileges on the snacks table.
CREATE OR REPLACE FUNCTION public.remove_snack_v3(p_barcode text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE sn public.snacks;
DECLARE sales_count integer;
BEGIN
  IF NOT public.is_staff() THEN
    RAISE EXCEPTION 'Staff access required';
  END IF;
  SELECT * INTO sn FROM public.snacks
  WHERE barcode=trim(coalesce(p_barcode,'')) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Snack not found'; END IF;

  -- Preserve historic merchandise sales and current best-known cost estimates.
  UPDATE public.transactions t
  SET product_name_at_sale=coalesce(t.product_name_at_sale,sn.name),
      sale_price=coalesce(t.sale_price,(-t.delta_points)::numeric),
      unit_cost_at_sale=coalesce(t.unit_cost_at_sale,
        CASE WHEN sn.pack_size>0
          THEN round(sn.pack_cost/sn.pack_size,4) ELSE NULL END)
  WHERE t.snack_id=sn.id AND t.kind='purchase';

  SELECT count(*) INTO sales_count FROM public.transactions
  WHERE snack_id=sn.id AND kind='purchase';

  DELETE FROM public.snacks WHERE id=sn.id;
  -- The FK only clears transaction.snack_id, not transaction amounts.
  RETURN jsonb_build_object(
    'removed',true,'name',sn.name,'sales_preserved',sales_count
  );
END
$$;

REVOKE ALL ON FUNCTION public.remove_snack_v3(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.remove_snack_v3(text) TO authenticated;

COMMIT;

-- Optional inspection after running: shows saved costs and sell prices.
SELECT name, barcode, pack_size AS pack_quantity, pack_cost AS pack_total,
       round(pack_cost/nullif(pack_size,0),3) AS unit_cost,
       price AS sell_points, stock AS units_currently_in_stock
FROM public.snacks ORDER BY name;
