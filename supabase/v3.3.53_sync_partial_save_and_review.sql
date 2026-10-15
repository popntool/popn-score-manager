-- v3.3.53: classify unsafe song identities without changing score-matching RPC.
-- Run this transaction in Supabase SQL Editor BEFORE deploying v3.3.53 frontend.
BEGIN;

CREATE TABLE IF NOT EXISTS public.sync_song_review_dedupe (
  fingerprint text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON public.sync_song_review_dedupe FROM PUBLIC, anon, authenticated;
ALTER TABLE public.sync_song_review_dedupe ENABLE ROW LEVEL SECURITY;

-- Metadata-only classifier. Never returns score or user identity.
CREATE OR REPLACE FUNCTION public.inspect_sync_review_records(p_records jsonb)
RETURNS TABLE(master_key text,genre text,title text,artist text,registered_genre text,registered_artist text)
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  IF jsonb_typeof(p_records) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'records must be an array'; END IF;
  RETURN QUERY
  WITH input AS MATERIALIZED (
    SELECT DISTINCT x.master_key,x.genre,x.title,x.artist
    FROM jsonb_to_recordset(p_records) AS x(master_key text,genre text,title text,artist text)
    WHERE coalesce(btrim(x.title),'')<>''
  )
  SELECT x.master_key,x.genre,x.title,x.artist,
         (SELECT min(s.genre) FROM public.songs s WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)),
         (SELECT min(s.artist) FROM public.songs s WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title))
  FROM input x
  WHERE NOT EXISTS(SELECT 1 FROM public.songs s WHERE s.master_key=x.master_key)
    AND NOT EXISTS(SELECT 1 FROM public.songs s
        WHERE public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
          AND public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist))
    AND EXISTS(SELECT 1 FROM public.songs s WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title));
END $fn$;
REVOKE ALL ON FUNCTION public.inspect_sync_review_records(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inspect_sync_review_records(jsonb) TO authenticated;

-- Only accept a notification if the master data really is still ambiguous.
-- The report is globally de-duplicated and appears in the existing admin feedback UI.
CREATE OR REPLACE FUNCTION public.report_sync_review_item(
 p_master_key text,p_genre text,p_title text,p_artist text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
DECLARE v_fp text;v_created text;v_genre text;v_artist text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
 IF char_length(coalesce(p_title,''))>250 OR char_length(coalesce(p_genre,''))>250 OR char_length(coalesce(p_artist,''))>250 THEN
  RAISE EXCEPTION 'metadata too long';
 END IF;
 IF coalesce(btrim(p_title),'')='' THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM public.songs s WHERE s.master_key=p_master_key) OR
    EXISTS(SELECT 1 FROM public.songs s
      WHERE public.normalize_popn_text(s.genre)=public.normalize_popn_text(p_genre)
      AND public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title)
      AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(p_artist)) OR
    NOT EXISTS(SELECT 1 FROM public.songs s WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title))
 THEN RETURN false; END IF;
 SELECT min(s.genre),min(s.artist) INTO v_genre,v_artist
 FROM public.songs s WHERE public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title);
 v_fp:=md5(coalesce(public.normalize_popn_text(p_title),'')||chr(31)||coalesce(public.normalize_popn_text(p_artist),'')||chr(31)||coalesce(public.normalize_popn_text(p_genre),''));
 INSERT INTO public.sync_song_review_dedupe(fingerprint) VALUES(v_fp)
 ON CONFLICT DO NOTHING RETURNING fingerprint INTO v_created;
 IF v_created IS NULL THEN RETURN false; END IF;
 INSERT INTO public.feedback_reports(user_id,category,message,device_name,browser_name,page_url,user_agent)
 VALUES (auth.uid(),'bug',
   left('[自動報告・曲マスター照合不一致]'||chr(10)||
   '公式：'||coalesce(p_genre,'')||' / '||p_title||' / '||coalesce(p_artist,'')||chr(10)||
   '登録候補：'||coalesce(v_genre,'')||' / '||p_title||' / '||coalesce(v_artist,'')||chr(10)||
   'スコアは保留しました。曲情報をご確認ください。',1200),
   '自動同期','', '', '');
 RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.report_sync_review_item(text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_sync_review_item(text,text,text,text) TO authenticated;
COMMIT;
