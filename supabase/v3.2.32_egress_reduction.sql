-- v3.2.32: reduce admin-page egress by returning notice counts only.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_notice_counts_v32()
RETURNS TABLE(requests bigint,banners bigint,feedback bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=''
AS $fn$
  SELECT
    (SELECT count(*) FROM public.song_requests r WHERE lower(coalesce(r.status,'pending'))='pending')::bigint,
    (SELECT count(*) FROM public.banner_requests b WHERE lower(coalesce(b.status,'pending'))='pending' AND nullif(btrim(coalesce(b.image_path,'')),'') IS NOT NULL)::bigint,
    (SELECT count(*) FROM public.feedback_reports f WHERE lower(coalesce(f.status,'pending'))='pending' AND nullif(btrim(coalesce(f.message,'')),'') IS NOT NULL)::bigint
  WHERE EXISTS (SELECT 1 FROM public.admin_users a WHERE a.user_id=auth.uid());
$fn$;

REVOKE ALL ON FUNCTION public.admin_notice_counts_v32() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_notice_counts_v32() TO authenticated;

COMMIT;
