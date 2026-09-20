-- Run once in the Supabase SQL editor before deploying v3.1.25.
-- Caches per-user, per-game-version PSR; score writes only invalidate affected users.
-- The public RPC continues to enforce the existing per-field visibility settings.
BEGIN;

CREATE TABLE IF NOT EXISTS public.user_summary_cache (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  game_version_id uuid NOT NULL REFERENCES public.game_versions(id) ON DELETE CASCADE,
  pop_class numeric NOT NULL DEFAULT 0,
  highest_clear_level smallint,
  last_clear_updated_at timestamptz,
  PRIMARY KEY (user_id,game_version_id)
);
ALTER TABLE public.user_summary_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_summary_cache FROM PUBLIC,anon,authenticated;

-- Invalidate the user's summaries after score insert/update/delete, including imports
-- and administrative deletes. This operation is cheap and never recomputes PSR on write.
CREATE OR REPLACE FUNCTION public.invalidate_user_summary_from_score()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    DELETE FROM public.user_summary_cache WHERE user_id=OLD.user_id;
  END IF;
  IF TG_OP IN ('UPDATE','INSERT') THEN
    DELETE FROM public.user_summary_cache WHERE user_id=NEW.user_id;
  END IF;
  RETURN NULL;
END $fn$;
DROP TRIGGER IF EXISTS user_summary_score_invalidate ON public.user_scores;
CREATE TRIGGER user_summary_score_invalidate
AFTER INSERT OR UPDATE OR DELETE ON public.user_scores
FOR EACH ROW EXECUTE FUNCTION public.invalidate_user_summary_from_score();

CREATE OR REPLACE FUNCTION public.invalidate_user_summary_from_version_score()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    DELETE FROM public.user_summary_cache
    WHERE user_id=OLD.user_id AND game_version_id=OLD.game_version_id;
  END IF;
  IF TG_OP IN ('UPDATE','INSERT') THEN
    DELETE FROM public.user_summary_cache
    WHERE user_id=NEW.user_id AND game_version_id=NEW.game_version_id;
  END IF;
  RETURN NULL;
END $fn$;
DROP TRIGGER IF EXISTS user_summary_slot_invalidate ON public.user_version_scores;
CREATE TRIGGER user_summary_slot_invalidate
AFTER INSERT OR UPDATE OR DELETE ON public.user_version_scores
FOR EACH ROW EXECUTE FUNCTION public.invalidate_user_summary_from_version_score();

-- Master changes can affect all users with scores on the changed song.
CREATE OR REPLACE FUNCTION public.invalidate_user_summary_from_song()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
  IF TG_OP='DELETE' THEN
    DELETE FROM public.user_summary_cache c
    WHERE EXISTS (SELECT 1 FROM public.user_scores us WHERE us.user_id=c.user_id AND us.song_id=OLD.id);
  ELSIF TG_OP='INSERT' THEN
    RETURN NULL;
  ELSIF ROW(OLD.version_id,OLD.light_level,OLD.normal_level,OLD.hyper_level,OLD.ex_level)
       IS DISTINCT FROM ROW(NEW.version_id,NEW.light_level,NEW.normal_level,NEW.hyper_level,NEW.ex_level) THEN
    DELETE FROM public.user_summary_cache c
    WHERE EXISTS (SELECT 1 FROM public.user_scores us WHERE us.user_id=c.user_id AND us.song_id=NEW.id);
  END IF;
  RETURN NULL;
END $fn$;
DROP TRIGGER IF EXISTS user_summary_song_invalidate ON public.songs;
CREATE TRIGGER user_summary_song_invalidate
AFTER UPDATE OR DELETE ON public.songs
FOR EACH ROW EXECUTE FUNCTION public.invalidate_user_summary_from_song();

-- The high-cheers slug and active state control which score slot to use.
CREATE OR REPLACE FUNCTION public.invalidate_user_summary_from_game_version()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
  IF TG_OP='UPDATE' AND ROW(OLD.slug,OLD.is_active) IS DISTINCT FROM ROW(NEW.slug,NEW.is_active) THEN
    DELETE FROM public.user_summary_cache WHERE game_version_id=NEW.id;
  END IF;
  RETURN NULL;
END $fn$;
DROP TRIGGER IF EXISTS user_summary_version_invalidate ON public.game_versions;
CREATE TRIGGER user_summary_version_invalidate
AFTER UPDATE OF slug,is_active ON public.game_versions
FOR EACH ROW EXECUTE FUNCTION public.invalidate_user_summary_from_game_version();

