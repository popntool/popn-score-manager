-- v3.3.59: Current master wins; only pending is deduplicated.
-- Run after v3.3.56. No changes to songs, master_key or user_scores.
BEGIN;

-- Preserve decision history when a previously rejected/approved fingerprint recurs.
CREATE TABLE IF NOT EXISTS public.sync_song_correction_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fingerprint text NOT NULL,
  previous_status text NOT NULL,
  previous_target_song_id uuid,
  previous_created_at timestamptz,
  previous_reviewed_at timestamptz,
  recorded_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sync_song_correction_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sync_song_correction_history FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.report_sync_review_item(
 p_master_key text,p_genre text,p_title text,p_artist text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
DECLARE v_fp text;v_old public.sync_song_correction_requests%ROWTYPE;v_inserted boolean:=false;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
 IF length(coalesce(p_title,''))>250 OR length(coalesce(p_genre,''))>250 OR length(coalesce(p_artist,''))>250
    OR length(coalesce(p_master_key,''))>256 THEN RAISE EXCEPTION 'metadata too long'; END IF;
 IF coalesce(btrim(p_title),'')='' THEN RETURN false; END IF;
 -- A current master match is authoritative regardless of any old decision history.
 IF EXISTS(SELECT 1 FROM public.songs s WHERE s.master_key=p_master_key) OR
    EXISTS(SELECT 1 FROM public.songs s
      WHERE public.normalize_popn_text(s.genre)=public.normalize_popn_text(p_genre)
        AND public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title)
        AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(p_artist)) OR
    NOT EXISTS(SELECT 1 FROM public.songs s
      WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title))
 THEN RETURN false; END IF;
 v_fp:=md5(coalesce(public.normalize_popn_text(p_title),'')||chr(31)||coalesce(public.normalize_popn_text(p_artist),'')||chr(31)||coalesce(public.normalize_popn_text(p_genre),''));
 -- Lock the fingerprint to avoid racing on the same request from two users.
 PERFORM pg_advisory_xact_lock(hashtextextended(v_fp, 3359::bigint));
 SELECT * INTO v_old FROM public.sync_song_correction_requests WHERE fingerprint=v_fp FOR UPDATE;
 IF FOUND THEN
   IF v_old.status='pending' THEN RETURN false; END IF;
   INSERT INTO public.sync_song_correction_history(fingerprint,previous_status,previous_target_song_id,previous_created_at,previous_reviewed_at)
   VALUES(v_fp,v_old.status,v_old.target_song_id,v_old.created_at,v_old.reviewed_at);
   UPDATE public.sync_song_correction_requests SET official_master_key=coalesce(p_master_key,''),
     official_genre=p_genre,official_title=p_title,official_artist=p_artist,
     status='pending',target_song_id=NULL,reviewed_at=NULL,created_at=now()
   WHERE fingerprint=v_fp;
   RETURN true;
 END IF;
 INSERT INTO public.sync_song_correction_requests(fingerprint,official_master_key,official_genre,official_title,official_artist)
 VALUES(v_fp,coalesce(p_master_key,''),p_genre,p_title,p_artist);
 RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.report_sync_review_item(text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.report_sync_review_item(text,text,text,text) TO authenticated;

-- Return strict, actionable candidates separately from title-only diagnostics.
-- Title-only results can be inspected but are NOT auto-approved as artist matches.
CREATE OR REPLACE FUNCTION public.admin_list_sync_corrections(p_search text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
DECLARE v_result jsonb;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin only'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object(
    'candidates', (SELECT coalesce(jsonb_agg(jsonb_build_object('id',s.id,'genre',s.genre,'title',s.title,'artist',s.artist)
          ORDER BY s.genre,s.id), '[]'::jsonb)
       FROM public.songs s WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(r.official_title)
         AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.official_artist)),
    'title_candidates', (SELECT coalesce(jsonb_agg(jsonb_build_object('id',s.id,'genre',s.genre,'title',s.title,'artist',s.artist)
          ORDER BY s.genre,s.id), '[]'::jsonb)
       FROM public.songs s WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(r.official_title)
         AND public.normalize_popn_text(s.artist) IS DISTINCT FROM public.normalize_popn_text(r.official_artist))
 ) ORDER BY r.created_at DESC), '[]'::jsonb) INTO v_result
 FROM (SELECT * FROM public.sync_song_correction_requests
 WHERE coalesce(p_search,'')='' OR concat_ws(' ',official_genre,official_title,official_artist,status) ILIKE '%'||p_search||'%'
 ORDER BY created_at DESC LIMIT 1000) r;
 RETURN v_result;
END $fn$;
REVOKE ALL ON FUNCTION public.admin_list_sync_corrections(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_list_sync_corrections(text) TO authenticated;

-- A historical pending request whose triple already matches should not clutter the queue.
UPDATE public.sync_song_correction_requests r
SET status='approved', reviewed_at=now()
WHERE r.status='pending' AND EXISTS (
 SELECT 1 FROM public.songs s
 WHERE (r.official_master_key<>'' AND s.master_key=r.official_master_key)
    OR (public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.official_genre)
    AND public.normalize_popn_text(s.title)=public.normalize_popn_text(r.official_title)
    AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.official_artist))
);
COMMIT;
