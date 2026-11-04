-- PANTHER PANTRY ONE-RUN ADMINISTRATOR UPGRADE
-- Run AFTER prior Snack Pass finance, catalog, PIN, and activity migrations.
-- Updates the original admin login, all regular staff, tab accounting and security.
-- No existing student, snack, or transaction records are erased.
-- Entire upgrade runs in a single transaction.
BEGIN;

-- REQUIRED: Replace the placeholder with YOUR Supabase Auth user UUID.
-- Supabase Dashboard > Authentication > Users > your own staff login.
-- This safeguards against assigning administrator rights to an employee.
CREATE TEMP TABLE pantry_admin_selection(admin_id uuid NOT NULL) ON COMMIT DROP;
INSERT INTO pg_temp.pantry_admin_selection(admin_id)
VALUES ('REPLACE_WITH_YOUR_AUTH_USER_UUID'::uuid);


-- === PART 1: upgrade_admin_roles.sql ===
-- Panther Pantry roles and administrator-only store settings.
-- RUN AFTER upgrade_finance.sql, upgrade_snack_catalog.sql,
-- upgrade_purchase_pin.sql and upgrade_activity_inventory.sql.
-- This script changes staff permissions; does not delete existing records.
ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'staff';
ALTER TABLE public.staff DROP CONSTRAINT IF EXISTS staff_role_check;
ALTER TABLE public.staff ADD CONSTRAINT staff_role_check
  CHECK (role IN ('admin','staff'));

-- All current and future authorized staff default to regular user.
-- The account below is the sole administrator.
UPDATE public.staff
SET role = CASE
  WHEN id=(SELECT admin_id FROM pg_temp.pantry_admin_selection) THEN 'admin'
  ELSE 'staff' END;
DO $check$
BEGIN
 IF NOT EXISTS (
   SELECT 1 FROM public.staff
   WHERE id=(SELECT admin_id FROM pg_temp.pantry_admin_selection)
     AND active AND role='admin'
 ) THEN RAISE EXCEPTION 'Original administrator staff account missing or inactive'; END IF;
END;
$check$;
CREATE UNIQUE INDEX IF NOT EXISTS one_pantry_administrator
  ON public.staff ((role)) WHERE role='admin';

CREATE OR REPLACE FUNCTION public.is_pantry_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
 SELECT EXISTS (
  SELECT 1 FROM public.staff
  WHERE id=auth.uid()
    AND active AND role='admin'
 );
$fn$;
REVOKE ALL ON FUNCTION public.is_pantry_admin() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.is_pantry_admin() TO authenticated;

