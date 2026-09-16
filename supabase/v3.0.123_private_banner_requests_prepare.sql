-- Phase 1: run before deploying v3.0.123. Keep the bucket public until phase 2.
-- Allow signed URL creation and download for admins, including after the public read policy is removed.
drop policy if exists banner_requests_admin_read on storage.objects;
create policy banner_requests_admin_read on storage.objects
for select to authenticated
using (bucket_id = 'banner-requests' and public.is_admin());
