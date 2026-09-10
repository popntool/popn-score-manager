-- v3.0.42: ユーザーからのバナー画像登録依頼

create table if not exists public.banner_requests(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  song_id uuid not null references public.songs(id) on delete cascade,
  image_path text not null,
  status text not null default 'pending' check(status in('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists banner_requests_status_idx
  on public.banner_requests(status,created_at desc);
create unique index if not exists banner_requests_one_pending_per_song_idx
  on public.banner_requests(song_id) where status='pending';

drop trigger if exists banner_requests_touch on public.banner_requests;
create trigger banner_requests_touch
before update on public.banner_requests
for each row execute function public.touch_updated_at();

alter table public.banner_requests enable row level security;
drop policy if exists banner_requests_select on public.banner_requests;
create policy banner_requests_select on public.banner_requests
for select to authenticated
using(user_id=auth.uid() or public.is_admin());
drop policy if exists banner_requests_insert on public.banner_requests;
create policy banner_requests_insert on public.banner_requests
for insert to authenticated
with check(user_id=auth.uid());
drop policy if exists banner_requests_admin_update on public.banner_requests;
create policy banner_requests_admin_update on public.banner_requests
for update to authenticated
using(public.is_admin()) with check(public.is_admin());

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('banner-requests','banner-requests',true,2097152,array['image/png','image/jpeg','image/webp','image/gif'])
on conflict(id) do update set
  public=true,
  file_size_limit=2097152,
  allowed_mime_types=array['image/png','image/jpeg','image/webp','image/gif'];

drop policy if exists banner_requests_public_read on storage.objects;
create policy banner_requests_public_read on storage.objects
for select using(bucket_id='banner-requests');

drop policy if exists banner_requests_user_insert on storage.objects;
create policy banner_requests_user_insert on storage.objects
for insert to authenticated
with check(
  bucket_id='banner-requests'
  and (storage.foldername(name))[1]=auth.uid()::text
);

drop policy if exists banner_requests_user_delete on storage.objects;
create policy banner_requests_user_delete on storage.objects
for delete to authenticated
using(
  bucket_id='banner-requests'
  and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin())
);

create or replace function public.list_banner_request_songs()
returns table(id uuid,title text)
language sql stable security definer set search_path=public as $$
  select s.id,s.title
  from public.songs s
  where auth.uid() is not null
    and coalesce(trim(s.banner_url),'')=''
    and not exists(
      select 1 from public.banner_requests r
      where r.song_id=s.id and r.status='pending'
    )
  order by s.title collate "C"
$$;
revoke all on function public.list_banner_request_songs() from public;
grant execute on function public.list_banner_request_songs() to authenticated;

create or replace function public.submit_banner_request(p_song_id uuid,p_image_path text)
returns uuid
language plpgsql security definer set search_path=public,storage as $$
declare
  v_id uuid;
  v_banner text;
begin
  if auth.uid() is null then raise exception 'ログインが必要です。'; end if;
  if coalesce(trim(p_image_path),'')='' or split_part(p_image_path,'/',1)<>auth.uid()::text then
    raise exception '画像データが不正です。';
  end if;
  select banner_url into v_banner from public.songs where id=p_song_id;
  if not found then raise exception '曲が見つかりません。'; end if;
  if coalesce(trim(v_banner),'')<>'' then raise exception 'この曲にはすでにバナーが登録されています。'; end if;
  if exists(select 1 from public.banner_requests where song_id=p_song_id and status='pending') then
    raise exception 'この曲のバナーはすでに申請中です。';
  end if;
  insert into public.banner_requests(user_id,song_id,image_path)
  values(auth.uid(),p_song_id,p_image_path)
  returning id into v_id;
  return v_id;
end$$;
revoke all on function public.submit_banner_request(uuid,text) from public;
grant execute on function public.submit_banner_request(uuid,text) to authenticated;

create or replace function public.admin_list_banner_requests(p_search text default '')
returns table(
  id uuid,
  song_id uuid,
  title text,
  genre text,
  artist text,
  username text,
  image_path text,
  created_at timestamptz
)
language sql stable security definer set search_path=public as $$
  select r.id,r.song_id,s.title,s.genre,s.artist,p.username,r.image_path,r.created_at
  from public.banner_requests r
  join public.songs s on s.id=r.song_id
  left join public.profiles p on p.id=r.user_id
  where public.is_admin()
    and r.status='pending'
    and (
      coalesce(p_search,'')=''
      or s.title ilike '%'||p_search||'%'
      or s.genre ilike '%'||p_search||'%'
      or s.artist ilike '%'||p_search||'%'
      or coalesce(p.username,'') ilike '%'||p_search||'%'
    )
  order by r.created_at desc
  limit 500
$$;
revoke all on function public.admin_list_banner_requests(text) from public;
grant execute on function public.admin_list_banner_requests(text) to authenticated;

create or replace function public.approve_banner_request(p_request_id uuid,p_banner_url text)
returns boolean
language plpgsql security definer set search_path=public as $$
declare
  v_song_id uuid;
  v_status text;
  v_existing text;
begin
  if not public.is_admin() then raise exception '管理者権限が必要です。'; end if;
  if coalesce(trim(p_banner_url),'')='' then raise exception 'バナーURLが不正です。'; end if;

  select song_id,status into v_song_id,v_status
  from public.banner_requests where id=p_request_id for update;
  if not found then raise exception 'バナー依頼が見つかりません。'; end if;
  if v_status<>'pending' then raise exception 'この依頼は処理済みです。'; end if;

  select banner_url into v_existing from public.songs where id=v_song_id for update;
  if coalesce(trim(v_existing),'')<>'' then
    update public.banner_requests set status='rejected',updated_at=now() where id=p_request_id;
    raise exception 'この曲にはすでにバナーが登録されています。';
  end if;

  update public.songs set banner_url=trim(p_banner_url),updated_at=now() where id=v_song_id;
  update public.banner_requests set status='approved',updated_at=now() where id=p_request_id;
  return true;
end$$;
revoke all on function public.approve_banner_request(uuid,text) from public;
grant execute on function public.approve_banner_request(uuid,text) to authenticated;