CREATE TABLE IF NOT EXISTS public.pantry_admin_settings (
 singleton integer PRIMARY KEY CHECK (singleton=1),
 admin_student_id bigint REFERENCES public.students(id) ON DELETE SET NULL,
 account_mode text NOT NULL DEFAULT 'points'
   CHECK (account_mode IN ('points','tab')),
 updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.pantry_admin_settings(singleton) VALUES (1)
ON CONFLICT(singleton) DO NOTHING;

-- Link the admin's student card by an exact, unique name match.
-- No guessed barcode is ever written. Staff cannot change this setting.
WITH candidates AS (
  SELECT id FROM public.students
  WHERE lower(trim(full_name))='aereon robinson'
)
UPDATE public.pantry_admin_settings
SET admin_student_id=(SELECT id FROM candidates),
    updated_at=now()
WHERE singleton=1 AND admin_student_id IS NULL
  AND (SELECT count(*) FROM candidates)=1;

ALTER TABLE public.pantry_admin_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pantry_admin_settings FROM PUBLIC,anon,authenticated;

-- Staff can read stock and student data, but financial activity is admin-only.
DROP POLICY IF EXISTS staff_transactions_read ON public.transactions;
DROP POLICY IF EXISTS admin_transactions_read ON public.transactions;
CREATE POLICY admin_transactions_read ON public.transactions
 FOR SELECT TO authenticated USING (public.is_pantry_admin());

-- Keep existing checkout functions usable via their SECURITY DEFINER rights.
CREATE OR REPLACE FUNCTION public.get_pantry_role()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
BEGIN
 IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff account required'; END IF;
 RETURN jsonb_build_object(
   'role',CASE WHEN public.is_pantry_admin() THEN 'admin' ELSE 'staff' END
 );
END;
$fn$;
REVOKE ALL ON FUNCTION public.get_pantry_role() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pantry_role() TO authenticated;

-- Tighten the older SECURITY DEFINER functions that had allowed all staff
-- to edit snacks, deactivate students, change balances or view finances.
-- Do not change the checkout, reload or student registration RPCs.
DO $restrict$
DECLARE signature text; definition text; updated text; function_oid regprocedure;
BEGIN
 FOREACH signature IN ARRAY ARRAY[
  'public.save_snack(text,text,integer,integer)',
  'public.save_snack_v2(text,text,integer,integer,numeric,integer,integer)',
  'public.set_snack_active(text,boolean)',
  'public.remove_snack_v3(text)',
  'public.set_snack_stock_count(text,integer)',
  'public.edit_student_v2(bigint,text,text)',
  'public.delete_student_v2(bigint)',
  'public.set_student_active(text,boolean)',
  'public.adjust_points(text,integer,text,uuid)',
  'public.refund_purchase(uuid,uuid)',
  'public.get_snack_finances()'
 ] LOOP
  function_oid:=to_regprocedure(signature);
  IF function_oid IS NOT NULL THEN
    definition:=pg_get_functiondef(function_oid::oid);
    updated:=replace(definition,'public.is_staff()', 'public.is_pantry_admin()');
    IF updated=definition THEN
      RAISE EXCEPTION 'Permission guard could not be found in function %',signature;
    END IF;
    EXECUTE updated;
  ELSE
    RAISE NOTICE 'Optional function not found: %', signature;
  END IF;
 END LOOP;
END;
$restrict$;

-- Prevent bypassing the scan requirement through older direct delete RPCs.
REVOKE ALL ON FUNCTION public.remove_activity_entry(uuid,text) FROM authenticated;
REVOKE ALL ON FUNCTION public.void_purchase_pin(uuid,text,uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.remove_snack_v3(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.delete_student_v2(bigint) FROM authenticated;
-- Disable older bulk cleanup paths that do not require scanning a barcode.
DO $revoke$
BEGIN
 IF to_regprocedure('public.keep_only_three_activity(text,text)') IS NOT NULL THEN
   REVOKE ALL ON FUNCTION public.keep_only_three_activity(text,text) FROM authenticated;
 END IF;
 IF to_regprocedure('public.archive_opening_tests(uuid[],uuid,text,boolean)') IS NOT NULL THEN
   REVOKE ALL ON FUNCTION public.archive_opening_tests(uuid[],uuid,text,boolean) FROM authenticated;
 END IF;
END;
$revoke$;

SELECT display_name,role,active FROM public.staff ORDER BY role,display_name;
SELECT singleton,account_mode,
       admin_student_id IS NOT NULL AS admin_barcode_linked
FROM public.pantry_admin_settings;


-- === PART 2: upgrade_admin_tab_checkout.sql ===
-- Panther Pantry administrator-owned account: switch between points and tab.
-- Run AFTER upgrade_admin_roles.sql.
-- Tab purchases accumulate a balance owed; they do not reduce points.
-- Recording payments is manual and never processes a credit card.
CREATE TABLE IF NOT EXISTS public.pantry_tab_charges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE,
  admin_student_id bigint REFERENCES public.students(id) ON DELETE SET NULL,
  snack_id bigint REFERENCES public.snacks(id) ON DELETE SET NULL,
  snack_name text NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  unit_cost numeric(12,4),
  staff_id uuid REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  voided_at timestamptz
);
CREATE TABLE IF NOT EXISTS public.pantry_tab_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE,
  admin_student_id bigint REFERENCES public.students(id) ON DELETE SET NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  staff_id uuid REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  voided_at timestamptz
);
ALTER TABLE public.pantry_tab_charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pantry_tab_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pantry_tab_charges,public.pantry_tab_payments
  FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pantry_tab_charges,public.pantry_tab_payments
  TO authenticated;
DROP POLICY IF EXISTS admin_tab_charges_read ON public.pantry_tab_charges;
CREATE POLICY admin_tab_charges_read ON public.pantry_tab_charges
  FOR SELECT TO authenticated USING (public.is_pantry_admin());
DROP POLICY IF EXISTS admin_tab_payments_read ON public.pantry_tab_payments;
CREATE POLICY admin_tab_payments_read ON public.pantry_tab_payments
  FOR SELECT TO authenticated USING (public.is_pantry_admin());

CREATE OR REPLACE FUNCTION public.get_admin_account()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE mode text; sid bigint; student_name text; charge_total numeric;
paid_total numeric;
BEGIN
  IF NOT public.is_pantry_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
  SELECT account_mode,admin_student_id INTO mode,sid
  FROM public.pantry_admin_settings WHERE singleton=1;
  SELECT full_name INTO student_name FROM public.students WHERE id=sid;
  SELECT coalesce(sum(amount),0) INTO charge_total
    FROM public.pantry_tab_charges WHERE voided_at IS NULL;
  SELECT coalesce(sum(amount),0) INTO paid_total
    FROM public.pantry_tab_payments WHERE voided_at IS NULL;
  RETURN jsonb_build_object(
    'account_mode',mode,'student_linked',sid IS NOT NULL,
    'student_name',student_name,
    'tab_balance',round(charge_total-paid_total,2),
    'charged',round(charge_total,2),'paid',round(paid_total,2)
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION public.set_admin_account_mode(p_mode text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE sid bigint;
BEGIN
 IF NOT public.is_pantry_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
 IF p_mode NOT IN ('points','tab') THEN RAISE EXCEPTION 'Select tab or points'; END IF;
 SELECT admin_student_id INTO sid FROM public.pantry_admin_settings
 WHERE singleton=1 FOR UPDATE;
 IF sid IS NULL THEN
  RAISE EXCEPTION 'Link your student barcode to the administrator account first';
 END IF;
 UPDATE public.pantry_admin_settings
 SET account_mode=p_mode,updated_at=now() WHERE singleton=1;
 RETURN public.get_admin_account();
END;
$fn$;

CREATE OR REPLACE FUNCTION public.record_admin_tab_payment(
 p_amount numeric,p_request_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE sid bigint; credit numeric; debits numeric;
BEGIN
 IF NOT public.is_pantry_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
 IF p_request_id IS NULL OR p_amount IS NULL OR p_amount<=0
   OR p_amount>10000 OR round(p_amount,2)<>p_amount THEN
   RAISE EXCEPTION 'Enter a positive payment amount with no more than two decimals';
 END IF;
 IF EXISTS(SELECT 1 FROM public.pantry_tab_payments WHERE request_id=p_request_id) THEN
   RETURN public.get_admin_account();
 END IF;
 SELECT admin_student_id INTO sid FROM public.pantry_admin_settings
 WHERE singleton=1 FOR UPDATE;
 SELECT coalesce(sum(amount),0) INTO debits FROM public.pantry_tab_charges WHERE voided_at IS NULL;
 SELECT coalesce(sum(amount),0) INTO credit FROM public.pantry_tab_payments WHERE voided_at IS NULL;
 IF p_amount>debits-credit THEN RAISE EXCEPTION 'Payment exceeds amount owed'; END IF;
 INSERT INTO public.pantry_tab_payments(request_id,admin_student_id,amount,staff_id)
 VALUES(p_request_id,sid,p_amount,auth.uid());
 RETURN public.get_admin_account();
END;
$fn$;

CREATE OR REPLACE FUNCTION public.checkout_snack_v2(
  p_student_barcode text,p_snack_barcode text,p_request_id uuid,p_fbla boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $fn$
DECLARE st public.students; sn public.snacks; tx public.transactions;
charge integer; sid bigint; mode text; tab_id uuid; cost_at_sale numeric;
BEGIN
 IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'Missing transaction request ID'; END IF;
 SELECT * INTO tx FROM public.transactions WHERE request_id=p_request_id;
 IF FOUND THEN
  IF tx.kind<>'purchase' THEN RAISE EXCEPTION 'Request ID used for another action'; END IF;
  RETURN jsonb_build_object('balance',tx.balance_after,'transaction_id',tx.id,
    'charged',-tx.delta_points,'duplicate',true,'tab_charge',false);
 END IF;
 SELECT id INTO tab_id FROM public.pantry_tab_charges WHERE request_id=p_request_id;
 IF FOUND THEN
  SELECT * INTO st FROM public.students
  WHERE barcode=trim(coalesce(p_student_barcode,''));
  RETURN jsonb_build_object('balance',st.points,'transaction_id',tab_id,
    'charged',NULL,'duplicate',true,'tab_charge',true);
 END IF;
 SELECT * INTO st FROM public.students
 WHERE barcode=trim(coalesce(p_student_barcode,'')) FOR UPDATE;
 IF NOT FOUND OR NOT st.active THEN RAISE EXCEPTION 'Student not found or inactive'; END IF;
 SELECT * INTO sn FROM public.snacks
 WHERE barcode=trim(coalesce(p_snack_barcode,'')) FOR UPDATE;
 IF NOT FOUND OR NOT sn.active THEN RAISE EXCEPTION 'Snack not found or inactive'; END IF;
 IF sn.stock=0 THEN RAISE EXCEPTION 'Snack out of stock'; END IF;
 IF coalesce(p_fbla,false) THEN
  IF sn.fbla_price IS NULL THEN RAISE EXCEPTION 'FBLA price not set'; END IF;
  charge:=sn.fbla_price;
 ELSE charge:=sn.price; END IF;
 cost_at_sale:=CASE WHEN sn.pack_size>0 AND sn.pack_cost IS NOT NULL
   THEN round(sn.pack_cost/sn.pack_size,4) ELSE NULL END;
 SELECT admin_student_id,account_mode INTO sid,mode
   FROM public.pantry_admin_settings WHERE singleton=1;
 IF st.id=sid AND mode='tab' THEN
   IF sn.stock IS NOT NULL THEN
     UPDATE public.snacks SET stock=stock-1,updated_at=now()
     WHERE id=sn.id RETURNING * INTO sn;
   END IF;
   INSERT INTO public.pantry_tab_charges(
     request_id,admin_student_id,snack_id,snack_name,amount,unit_cost,staff_id)
   VALUES(p_request_id,st.id,sn.id,sn.name,charge,cost_at_sale,auth.uid())
   RETURNING id INTO tab_id;
   RETURN jsonb_build_object('balance',st.points,'stock',sn.stock,
      'charged',charge,'transaction_id',tab_id,
      'duplicate',false,'tab_charge',true);
 END IF;
 IF st.points<charge THEN RAISE EXCEPTION 'Insufficient points. Reload first'; END IF;
 UPDATE public.students SET points=points-charge,updated_at=now()
 WHERE id=st.id RETURNING * INTO st;
 IF sn.stock IS NOT NULL THEN
  UPDATE public.snacks SET stock=stock-1,updated_at=now()
  WHERE id=sn.id RETURNING * INTO sn;
 END IF;
 INSERT INTO public.transactions(
   request_id,kind,student_id,snack_id,delta_points,balance_after,
   staff_id,note,sale_price,unit_cost_at_sale
 ) VALUES(
   p_request_id,'purchase',st.id,sn.id,-charge,st.points,auth.uid(),
   CASE WHEN coalesce(p_fbla,false) THEN 'FBLA price' ELSE '' END,
   charge,cost_at_sale
 ) RETURNING * INTO tx;
 RETURN jsonb_build_object('balance',st.points,'stock',sn.stock,
  'charged',charge,'transaction_id',tx.id,
  'duplicate',false,'tab_charge',false);
END;
$fn$;

-- Keep the original barcode scanning endpoint working for all staff.
CREATE OR REPLACE FUNCTION public.checkout_snack(
 p_student_barcode text,p_snack_barcode text,p_request_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
BEGIN
 IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
 RETURN public.checkout_snack_v2(
    p_student_barcode,p_snack_barcode,p_request_id,false);
END;
$fn$;

REVOKE ALL ON FUNCTION public.get_admin_account() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.set_admin_account_mode(text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.record_admin_tab_payment(numeric,uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.checkout_snack_v2(text,text,uuid,boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.checkout_snack(text,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_admin_account() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_admin_account_mode(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_admin_tab_payment(numeric,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.checkout_snack_v2(text,text,uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.checkout_snack(text,text,uuid) TO authenticated;


-- === PART 3: upgrade_admin_barcode_removals.sql ===
-- Panther Pantry administrator barcode authorization for removal actions.
-- Run AFTER upgrade_admin_roles.sql and upgrade_admin_tab_checkout.sql.
-- A scan can also be typed; safety comes from requiring BOTH the signed-in
-- administrator identity and an exact match to their registered student barcode.
CREATE OR REPLACE FUNCTION public.require_pantry_admin_barcode(p_barcode text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
BEGIN
 IF NOT public.is_pantry_admin() THEN
   RAISE EXCEPTION 'Only the administrator may remove records';
 END IF;
 IF NOT EXISTS(
   SELECT 1 FROM public.pantry_admin_settings x
   JOIN public.students s ON s.id=x.admin_student_id
   WHERE x.singleton=1 AND s.barcode=trim(coalesce(p_barcode,''))
 ) THEN
   RAISE EXCEPTION 'Administrator student barcode was not recognized. Check account setup';
 END IF;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_remove_activity(
 p_transaction_id uuid,p_admin_barcode text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE tx public.transactions;
BEGIN
 PERFORM public.require_pantry_admin_barcode(p_admin_barcode);
 UPDATE public.transactions
 SET archived_at=now(),archived_by=auth.uid()
 WHERE id=p_transaction_id AND archived_at IS NULL
 RETURNING * INTO tx;
 IF NOT FOUND THEN RAISE EXCEPTION 'Activity entry was already removed or not found'; END IF;
 RETURN jsonb_build_object('removed',true,'kind',tx.kind,'id',tx.id);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_remove_snack(
 p_snack_barcode text,p_admin_barcode text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
BEGIN
 PERFORM public.require_pantry_admin_barcode(p_admin_barcode);
 RETURN public.remove_snack_v3(p_snack_barcode);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_remove_student(
 p_student_id bigint,p_admin_barcode text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
BEGIN
 PERFORM public.require_pantry_admin_barcode(p_admin_barcode);
 IF EXISTS(SELECT 1 FROM public.pantry_admin_settings
    WHERE singleton=1 AND admin_student_id=p_student_id) THEN
   RAISE EXCEPTION 'Cannot remove the administrator linked student account';
 END IF;
 RETURN public.delete_student_v2(p_student_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_remove_tab_charge(
 p_charge_id uuid,p_admin_barcode text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE c public.pantry_tab_charges;
total_owed numeric; total_paid numeric;
BEGIN
 PERFORM public.require_pantry_admin_barcode(p_admin_barcode);
 PERFORM 1 FROM public.pantry_admin_settings WHERE singleton=1 FOR UPDATE;
 SELECT * INTO c FROM public.pantry_tab_charges
 WHERE id=p_charge_id AND voided_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tab charge not found or already removed'; END IF;
 SELECT coalesce(sum(amount),0) INTO total_owed
 FROM public.pantry_tab_charges WHERE voided_at IS NULL;
 SELECT coalesce(sum(amount),0) INTO total_paid
 FROM public.pantry_tab_payments WHERE voided_at IS NULL;
 IF total_owed-c.amount<total_paid THEN
   RAISE EXCEPTION 'Removing this charge would exceed recorded tab payments. Correct the payment first';
 END IF;
 UPDATE public.pantry_tab_charges SET voided_at=now() WHERE id=p_charge_id;
 RETURN jsonb_build_object('removed',true,'id',p_charge_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_remove_tab_payment(
 p_payment_id uuid,p_admin_barcode text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
BEGIN
 PERFORM public.require_pantry_admin_barcode(p_admin_barcode);
 UPDATE public.pantry_tab_payments SET voided_at=now()
 WHERE id=p_payment_id AND voided_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tab payment not found or already removed'; END IF;
 RETURN jsonb_build_object('removed',true,'id',p_payment_id);
END;
$fn$;

-- Retire older removal entrypoints that only used a PIN, not the admin card.
REVOKE ALL ON FUNCTION public.remove_activity_entry(uuid,text) FROM authenticated;
REVOKE ALL ON FUNCTION public.remove_snack_v3(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.delete_student_v2(bigint) FROM authenticated;
REVOKE ALL ON FUNCTION public.void_purchase_pin(uuid,text,uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.require_pantry_admin_barcode(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.admin_remove_activity(uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_remove_snack(text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_remove_student(bigint,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_remove_tab_charge(uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_remove_tab_payment(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_remove_activity(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remove_snack(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remove_student(bigint,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remove_tab_charge(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remove_tab_payment(uuid,text) TO authenticated;


-- === PART 4: upgrade_admin_finances.sql ===
-- Financial reporting includes ordinary point purchases AND unpaid/paid
-- administrator tab purchases exactly once, excluding archived or voided sales.
-- Run AFTER upgrade_admin_tab_checkout.sql and upgrade_admin_barcode_removals.sql.
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


-- === PART 5: upgrade_admin_link_barcode.sql ===
-- Run after upgrade_admin_roles.sql.
-- Link or update the administrator's own student barcode from an admin session.
CREATE OR REPLACE FUNCTION public.link_admin_student_barcode(p_barcode text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE st public.students; linked bigint;
BEGIN
 IF NOT public.is_pantry_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
 SELECT * INTO st FROM public.students
 WHERE barcode=trim(coalesce(p_barcode,'')) AND active;
 IF NOT FOUND THEN RAISE EXCEPTION 'Student barcode not registered or inactive'; END IF;
 SELECT admin_student_id INTO linked
 FROM public.pantry_admin_settings WHERE singleton=1 FOR UPDATE;
 IF linked IS NOT NULL AND linked<>st.id THEN
  RAISE EXCEPTION 'An administrator barcode is already linked. Change it in Supabase SQL Editor';
 END IF;
 UPDATE public.pantry_admin_settings
 SET admin_student_id=st.id,updated_at=now()
 WHERE singleton=1;
 RETURN jsonb_build_object('linked',true,'student_name',st.full_name);
END;
$fn$;
REVOKE ALL ON FUNCTION public.link_admin_student_barcode(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.link_admin_student_barcode(text) TO authenticated;



-- Cashiers can REGISTER new students. Editing an existing student name
-- remains an administrator-only action.
CREATE OR REPLACE FUNCTION public.save_student(
 p_barcode text,p_full_name text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE r public.students;
BEGIN
 IF NOT public.is_staff() THEN RAISE EXCEPTION 'Staff access required'; END IF;
 p_barcode:=trim(coalesce(p_barcode,''));
 p_full_name:=trim(coalesce(p_full_name,''));
 IF length(p_barcode) NOT BETWEEN 1 AND 100
    OR length(p_full_name) NOT BETWEEN 1 AND 150 THEN
  RAISE EXCEPTION 'Provide valid barcode and student name';
 END IF;
 IF public.is_pantry_admin() THEN
  INSERT INTO public.students(barcode,full_name)
  VALUES(p_barcode,p_full_name)
  ON CONFLICT(barcode) DO UPDATE
  SET full_name=EXCLUDED.full_name,active=true,updated_at=now()
  RETURNING * INTO r;
 ELSE
  INSERT INTO public.students(barcode,full_name)
  VALUES(p_barcode,p_full_name)
  ON CONFLICT(barcode) DO NOTHING
  RETURNING * INTO r;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'This student already exists. Only an administrator can edit existing students';
  END IF;
 END IF;
 RETURN to_jsonb(r);
END;
$fn$;
REVOKE ALL ON FUNCTION public.save_student(text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_student(text,text) TO authenticated;

COMMIT;
