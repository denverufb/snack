-- Panther Pantry roles and administrator-only store settings.
-- RUN AFTER upgrade_finance.sql, upgrade_snack_catalog.sql,
-- upgrade_purchase_pin.sql and upgrade_activity_inventory.sql.
-- This script changes staff permissions; does not delete existing records.
BEGIN;

ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'staff';
ALTER TABLE public.staff DROP CONSTRAINT IF EXISTS staff_role_check;
ALTER TABLE public.staff ADD CONSTRAINT staff_role_check
  CHECK (role IN ('admin','staff'));

-- All current and future authorized staff default to regular user.
-- The account below is the sole administrator.
UPDATE public.staff
SET role = CASE
  WHEN id='2d8cbbb9-e980-48bf-96bd-de29acbf5473'::uuid THEN 'admin'
  ELSE 'staff' END;
DO $check$
BEGIN
 IF NOT EXISTS (
   SELECT 1 FROM public.staff
   WHERE id='2d8cbbb9-e980-48bf-96bd-de29acbf5473'::uuid
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
    AND id='2d8cbbb9-e980-48bf-96bd-de29acbf5473'::uuid
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

COMMIT;

SELECT display_name,role,active FROM public.staff ORDER BY role,display_name;
SELECT singleton,account_mode,
       admin_student_id IS NOT NULL AS admin_barcode_linked
FROM public.pantry_admin_settings;
