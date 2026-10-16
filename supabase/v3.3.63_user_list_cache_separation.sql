-- v3.3.63: only read cache in public list, refresh at most one missing user per call.
-- Uses the existing production PSR expression, supplied from pg_get_functiondef.
-- Apply before deploying frontend. No tables/scores are deleted.
BEGIN;
CREATE OR REPLACE FUNCTION public.refresh_user_summaries_batch_v363(p_search text, p_game_version_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE v_active public.game_versions%ROWTYPE;
        v_inserted integer := 0;
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
    ORDER BY p.id
    LIMIT 1
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

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END $function$;
CREATE OR REPLACE FUNCTION public.list_user_summaries_v31(p_search text,p_game_version_id uuid)
RETURNS TABLE(user_id uuid,username text,poptomo_id text,pop_class numeric,official_popn_class numeric,highest_clear_level smallint,updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
  SELECT p.id,p.username,
    CASE WHEN p.poptomo_public THEN p.poptomo_id ELSE NULL END,
    CASE WHEN p.psr_public THEN coalesce(c.pop_class, -1::numeric) ELSE NULL END,
    CASE WHEN p.popn_class_public THEN p.official_popn_class ELSE NULL END,
    CASE WHEN p.highest_clear_public THEN c.highest_clear_level ELSE NULL END,
    c.last_clear_updated_at
  FROM public.profiles p
  LEFT JOIN public.user_summary_cache c
    ON c.user_id=p.id AND c.game_version_id=p_game_version_id
  WHERE EXISTS (SELECT 1 FROM public.game_versions gv WHERE gv.id=p_game_version_id)
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
