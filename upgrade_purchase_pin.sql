-- Panther Pantry purchase correction controls.
-- Run after upgrade_finance.sql and upgrade_snack_catalog.sql.
-- This file DOES NOT contain a PIN. Set your PIN separately in Supabase SQL Editor.
BEGIN;
CREATE SCHEMA IF NOT EXISTS snack_private;
REVOKE ALL ON SCHEMA snack_private FROM PUBLIC;
CREATE TABLE IF NOT EXISTS snack_private.void_pin (
  id integer PRIMARY KEY CHECK (id = 1),
  salt text NOT NULL,
  pin_hash bytea NOT NULL
);
REVOKE ALL ON snack_private.void_pin FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.void_purchase_pin(
  p_transaction_id uuid, p_pin text, p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
DECLARE v_salt text; v_hash bytea; v_result jsonb; v_st bigint;
BEGIN
  IF auth.uid() IS DISTINCT FROM '2d8cbbb9-e980-48bf-96bd-de29acbf5473'::uuid
     OR NOT public.is_staff() THEN
     RAISE EXCEPTION 'Administrator access required';
  END IF;
  SELECT salt,pin_hash INTO v_salt,v_hash FROM snack_private.void_pin WHERE id=1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Set the purchase-removal PIN in Supabase first'; END IF;
  IF p_pin IS NULL OR v_hash IS DISTINCT FROM sha256(convert_to(v_salt||p_pin,'UTF8')) THEN
     RAISE EXCEPTION 'Incorrect removal PIN';
  END IF;
  SELECT student_id INTO v_st FROM public.transactions
  WHERE id=p_transaction_id AND kind='purchase';
  IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF v_st IS NULL OR NOT EXISTS (SELECT 1 FROM public.students WHERE id=v_st) THEN
     RAISE EXCEPTION 'Student was deleted; cannot restore their points automatically';
  END IF;
  v_result:=public.refund_purchase(p_transaction_id,p_request_id);
  RETURN jsonb_build_object('voided',true,'reversal',v_result);
END;
$function$;

REVOKE ALL ON FUNCTION public.refund_purchase(uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.void_purchase_pin(uuid,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.void_purchase_pin(uuid,text,uuid) TO authenticated;
COMMIT;