-- Refill only missing (changed/new) users, and only for the requested game version.
-- Keep the same PSR formula, round-down order, medal clear levels and visibility
-- as the original v3.1.0 list_user_summaries_v31 RPC.
CREATE OR REPLACE FUNCTION public.list_user_summaries_v31(p_search text,p_game_version_id uuid)
RETURNS TABLE(user_id uuid,username text,poptomo_id text,pop_class numeric,official_popn_class numeric,highest_clear_level smallint,updated_at timestamptz)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $fn$
#variable_conflict use_column
DECLARE v_active public.game_versions%ROWTYPE;
BEGIN
  SELECT * INTO v_active FROM public.game_versions WHERE id=p_game_version_id;
  IF v_active.id IS NULL THEN
    RAISE EXCEPTION '有効なゲームバージョンを選択してください。';
  END IF;

  INSERT INTO public.user_summary_cache(user_id,game_version_id,pop_class,highest_clear_level,last_clear_updated_at)
  WITH missing AS (
    SELECT p.id
    FROM public.profiles p
    WHERE p.username ILIKE '%'||coalesce(p_search,'')||'%'
      AND NOT EXISTS (SELECT 1 FROM public.user_summary_cache c
         WHERE c.user_id=p.id AND c.game_version_id=p_game_version_id)
      AND (NOT EXISTS (SELECT 1 FROM public.admin_users a WHERE a.user_id=p.id)
           OR EXISTS (SELECT 1 FROM public.visible_admin_users a WHERE a.user_id=p.id))
  ), raw_values AS (
    SELECT us.user_id,us.updated_at,us.medal_code,
      CASE WHEN v_active.is_active AND v_active.slug='master_cdbb557d24080162a681ae5c'
        THEN coalesce(us.version_score,0)
        WHEN v_active.is_active THEN coalesce(slot.version_score,0) ELSE 0 END version_score,
      CASE us.chart WHEN 'LIGHT' THEN s.light_level WHEN 'NORMAL' THEN s.normal_level
        WHEN 'HYPER' THEN s.hyper_level WHEN 'EX' THEN s.ex_level END level,
      coalesce(s.version_id=p_game_version_id,false) is_current,
      lower(coalesce(CASE WHEN v_active.is_active AND v_active.slug='master_cdbb557d24080162a681ae5c'
        THEN us.current_clear_status WHEN v_active.is_active THEN slot.current_clear_status END,'failed')) current_clear_status
    FROM missing m
    JOIN public.user_scores us ON us.user_id=m.id
    JOIN public.songs s ON s.id=us.song_id
    LEFT JOIN public.user_version_scores slot
      ON slot.user_id=us.user_id AND slot.song_id=us.song_id
      AND slot.chart=us.chart AND slot.game_version_id=p_game_version_id
  ), chart_values AS (
    SELECT user_id,updated_at,medal_code,level,is_current,
      CASE WHEN current_clear_status='unplayed' OR version_score<=0 THEN 0::numeric
      ELSE floor((((level::numeric*level::numeric*version_score::numeric/6000)
        + CASE current_clear_status WHEN 'perfect' THEN 3000 WHEN 'full_combo' THEN 2000
           WHEN 'clear' THEN 1000 WHEN 'long_off' THEN 300 WHEN 'easy' THEN 200 ELSE 0 END
        )/200)*100)/100 END song_psr
    FROM raw_values
  ), ranked AS (
    SELECT *,row_number() OVER (PARTITION BY user_id,is_current ORDER BY song_psr DESC) position
    FROM chart_values
  ), totals AS (
    SELECT user_id,
      floor((coalesce(sum(song_psr) FILTER(WHERE is_current AND position<=20),0)
         +coalesce(sum(song_psr) FILTER(WHERE NOT is_current AND position<=40),0))/60*100)/100 pop_class
    FROM ranked GROUP BY user_id
  ), clears AS (
    SELECT user_id,max(level)::smallint highest_clear_level,max(updated_at) updated_at
    FROM chart_values
    WHERE lower(medal_code) IN ('perfect','a','fc_1_5','b','fc_6_20','c','fc_21_plus',
      'd','clear_bad_1_5','e','clear_bad_6_20','f','clear_bad_21_plus','g')
    GROUP BY user_id
  )
  SELECT m.id,p_game_version_id,coalesce(t.pop_class,0),c.highest_clear_level,c.updated_at
  FROM missing m LEFT JOIN totals t ON t.user_id=m.id
  LEFT JOIN clears c ON c.user_id=m.id
  ON CONFLICT (user_id,game_version_id) DO NOTHING;

  RETURN QUERY
  SELECT p.id,p.username,CASE WHEN p.poptomo_public THEN p.poptomo_id ELSE NULL END,
    CASE WHEN p.psr_public THEN coalesce(c.pop_class,0) ELSE NULL END,
    CASE WHEN p.popn_class_public THEN p.official_popn_class ELSE NULL END,
    CASE WHEN p.highest_clear_public THEN c.highest_clear_level ELSE NULL END,
    c.last_clear_updated_at
  FROM public.profiles p
  LEFT JOIN public.user_summary_cache c ON c.user_id=p.id AND c.game_version_id=p_game_version_id
  WHERE p.username ILIKE '%'||coalesce(p_search,'')||'%'
    AND (NOT EXISTS (SELECT 1 FROM public.admin_users a WHERE a.user_id=p.id)
      OR EXISTS (SELECT 1 FROM public.visible_admin_users a WHERE a.user_id=p.id))
  ORDER BY p.username;
END $fn$;
REVOKE ALL ON FUNCTION public.list_user_summaries_v31(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_user_summaries_v31(text,uuid) TO anon,authenticated;

COMMIT;

-- Precompute the current version once at deployment so the first visitor does not
-- have to populate every user's cache. On very large databases this one-time step
-- may take time; if it times out, the migration above is already committed and
-- the normal list RPC will safely fill only the missing records on demand.
DO $warm$
DECLARE v_version uuid;
BEGIN
  SELECT id INTO v_version FROM public.game_versions
    WHERE is_current AND is_active LIMIT 1;
  IF v_version IS NOT NULL THEN
    PERFORM count(*) FROM public.list_user_summaries_v31('',v_version);
  END IF;
END $warm$;
