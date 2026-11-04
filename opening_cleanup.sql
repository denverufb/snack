-- One-time cleanup: select four known real transactions, preserve all later ones.
-- Requires upgrade_activity_inventory.sql and the administrator PIN setup.
BEGIN;
CREATE OR REPLACE FUNCTION public.archive_opening_tests(
  purchase_ids uuid[],
  funding_id uuid,
  pin text,
  preview_only boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $func$
DECLARE
  cutoff timestamptz;
  purchases integer;
  funding integer;
  matching integer;
  affected integer;
BEGIN
  PERFORM snack_private.require_activity_pin(pin);
  IF array_length(purchase_ids,1) IS DISTINCT FROM 3
    OR (SELECT count(DISTINCT v) FROM unnest(purchase_ids) v) <> 3
    OR funding_id=ANY(purchase_ids)
  THEN RAISE EXCEPTION 'Choose three unique purchases and one separate reload'; END IF;

  SELECT count(*),max(created_at) INTO purchases,cutoff
    FROM public.transactions
    WHERE id=ANY(purchase_ids) AND kind='purchase' AND archived_at IS NULL;
  SELECT count(*) INTO funding FROM public.transactions
    WHERE id=funding_id AND kind IN ('reload','adjustment') AND archived_at IS NULL;
  IF purchases<>3 OR funding<>1 THEN RAISE EXCEPTION 'Selected entries do not match three purchases and one reload'; END IF;
  SELECT greatest(cutoff,created_at) INTO cutoff
    FROM public.transactions WHERE id=funding_id;
  SELECT count(*) INTO matching FROM public.transactions
   WHERE archived_at IS NULL AND created_at<=cutoff
     AND id<>ALL(purchase_ids) AND id<>funding_id;

  IF NOT preview_only THEN
    UPDATE public.transactions SET archived_at=now(),archived_by=auth.uid()
    WHERE archived_at IS NULL AND created_at<=cutoff
      AND id<>ALL(purchase_ids) AND id<>funding_id;
    GET DIAGNOSTICS affected=ROW_COUNT;
  END IF;
  RETURN jsonb_build_object(
    'would_hide',matching,'hidden',coalesce(affected,0),
    'four_selected_kept',4,'later_transactions_kept',true,
    'cutoff',cutoff,'preview',preview_only
  );
END;
$func$;
REVOKE ALL ON FUNCTION public.archive_opening_tests(uuid[],uuid,text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.archive_opening_tests(uuid[],uuid,text,boolean) TO authenticated;
COMMIT;