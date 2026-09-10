-- v3.0.23 既存の登録依頼を曲マスターへ再照合・統合
-- Supabase SQL Editorで、このファイル全体を1回実行してください。
-- 曲マスターに既に存在する依頼は難易度レベルを補完して削除し、
-- 本当に未登録の曲だけ登録依頼として残します。

create or replace function public.merge_song_requests_into_master()
returns integer
language plpgsql security definer set search_path=public as $$
declare
  v_deleted integer:=0;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'admin only';
  end if;

  -- sync_my_scores と同じ3段階で既存曲を解決する。
  with request_match as materialized (
    select r.id,r.chart,r.level,
      coalesce(exact_song.id,identity_song.id,title_song.id) song_id
    from public.song_requests r
    left join public.songs exact_song
      on exact_song.master_key = encode(
        digest(lower(concat_ws('|',trim(r.genre),trim(r.title),trim(r.artist))),'sha256'),'hex'
      )
    left join lateral (
      select s.id
      from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where exact_song.id is null and identity_song.id is null
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
      having count(*)=1
    ) title_song on true
    where r.status in('pending','approved')
  ), matched as (
    select song_id,
      max(level) filter(where upper(chart)='LIGHT') light_level,
      max(level) filter(where upper(chart)='NORMAL') normal_level,
      max(level) filter(where upper(chart)='HYPER') hyper_level,
      max(level) filter(where upper(chart)='EX') ex_level
    from request_match
    where song_id is not null
    group by song_id
  )
  update public.songs s set
    light_level=coalesce(s.light_level,m.light_level),
    normal_level=coalesce(s.normal_level,m.normal_level),
    hyper_level=coalesce(s.hyper_level,m.hyper_level),
    ex_level=coalesce(s.ex_level,m.ex_level),
    updated_at=now()
  from matched m
  where s.id=m.song_id;

  -- 曲マスターに解決できた依頼を全ユーザー分まとめて削除する。
  with request_match as materialized (
    select r.id,
      coalesce(exact_song.id,identity_song.id,title_song.id) song_id
    from public.song_requests r
    left join public.songs exact_song
      on exact_song.master_key = encode(
        digest(lower(concat_ws('|',trim(r.genre),trim(r.title),trim(r.artist))),'sha256'),'hex'
      )
    left join lateral (
      select s.id
      from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where exact_song.id is null and identity_song.id is null
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
      having count(*)=1
    ) title_song on true
    where r.status in('pending','approved')
  )
  delete from public.song_requests r
  using request_match m
  where r.id=m.id and m.song_id is not null;

  get diagnostics v_deleted=row_count;
  return v_deleted;
end$$;

revoke all on function public.merge_song_requests_into_master() from public;
grant execute on function public.merge_song_requests_into_master() to authenticated;

-- 既に溜まっている依頼を即時整理。
select public.merge_song_requests_into_master() as merged_requests;
