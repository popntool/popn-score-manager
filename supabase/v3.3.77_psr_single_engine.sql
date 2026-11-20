-- v3.3.77: one authoritative PSR calculation for both personal and public pages.
-- Run BEFORE deploying v3.3.77. Score, medal and historical snapshot rows are untouched.
BEGIN;

-- The SINGLE per-chart PSR formula, also used for unsaved manual-entry previews.
CREATE OR REPLACE FUNCTION public.psr_chart_value_v3377(p_level numeric,p_score numeric,p_status text)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path='' AS $rating$
 SELECT CASE WHEN coalesce(p_score,0)<=0 OR lower(coalesce(p_status,'failed'))='unplayed'
 THEN 0::numeric ELSE floor(((greatest(0,coalesce(p_level,0))*greatest(0,coalesce(p_level,0))
   *least(100000,greatest(0,p_score))/6000
   + CASE lower(coalesce(p_status,'failed')) WHEN 'perfect' THEN 3000
     WHEN 'full_combo' THEN 2000 WHEN 'clear' THEN 1000 WHEN 'long_off' THEN 300
     WHEN 'easy' THEN 200 ELSE 0 END)/200)*100)/100 END;
$rating$;
REVOKE ALL ON FUNCTION public.psr_chart_value_v3377(numeric,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.psr_chart_value_v3377(numeric,numeric,text) TO authenticated;

-- INTERNAL engine: not exposed as an API. All played charts and their official
-- per-chart rating, placement and aggregate are computed here only.
CREATE OR REPLACE FUNCTION public.psr_values_core_v3377(p_user_id uuid,p_game_version_id uuid)
RETURNS TABLE(song_id uuid,chart text,version_score numeric,current_clear_status text,
  pop_class numeric,version_is_current boolean,position bigint,selected boolean,total numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $psr$
WITH game AS (
 SELECT id,slug,is_active,is_current FROM public.game_versions WHERE id=p_game_version_id
), raw AS (
 SELECT s.id AS song_id,us.chart::text AS chart,s.title,
  CASE us.chart::text WHEN 'LIGHT' THEN s.light_level WHEN 'NORMAL' THEN s.normal_level
    WHEN 'HYPER' THEN s.hyper_level WHEN 'EX' THEN s.ex_level END::numeric AS level,
  coalesce(s.version_id=p_game_version_id,false) AS version_is_current,
  lower(coalesce(us.medal_code::text,'none')) AS medal_code,
  CASE WHEN g.is_active AND g.slug='master_cdbb557d24080162a681ae5c'
    THEN coalesce(us.version_score,0)
    WHEN g.is_active THEN coalesce(slot.version_score,0) ELSE 0 END::numeric AS version_score,
  lower(coalesce(CASE WHEN g.is_active AND g.slug='master_cdbb557d24080162a681ae5c'
    THEN us.current_clear_status::text WHEN g.is_active THEN slot.current_clear_status::text END,'failed')) AS base_status,
  g.is_current AS game_is_current
 FROM public.user_scores us
 JOIN public.songs s ON s.id=us.song_id
 CROSS JOIN game g
 LEFT JOIN public.user_version_scores slot
   ON slot.user_id=us.user_id AND slot.song_id=us.song_id
   AND slot.chart=us.chart AND slot.game_version_id=p_game_version_id
 WHERE us.user_id=p_user_id
), normalized AS (
 SELECT *,CASE
   WHEN game_is_current AND version_is_current AND medal_code IN ('perfect','a') THEN 'perfect'
   WHEN game_is_current AND version_is_current AND medal_code IN ('fc_1_5','fc_6_20','fc_21_plus','b','c','d') THEN 'full_combo'
   WHEN game_is_current AND version_is_current AND medal_code IN ('clear_bad_1_5','clear_bad_6_20','clear_bad_21_plus','e','f','g') THEN 'clear'
   WHEN game_is_current AND version_is_current AND medal_code IN ('easy','k') THEN 'easy'
   WHEN game_is_current AND version_is_current AND medal_code='long_off' THEN 'long_off'
   WHEN game_is_current AND version_is_current AND medal_code IN ('failed_0_11','failed_12_14','failed_15_16','h','i','j','l','m','n') THEN 'failed'
   ELSE base_status END AS effective_status
 FROM raw
), ratings AS (
 SELECT *,public.psr_chart_value_v3377(level,version_score,effective_status) AS rating
 FROM normalized WHERE version_score>0 AND effective_status<>'unplayed' AND level>0
), ranked AS (
 SELECT *,row_number() OVER (PARTITION BY version_is_current
   ORDER BY rating DESC,version_score DESC,title COLLATE "C",song_id,chart) AS pos
 FROM ratings
), marked AS (
 SELECT *, (pos <= CASE WHEN version_is_current THEN 20 ELSE 40 END) AS chosen FROM ranked
), aggregate AS (
 SELECT floor(coalesce(sum(rating) FILTER (WHERE chosen),0)/60*100)/100 AS total FROM marked
)
SELECT m.song_id,m.chart,m.version_score,m.effective_status,m.rating,m.version_is_current,
 m.pos,m.chosen,a.total FROM marked m CROSS JOIN aggregate a;
$psr$;
REVOKE ALL ON FUNCTION public.psr_values_core_v3377(uuid,uuid) FROM PUBLIC,anon,authenticated;

-- A signed-in user may read only their own canonical chart ratings/selection.
CREATE OR REPLACE FUNCTION public.my_psr_values_v3377(p_game_version_id uuid)
RETURNS TABLE(song_id uuid,chart text,version_score numeric,current_clear_status text,
  pop_class numeric,version_is_current boolean,position bigint,selected boolean,total numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'ログインが必要です。'; END IF;
 RETURN QUERY SELECT * FROM public.psr_values_core_v3377(auth.uid(),p_game_version_id);
END $fn$;
REVOKE ALL ON FUNCTION public.my_psr_values_v3377(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.my_psr_values_v3377(uuid) TO authenticated;

-- Cache refill uses the SAME core function; no duplicate rating formula.
CREATE OR REPLACE FUNCTION public.refresh_user_summaries_batch_v363(p_search text,p_game_version_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
#variable_conflict use_column
DECLARE v_count integer:=0;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM public.game_versions WHERE id=p_game_version_id) THEN
  RAISE EXCEPTION '有効なゲームバージョンを選択してください。';
 END IF;
 WITH missing AS (
  SELECT p.id FROM public.profiles p
  WHERE p.username ILIKE '%'||coalesce(p_search,'')||'%'
  AND NOT EXISTS (SELECT 1 FROM public.user_summary_cache c
    WHERE c.user_id=p.id AND c.game_version_id=p_game_version_id AND c.calculation_revision>=2)
  AND (NOT EXISTS (SELECT 1 FROM public.admin_users a WHERE a.user_id=p.id)
    OR EXISTS (SELECT 1 FROM public.visible_admin_users a WHERE a.user_id=p.id))
  ORDER BY p.id LIMIT 1
 ), payload AS (
  SELECT m.id, coalesce(r.total,0) AS psr,cl.level,cl.updated_at FROM missing m
  LEFT JOIN LATERAL (
   SELECT max(total) AS total FROM public.psr_values_core_v3377(m.id,p_game_version_id)
  ) r ON true
  LEFT JOIN LATERAL (
   SELECT max(CASE us.chart::text WHEN 'LIGHT' THEN s.light_level
      WHEN 'NORMAL' THEN s.normal_level WHEN 'HYPER' THEN s.hyper_level
      WHEN 'EX' THEN s.ex_level END)::smallint AS level,
      max(us.updated_at) AS updated_at
   FROM public.user_scores us JOIN public.songs s ON s.id=us.song_id
   WHERE us.user_id=m.id AND lower(coalesce(us.medal_code::text,'none')) IN
    ('perfect','a','fc_1_5','b','fc_6_20','c','fc_21_plus','d',
     'clear_bad_1_5','e','clear_bad_6_20','f','clear_bad_21_plus','g')
  ) cl ON true
 )
 INSERT INTO public.user_summary_cache
   (user_id,game_version_id,pop_class,highest_clear_level,last_clear_updated_at,calculation_revision)
 SELECT p.id,p_game_version_id,p.psr,p.level,p.updated_at,2 FROM payload p
 ON CONFLICT (user_id,game_version_id) DO UPDATE SET
  pop_class=EXCLUDED.pop_class,highest_clear_level=EXCLUDED.highest_clear_level,
  last_clear_updated_at=EXCLUDED.last_clear_updated_at,calculation_revision=2;
 GET DIAGNOSTICS v_count=ROW_COUNT;
 RETURN v_count;
END $fn$;

CREATE OR REPLACE FUNCTION public.list_user_summaries_v31(p_search text,p_game_version_id uuid)
RETURNS TABLE(user_id uuid,username text,poptomo_id text,pop_class numeric,official_popn_class numeric,highest_clear_level smallint,updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
 SELECT p.id,p.username,CASE WHEN p.poptomo_public THEN p.poptomo_id ELSE NULL END,
 CASE WHEN p.psr_public THEN CASE WHEN c.calculation_revision>=2 THEN c.pop_class ELSE -1::numeric END ELSE NULL END,
 CASE WHEN p.popn_class_public THEN p.official_popn_class ELSE NULL END,
 CASE WHEN p.highest_clear_public THEN c.highest_clear_level ELSE NULL END,c.last_clear_updated_at
 FROM public.profiles p LEFT JOIN public.user_summary_cache c
   ON c.user_id=p.id AND c.game_version_id=p_game_version_id
 WHERE EXISTS(SELECT 1 FROM public.game_versions gv WHERE gv.id=p_game_version_id)
  AND p.username ILIKE '%'||coalesce(p_search,'')||'%'
  AND (NOT EXISTS (SELECT 1 FROM public.admin_users a WHERE a.user_id=p.id)
   OR EXISTS (SELECT 1 FROM public.visible_admin_users a WHERE a.user_id=p.id))
 ORDER BY p.username;
$fn$;
REVOKE ALL ON FUNCTION public.refresh_user_summaries_batch_v363(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_user_summaries_batch_v363(text,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.list_user_summaries_v31(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_user_summaries_v31(text,uuid) TO anon,authenticated;
COMMIT;
