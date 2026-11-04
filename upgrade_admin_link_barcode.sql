-- Run after upgrade_admin_roles.sql.
-- Link or update the administrator's own student barcode from an admin session.
BEGIN;
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
COMMIT;
