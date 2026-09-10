-- v3.0.52: バナー登録依頼の整合性修正
-- 画像が存在しない異常な依頼を掃除し、今後は画像アップロード済みの依頼だけ作成・表示する。

-- 1) 既存の異常データを削除
--    ・image_path が空
--    ・banner-requests Storage に実ファイルが存在しない
--    ・対象曲にすでにバナーが登録済み
with invalid_requests as (
  select r.id
  from public.banner_requests r
  join public.songs s on s.id = r.song_id
  where r.status = 'pending'
    and (
      coalesce(trim(r.image_path), '') = ''
      or coalesce(trim(s.banner_url), '') <> ''
      or not exists (
        select 1
        from storage.objects o
        where o.bucket_id = 'banner-requests'
          and o.name = r.image_path
      )
    )
)
delete from public.banner_requests r
using invalid_requests i
where r.id = i.id;

-- 2) クライアントから banner_requests へ直接 insert する経路を閉じる。
--    登録は submit_banner_request() RPC だけを使用する。
drop policy if exists banner_requests_insert on public.banner_requests;

-- 3) 送信RPCを強化
create or replace function public.submit_banner_request(p_song_id uuid,p_image_path text)
returns uuid
language plpgsql
security definer
set search_path=public,storage
as $$
declare
  v_id uuid;
  v_banner text;
  v_path text := trim(coalesce(p_image_path,''));
begin
  if auth.uid() is null then
    raise exception 'ログインが必要です。';
  end if;

  if v_path = '' or split_part(v_path,'/',1) <> auth.uid()::text then
    raise exception '画像データが不正です。';
  end if;

  if not exists (
    select 1
    from storage.objects o
    where o.bucket_id = 'banner-requests'
      and o.name = v_path
  ) then
    raise exception 'アップロード済みの画像が見つかりません。';
  end if;

  select banner_url into v_banner
  from public.songs
  where id = p_song_id;

  if not found then
    raise exception '曲が見つかりません。';
  end if;

  if coalesce(trim(v_banner),'') <> '' then
    raise exception 'この曲にはすでにバナーが登録されています。';
  end if;

  if exists (
    select 1
    from public.banner_requests
    where song_id = p_song_id
      and status = 'pending'
  ) then
    raise exception 'この曲のバナーはすでに申請中です。';
  end if;

  insert into public.banner_requests(user_id,song_id,image_path)
  values(auth.uid(),p_song_id,v_path)
  returning id into v_id;

  return v_id;
end
$$;

revoke all on function public.submit_banner_request(uuid,text) from public;
grant execute on function public.submit_banner_request(uuid,text) to authenticated;

-- 4) 管理画面には「pending + 画像実体あり + 曲にまだバナーなし」だけ返す。
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
language sql
stable
security definer
set search_path=public,storage
as $$
  select
    r.id,
    r.song_id,
    s.title,
    s.genre,
    s.artist,
    p.username,
    r.image_path,
    r.created_at
  from public.banner_requests r
  join public.songs s on s.id = r.song_id
  left join public.profiles p on p.id = r.user_id
  where public.is_admin()
    and r.status = 'pending'
    and coalesce(trim(r.image_path),'') <> ''
    and coalesce(trim(s.banner_url),'') = ''
    and exists (
      select 1
      from storage.objects o
      where o.bucket_id = 'banner-requests'
        and o.name = r.image_path
    )
    and (
      coalesce(p_search,'') = ''
      or s.title ilike '%' || p_search || '%'
      or s.genre ilike '%' || p_search || '%'
      or s.artist ilike '%' || p_search || '%'
      or coalesce(p.username,'') ilike '%' || p_search || '%'
    )
  order by r.created_at desc
  limit 500
$$;

revoke all on function public.admin_list_banner_requests(text) from public;
grant execute on function public.admin_list_banner_requests(text) to authenticated;

-- 5) ユーザー側プルダウンも、実画像付き pending 依頼だけを「申請中」とみなす。
create or replace function public.list_banner_request_songs()
returns table(id uuid,title text)
language sql
stable
security definer
set search_path=public,storage
as $$
  select s.id,s.title
  from public.songs s
  where auth.uid() is not null
    and coalesce(trim(s.banner_url),'') = ''
    and not exists (
      select 1
      from public.banner_requests r
      where r.song_id = s.id
        and r.status = 'pending'
        and coalesce(trim(r.image_path),'') <> ''
        and exists (
          select 1
          from storage.objects o
          where o.bucket_id = 'banner-requests'
            and o.name = r.image_path
        )
    )
  order by s.title collate "C"
$$;

revoke all on function public.list_banner_request_songs() from public;
grant execute on function public.list_banner_request_songs() to authenticated;

-- 実行結果確認用
select count(*) as valid_pending_banner_requests
from public.banner_requests r
join public.songs s on s.id = r.song_id
where r.status = 'pending'
  and coalesce(trim(r.image_path),'') <> ''
  and coalesce(trim(s.banner_url),'') = ''
  and exists (
    select 1
    from storage.objects o
    where o.bucket_id = 'banner-requests'
      and o.name = r.image_path
  );
