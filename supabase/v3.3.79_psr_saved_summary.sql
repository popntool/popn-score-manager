-- v3.3.79: user-calculated PSR is persisted once, and public list reads it.
-- Execute before deploying the website. No stored scores, medals or snapshots are rewritten.
BEGIN;

CREATE OR REPLACE FUNCTION public.save_my_psr_summary_v3379(
 p_game_version_id uuid,p_psr numeric
) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE v_user uuid:=auth.uid();v_highest smallint;v_updated timestamptz;
BEGIN
 IF v_user IS NULL THEN RAISE EXCEPTION 'ログインが必要です。'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.game_versions WHERE id=p_game_version_id) THEN
  RAISE EXCEPTION 'ゲームバージョンが存在しません。'; END IF;
 IF p_psr IS NULL OR p_psr<0 OR p_psr>1000 OR p_psr<>trunc(p_psr,2) THEN
  RAISE EXCEPTION 'PSR値が不正です。'; END IF;
 -- This is highest clear LEVEL only; PSR is never calculated in SQL.
 SELECT max(CASE us.chart::text
   WHEN 'LIGHT' THEN s.light_level WHEN 'NORMAL' THEN s.normal_level
   WHEN 'HYPER' THEN s.hyper_level WHEN 'EX' THEN s.ex_level
   END)::smallint,max(us.updated_at)
 INTO v_highest,v_updated
 FROM public.user_scores us JOIN public.songs s ON s.id=us.song_id
 WHERE us.user_id=v_user AND lower(coalesce(us.medal_code::text,'none')) IN
  ('perfect','a','fc_1_5','b','fc_6_20','c','fc_21_plus','d',
   'clear_bad_1_5','e','clear_bad_6_20','f','clear_bad_21_plus','g');
 INSERT INTO public.user_summary_cache
  (user_id,game_version_id,pop_class,highest_clear_level,last_clear_updated_at,calculation_revision)
 VALUES(v_user,p_game_version_id,p_psr,v_highest,v_updated,3)
 ON CONFLICT (user_id,game_version_id) DO UPDATE SET
  pop_class=EXCLUDED.pop_class,highest_clear_level=EXCLUDED.highest_clear_level,
  last_clear_updated_at=EXCLUDED.last_clear_updated_at,calculation_revision=3;
 RETURN p_psr;
END $fn$;
REVOKE ALL ON FUNCTION public.save_my_psr_summary_v3379(uuid,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_my_psr_summary_v3379(uuid,numeric) TO authenticated;

-- Keep legacy RPC signature for compatibility with older tabs, but disable
-- old SQL recalculation so it cannot overwrite the JS-computed result.
CREATE OR REPLACE FUNCTION public.refresh_user_summaries_batch_v363(
 p_search text,p_game_version_id uuid
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 RETURN 0;
END $fn$;
REVOKE ALL ON FUNCTION public.refresh_user_summaries_batch_v363(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_user_summaries_batch_v363(text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.list_user_summaries_v31(
 p_search text,p_game_version_id uuid
) RETURNS TABLE(user_id uuid,username text,poptomo_id text,pop_class numeric,
 official_popn_class numeric,highest_clear_level smallint,updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
 SELECT p.id,p.username,
  CASE WHEN p.poptomo_public THEN p.poptomo_id ELSE NULL END,
  CASE WHEN p.psr_public THEN
   CASE WHEN c.calculation_revision>=3 THEN c.pop_class ELSE -1::numeric END
   ELSE NULL END,
  CASE WHEN p.popn_class_public THEN p.official_popn_class ELSE NULL END,
  CASE WHEN p.highest_clear_public THEN c.highest_clear_level ELSE NULL END,
  c.last_clear_updated_at
 FROM public.profiles p
 LEFT JOIN public.user_summary_cache c
  ON c.user_id=p.id AND c.game_version_id=p_game_version_id
 WHERE EXISTS(SELECT 1 FROM public.game_versions gv WHERE gv.id=p_game_version_id)
  AND p.username ILIKE '%'||coalesce(p_search,'')||'%'
  AND (NOT EXISTS(SELECT 1 FROM public.admin_users a WHERE a.user_id=p.id)
    OR EXISTS(SELECT 1 FROM public.visible_admin_users a WHERE a.user_id=p.id))
 ORDER BY p.username;
$fn$;
REVOKE ALL ON FUNCTION public.list_user_summaries_v31(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_user_summaries_v31(text,uuid) TO anon,authenticated;

-- Retire the server PSR formula. Old data is retained; no automatic backfill
-- is attempted with a different formula.
DROP FUNCTION IF EXISTS public.my_psr_values_v3377(uuid);
DROP FUNCTION IF EXISTS public.psr_values_core_v3377(uuid,uuid);
COMMIT;
