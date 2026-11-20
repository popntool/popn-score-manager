-- v3.3.81: Distinguish non-public fields from public but empty values.
-- Does not change scores, visibility settings, PSR calculations or caches.
BEGIN;
CREATE OR REPLACE FUNCTION public.list_user_summaries_v3381(
 p_search text,p_game_version_id uuid
) RETURNS TABLE(
 user_id uuid,username text,poptomo_id text,pop_class numeric,
 official_popn_class numeric,highest_clear_level smallint,updated_at timestamptz,
 poptomo_public boolean,psr_public boolean,popn_class_public boolean,highest_clear_public boolean
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
 SELECT p.id,p.username,
  CASE WHEN p.poptomo_public THEN p.poptomo_id ELSE NULL END,
  CASE WHEN p.psr_public THEN
   CASE WHEN c.calculation_revision>=3 THEN c.pop_class ELSE -1::numeric END
   ELSE NULL END,
  CASE WHEN p.popn_class_public THEN p.official_popn_class ELSE NULL END,
  CASE WHEN p.highest_clear_public THEN c.highest_clear_level ELSE NULL END,
  c.last_clear_updated_at,
  p.poptomo_public,p.psr_public,p.popn_class_public,p.highest_clear_public
 FROM public.profiles p
 LEFT JOIN public.user_summary_cache c
  ON c.user_id=p.id AND c.game_version_id=p_game_version_id
 WHERE EXISTS(SELECT 1 FROM public.game_versions gv WHERE gv.id=p_game_version_id)
  AND p.username ILIKE '%'||coalesce(p_search,'')||'%'
  AND (NOT EXISTS(SELECT 1 FROM public.admin_users a WHERE a.user_id=p.id)
    OR EXISTS(SELECT 1 FROM public.visible_admin_users a WHERE a.user_id=p.id))
 ORDER BY p.username;
$fn$;
REVOKE ALL ON FUNCTION public.list_user_summaries_v3381(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_user_summaries_v3381(text,uuid) TO anon,authenticated;
COMMIT;
