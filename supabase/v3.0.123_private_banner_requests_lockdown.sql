-- Phase 2: run ONLY after deploying and testing v3.0.123, and checking legacy approved URLs.
-- Stop if an already-approved song still points at the request bucket: migrate those images first.
do $$
begin
  if exists (
    select 1 from public.songs
    where banner_url like '%/storage/v1/object/public/banner-requests/%'
       or banner_url like '%/storage/v1/object/sign/banner-requests/%'
  ) then
    raise exception '承認済みの曲に banner-requests のURLが残っています。song-banners へ移行してから再実行してください。';
  end if;
end $$;

begin;
update storage.buckets set public = false where id = 'banner-requests';
drop policy if exists banner_requests_public_read on storage.objects;
commit;

-- Verify: banner-requests public=false; no public SELECT policy remains.
select id, public from storage.buckets where id in ('banner-requests','song-banners');
select policyname, cmd, roles, qual from pg_policies
where schemaname='storage' and tablename='objects' and policyname like 'banner_requests%';
