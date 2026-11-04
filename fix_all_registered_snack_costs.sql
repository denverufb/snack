-- Panther Pantry registered snack flavor and unit-cost mapping.
-- Run AFTER upgrade_finance.sql. Safe to rerun.
-- This updates cost of entire pack, items per pack and selling price.
-- It does NOT change the snack barcode or the current stock quantity.
BEGIN;
WITH packs (pack_name, pack_qty, pack_cost, selling_price) AS (
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
variants (registered_name, pack_name) AS (
 VALUES
  ('Sour Cream Pringles','Pringles'),
  ('Original Pringles','Pringles'),
  ('Cheddar Pringles','Pringles'),
  ('Mother''s Cookies','Mothers Circus'),
  ('Rice Krispeies','Rice Krispies'),
  ('Oreo''s','Oreo'),
  ('Red Starburst','Skittles and Starbursts'),
  ('Original Starburst','Skittles and Starbursts'),
  ('Tropical Skittles','Skittles and Starbursts'),
  ('Sour Skittles','Skittles and Starbursts'),
  ('Wild Berry Skittles','Skittles and Starbursts'),
  ('Original Skittles','Skittles and Starbursts'),
  ('Smartfood White Chedder','Chip Pack'),
  ('Cool Ranch Dorito''s','Chip Pack'),
  ('Sun Chip''s','Chip Pack'),
  ('Nacho Cheese Dorito''s','Chip Pack'),
  ('Sour Cream Lay''s','Chip Pack'),
  ('Pretzels','Chip Pack'),
  ('Cheeto Puffs','Chip Pack'),
  ('Donut Breakfast Bae','Blakes Bars'),
  ('Blueberry Breakfast Bar','Blakes Bars'),
  ('Cinnamon Roll Breakfast Bar','Blakes Bars'),
  ('Jalapeno Kettle','Miss Vickies')
),
all_names AS (
 SELECT pack_name AS registered_name,pack_name FROM packs
 UNION ALL SELECT registered_name,pack_name FROM variants
),
matched AS (
 SELECT s.id,p.pack_qty,p.pack_cost,p.selling_price
 FROM public.snacks s
 JOIN all_names n
   ON regexp_replace(lower(s.name),'[^a-z0-9]','','g') =
      regexp_replace(lower(n.registered_name),'[^a-z0-9]','','g')
 JOIN packs p ON p.pack_name=n.pack_name
)
UPDATE public.snacks s
SET pack_size=m.pack_qty,
    pack_cost=m.pack_cost,
    price=m.selling_price,
    updated_at=now()
FROM matched m WHERE s.id=m.id;

-- Backfill only missing unit-cost records for old purchases.
-- Historical unit costs are estimates based on the supplied pack costs.
UPDATE public.transactions t
SET unit_cost_at_sale=round(s.pack_cost/s.pack_size,4)
FROM public.snacks s
WHERE t.kind='purchase'
  AND t.snack_id=s.id
  AND t.unit_cost_at_sale IS NULL
  AND s.pack_size>0 AND s.pack_cost IS NOT NULL;
COMMIT;

SELECT name, barcode, pack_size AS items_in_pack,
       pack_cost AS total_pack_cost,
       round(pack_cost/nullif(pack_size,0),4) AS unit_cost,
       price AS sell_price, stock AS current_stock
FROM public.snacks ORDER BY name;
