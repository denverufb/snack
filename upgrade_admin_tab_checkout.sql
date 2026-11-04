-- Panther Pantry administrator-owned account: switch between points and tab.
-- Run AFTER upgrade_admin_roles.sql.
-- Tab purchases accumulate a balance owed; they do not reduce points.
-- Recording payments is manual and never processes a credit card.
BEGIN;

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
DECLARE paid_total numeric;
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
DECLARE charge integer; sid bigint; mode text; tab_id uuid; cost_at_sale numeric;
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
COMMIT;
