-- v3.3.60: Compare official fullwidth ＠ and halfwidth @ consistently.
-- This patch does NOT alter song master text, master_key, or stored scores.
-- Uses the existing normalize_popn_text for all other characters and changes ONLY
-- the official/incoming artist argument; master-side index expressions are unchanged.
-- Apply AFTER v3.3.59 SQL and BEFORE pushing the frontend version bump.
BEGIN;

DO $migration$
DECLARE
  v_target text;
  v_oid oid;
  v_original text;
  v_rewritten text;
  v_changes integer;
  v_total integer := 0;
  v_need text[] := ARRAY[
    'public.inspect_sync_review_records(jsonb)',
    'public.report_sync_review_item(text,text,text,text)',
    'public.admin_list_sync_corrections(text)',
    'public.diagnose_sync_matches(jsonb)'
  ];
  v_targets text[] := ARRAY[
    'public.inspect_sync_review_records(jsonb)',
    'public.report_sync_review_item(text,text,text,text)',
    'public.admin_list_sync_corrections(text)',
    'public.diagnose_sync_matches(jsonb)',
    'public.diagnose_title_only_matches(jsonb)',
    'public.sync_my_scores_v320(jsonb,uuid,text)',
    'public.sync_my_scores_v31(jsonb,uuid,text)',
    'public.sync_my_scores(jsonb)'
  ];
  v_from text;
  v_to text;
  v_arg text;
BEGIN
  -- Stop before changing anything if core functions are missing.
  FOREACH v_target IN ARRAY v_need LOOP
    IF to_regprocedure(v_target) IS NULL THEN
      RAISE EXCEPTION 'Required function is missing: %. Apply preceding migrations first.', v_target;
    END IF;
  END LOOP;

  FOREACH v_target IN ARRAY v_targets LOOP
    v_oid:=to_regprocedure(v_target);
    IF v_oid IS NULL THEN CONTINUE; END IF;
    v_original:=pg_get_functiondef(v_oid);
    v_rewritten:=v_original;
    v_changes:=0;

    -- Incoming official artist fields only. Preserve s.artist, p.artist,
    -- original text stored in songs and other song identity rules.
    FOREACH v_arg IN ARRAY ARRAY['x.artist','r.artist','p_artist','r.official_artist'] LOOP
      v_from:='public.normalize_popn_text(' || v_arg || ')';
      v_to:='public.normalize_popn_text(replace(' || v_arg || ', ''＠'', ''@''))';
      IF position(v_from IN v_rewritten)>0 THEN
        v_changes:=v_changes+1;
        v_rewritten:=replace(v_rewritten,v_from,v_to);
      END IF;
    END LOOP;
    IF v_changes>0 THEN
      EXECUTE v_rewritten;
      v_total:=v_total+1;
      RAISE NOTICE 'Updated artist comparison in %',v_target;
    ELSE
      RAISE NOTICE 'No official artist compare to replace in %',v_target;
    END IF;
  END LOOP;
  IF v_total < 4 THEN
    RAISE EXCEPTION 'Only % functions patched (expected at least 4). Transaction rolled back.',v_total;
  END IF;
END $migration$;

-- Resolve the known stale pending item only if its genre, title and
-- artist match the CURRENT master after comparison-only ＠ conversion.
-- Uses the existing 'approved' resolved status convention; does not edit songs.
UPDATE public.sync_song_correction_requests AS r
SET status='approved', reviewed_at=now()
WHERE r.status='pending'
  AND r.official_title='ホットドッグドカぐいレース!!!!'
  AND r.official_artist='cosMo＠暴走P'
  AND EXISTS (
    SELECT 1 FROM public.songs AS s
    WHERE public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.official_genre)
      AND public.normalize_popn_text(s.title)=public.normalize_popn_text(r.official_title)
      AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace(r.official_artist,'＠','@'))
  );

COMMIT;

-- Read-only post-check; must return at least one row with matches_after_fix=true.
SELECT s.title,s.genre,s.artist,
  public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace('cosMo＠暴走P','＠','@')) AS matches_after_fix
FROM public.songs s
WHERE s.title='ホットドッグドカぐいレース!!!!'
  AND s.artist='cosMo@暴走P';
