-- Fix Panther Pantry catalog costs based on the 15 supplied pack totals.
-- Run after upgrade_finance.sql. This does not change stock or barcodes.
BEGIN;
WITH products(label,qty,total,sell) AS (
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
aliases(variant,standard) AS (
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
 ('blakesseedbars','blakesbars'),
 ('skittlesstarbursts','skittlesandstarbursts')
),
matched AS (
 SELECT s.id, p.qty,p.total,p.sell
 FROM public.snacks s
 JOIN products p ON
   regexp_replace(lower(p.label),'[^a-z0-9]','','g')=
   COALESCE(
      (SELECT a.standard FROM aliases a
       WHERE a.variant=regexp_replace(lower(s.name),'[^a-z0-9]','','g') LIMIT 1),
      regexp_replace(lower(s.name),'[^a-z0-9]','','g')
   )
)
UPDATE public.snacks s
SET pack_size=m.qty,pack_cost=m.total,price=m.sell,updated_at=now()
FROM matched m WHERE s.id=m.id;

-- Historical cost for sales before cost tracking began is an estimate.
-- Fill only missing cost snapshots, using the product's stored unit cost.
UPDATE public.transactions t
SET unit_cost_at_sale=round(s.pack_cost/s.pack_size,4)
FROM public.snacks s
WHERE t.kind='purchase'
  AND t.snack_id=s.id
  AND t.unit_cost_at_sale IS NULL
  AND s.pack_size>0
  AND s.pack_cost IS NOT NULL;

COMMIT;

SELECT name,barcode,
 round(pack_cost/nullif(pack_size,0),3) AS unit_cost,
 pack_size,pack_cost,stock,price
FROM public.snacks ORDER BY name;
