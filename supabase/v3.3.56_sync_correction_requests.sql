-- v3.3.56  First run this migration successfully, then deploy frontend.
BEGIN;
CREATE TABLE IF NOT EXISTS public.sync_song_correction_requests (
 fingerprint text PRIMARY KEY,
 official_master_key text NOT NULL DEFAULT '',
 official_genre text NOT NULL,
 official_title text NOT NULL,
 official_artist text NOT NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected')),
 target_song_id uuid REFERENCES public.songs(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 reviewed_at timestamptz
);
ALTER TABLE public.sync_song_correction_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sync_song_correction_requests FROM PUBLIC,anon,authenticated;
CREATE INDEX IF NOT EXISTS sync_correction_status_idx ON public.sync_song_correction_requests(status,created_at DESC);

-- Move existing auto reports to the correction queue; do not migrate ordinary feedback.
-- Keep the same fingerprint used by v3.3.53 to preserve deduplication across versions.
WITH old_reports AS (
 SELECT f.id,
        split_part(split_part(f.message,E'公式：',2),E'\n',1) AS official,
        split_part(split_part(f.message,E'登録候補：',2),E'\n',1) AS candidate
 FROM public.feedback_reports f
 WHERE f.message LIKE '[自動報告・曲マスター照合不一致]%'
), parsed AS (
 SELECT id,btrim(split_part(official,' / ',1)) AS genre,
        btrim(split_part(official,' / ',2)) AS title,
        btrim(split_part(official,' / ',3)) AS artist
 FROM old_reports
), valid AS (
 SELECT *,md5(coalesce(public.normalize_popn_text(title),'')||chr(31)||coalesce(public.normalize_popn_text(artist),'')||chr(31)||coalesce(public.normalize_popn_text(genre),'')) AS fp
 FROM parsed WHERE title<>'' AND genre<>''
), moved AS (
 INSERT INTO public.sync_song_correction_requests(fingerprint,official_genre,official_title,official_artist)
 SELECT DISTINCT ON (fp) fp,genre,title,artist FROM valid ORDER BY fp
 ON CONFLICT (fingerprint) DO NOTHING RETURNING fingerprint
)
SELECT count(*) FROM moved;
-- Preserve the old feedback rows for audit. They can be removed later after the
-- administrator has verified that every correction was migrated correctly.

-- Lightweight admin-only notification counters, excluding migrated legacy notices.
CREATE OR REPLACE FUNCTION public.admin_sync_correction_counts()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
DECLARE v_pending bigint;v_old bigint;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin only'; END IF;
 SELECT count(*) INTO v_pending FROM public.sync_song_correction_requests WHERE status='pending';
 SELECT count(*) INTO v_old FROM public.feedback_reports WHERE message LIKE '[自動報告・曲マスター照合不一致]%';
 RETURN jsonb_build_object('pending',v_pending,'legacy_feedback',v_old);
END $fn$;
REVOKE ALL ON FUNCTION public.admin_sync_correction_counts() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_sync_correction_counts() TO authenticated;

-- Existing user sync call is preserved, now writes only to correction requests.
CREATE OR REPLACE FUNCTION public.report_sync_review_item(
 p_master_key text,p_genre text,p_title text,p_artist text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
DECLARE v_fp text;v_inserted text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
 IF length(coalesce(p_title,''))>250 OR length(coalesce(p_genre,''))>250 OR length(coalesce(p_artist,''))>250
    OR length(coalesce(p_master_key,''))>256 THEN RAISE EXCEPTION 'metadata too long'; END IF;
 IF coalesce(btrim(p_title),'')='' THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM public.songs s WHERE s.master_key=p_master_key) OR
    EXISTS(SELECT 1 FROM public.songs s
      WHERE public.normalize_popn_text(s.genre)=public.normalize_popn_text(p_genre)
      AND public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title)
      AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(p_artist)) OR
    NOT EXISTS(SELECT 1 FROM public.songs s WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title))
 THEN RETURN false; END IF;
 v_fp:=md5(coalesce(public.normalize_popn_text(p_title),'')||chr(31)||coalesce(public.normalize_popn_text(p_artist),'')||chr(31)||coalesce(public.normalize_popn_text(p_genre),''));
 INSERT INTO public.sync_song_correction_requests(fingerprint,official_master_key,official_genre,official_title,official_artist)
 VALUES(v_fp,coalesce(p_master_key,''),p_genre,p_title,p_artist)
 ON CONFLICT (fingerprint) DO UPDATE SET
 official_master_key=EXCLUDED.official_master_key,
 official_genre=EXCLUDED.official_genre,
 official_title=EXCLUDED.official_title,
 official_artist=EXCLUDED.official_artist,
 status='pending',reviewed_at=NULL,target_song_id=NULL
 WHERE sync_song_correction_requests.status='approved'
   AND NOT EXISTS(SELECT 1 FROM public.songs s
     WHERE public.normalize_popn_text(s.genre)=public.normalize_popn_text(p_genre)
       AND public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title)
       AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(p_artist))
 RETURNING fingerprint INTO v_inserted;
 RETURN v_inserted IS NOT NULL;
