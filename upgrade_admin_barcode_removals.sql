-- Panther Pantry administrator barcode authorization for removal actions.
-- Run AFTER upgrade_admin_roles.sql and upgrade_admin_tab_checkout.sql.
-- A scan can also be typed; safety comes from requiring BOTH the signed-in
-- administrator identity and an exact match to their registered student barcode.
BEGIN;

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
COMMIT;
