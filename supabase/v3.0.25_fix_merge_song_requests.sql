-- v3.0.25 既存の登録依頼と曲マスターの統合処理を修正
-- pgcrypto/digest に依存せず、正規化した曲情報で既存曲を照合します。
-- Supabase SQL Editorで、このファイル全体を1回実行してください。

create or replace function public.merge_song_requests_into_master()
returns integer
language plpgsql security definer set search_path=public as $$
declare
  v_deleted integer:=0;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'admin only';
  end if;

  -- song_requests には master_key が無いため、digest() で再生成せず
  -- 1) ジャンル+曲名+アーティストの正規化一致
  -- 2) 正規化タイトルが曲マスター内で一意
  -- の順で既存曲を解決する。
  with request_match as materialized (
    select r.id,r.chart,r.level,
      coalesce(identity_song.id,title_song.id) song_id
    from public.song_requests r
    left join lateral (
      select s.id
      from public.songs s
      where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
      order by s.id
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where identity_song.id is null
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

  -- 曲マスターに解決できた既存の登録依頼だけ削除する。
  with request_match as materialized (
    select r.id,
      coalesce(identity_song.id,title_song.id) song_id
    from public.song_requests r
    left join lateral (
      select s.id
      from public.songs s
      where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
      order by s.id
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where identity_song.id is null
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