END $fn$;
REVOKE ALL ON FUNCTION public.report_sync_review_item(text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.report_sync_review_item(text,text,text,text) TO authenticated;

-- Dedicated admin-only read including safe candidates. No score/user identity is returned.
CREATE OR REPLACE FUNCTION public.admin_list_sync_corrections(p_search text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
DECLARE v_result jsonb;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin only'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('candidates',
    (SELECT coalesce(jsonb_agg(jsonb_build_object('id',s.id,'genre',s.genre,'title',s.title,'artist',s.artist)
      ORDER BY s.genre,s.id), '[]'::jsonb)
     FROM public.songs s WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(r.official_title)
       AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.official_artist)))
    ORDER BY r.created_at DESC), '[]'::jsonb) INTO v_result
 FROM (SELECT * FROM public.sync_song_correction_requests
 WHERE coalesce(p_search,'')='' OR concat_ws(' ',official_genre,official_title,official_artist,status) ILIKE '%'||p_search||'%'
 ORDER BY created_at DESC LIMIT 1000) r;
 RETURN v_result;
END $fn$;
REVOKE ALL ON FUNCTION public.admin_list_sync_corrections(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_list_sync_corrections(text) TO authenticated;

-- One atomic administrative action per item; rejects never change master data.
CREATE OR REPLACE FUNCTION public.admin_decide_sync_correction(p_fingerprint text,p_decision text,p_song_id uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
DECLARE v_request public.sync_song_correction_requests%ROWTYPE;v_song public.songs%ROWTYPE;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin only'; END IF;
 IF p_decision NOT IN ('approved','rejected') THEN RAISE EXCEPTION 'invalid decision'; END IF;
 SELECT * INTO v_request FROM public.sync_song_correction_requests WHERE fingerprint=p_fingerprint FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'correction request not found'; END IF;
 IF v_request.status<>'pending' THEN RAISE EXCEPTION 'already reviewed'; END IF;
 IF p_decision='approved' THEN
   IF p_song_id IS NULL THEN RAISE EXCEPTION '曲マスターを選択してください'; END IF;
   SELECT * INTO v_song FROM public.songs WHERE id=p_song_id FOR UPDATE;
   IF NOT FOUND OR public.normalize_popn_text(v_song.title)<>public.normalize_popn_text(v_request.official_title)
      OR public.normalize_popn_text(v_song.artist)<>public.normalize_popn_text(v_request.official_artist)
   THEN RAISE EXCEPTION '曲名・アーティストが一致しないため承認できません'; END IF;
   -- Do not touch ID or master_key: old scores retain their song identity.
   UPDATE public.songs SET genre=v_request.official_genre WHERE id=p_song_id;
 END IF;
 UPDATE public.sync_song_correction_requests SET status=p_decision,target_song_id=CASE WHEN p_decision='approved' THEN p_song_id ELSE NULL END,
 reviewed_at=now() WHERE fingerprint=p_fingerprint;
 RETURN p_decision;
END $fn$;
REVOKE ALL ON FUNCTION public.admin_decide_sync_correction(text,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_decide_sync_correction(text,text,uuid) TO authenticated;
COMMIT;
