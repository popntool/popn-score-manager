-- v3.0.106: 既存曲のタイトル一意照合を依頼送信時にも適用し、既存の保留依頼を整理します。
-- Supabase SQL Editorで全体を一度実行してください。

create or replace function public.submit_song_request_v2(
  p_genre text,p_title text,p_artist text,p_chart text,p_level integer,p_note text default ''
) returns text language plpgsql security definer set search_path=public as $$
declare v_song_id uuid;v_chart text:=upper(trim(p_chart));v_level integer:=p_level;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  if coalesce(trim(p_genre),'')='' or coalesce(trim(p_title),'')='' or coalesce(trim(p_artist),'')='' then raise exception '曲情報を入力してください。';end if;
  if v_chart not in('LIGHT','NORMAL','HYPER','EX') or v_level not between 1 and 50 then raise exception '譜面またはレベルが不正です。';end if;
  select id into v_song_id from public.songs
   where public.normalize_popn_text(genre)=public.normalize_popn_text(p_genre)
     and public.normalize_popn_text(title)=public.normalize_popn_text(p_title)
     and public.normalize_popn_text(artist)=public.normalize_popn_text(p_artist) limit 1;
  -- ジャンルやアーティストの表記が異なっても、曲名が一意なら既存曲を使用。
  if v_song_id is null then
    select min(s.id::text)::uuid into v_song_id from public.songs s
    where public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title)
    having count(*)=1;
  end if;
  if v_song_id is not null then
    update public.songs set
      light_level=case when v_chart='LIGHT' then coalesce(light_level,v_level) else light_level end,
      normal_level=case when v_chart='NORMAL' then coalesce(normal_level,v_level) else normal_level end,
      hyper_level=case when v_chart='HYPER' then coalesce(hyper_level,v_level) else hyper_level end,
      ex_level=case when v_chart='EX' then coalesce(ex_level,v_level) else ex_level end,
      updated_at=now()
    where id=v_song_id;
    -- 既存曲と確定した同名の保留依頼を整理する（同名異曲は一意判定で除外）。
    delete from public.song_requests r where r.status in('pending','approved')
      and public.normalize_popn_text(r.title)=public.normalize_popn_text(p_title)
      and (select count(*) from public.songs s
           where public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title))=1;
    return 'merged';
  end if;
  if not exists(select 1 from public.song_requests where user_id=auth.uid() and status='pending'
    and public.normalize_popn_text(genre)=public.normalize_popn_text(p_genre)
    and public.normalize_popn_text(title)=public.normalize_popn_text(p_title)
    and public.normalize_popn_text(artist)=public.normalize_popn_text(p_artist)
    and chart=v_chart and level=v_level) then
    insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
    values(auth.uid(),trim(p_genre),trim(p_title),trim(p_artist),v_chart,v_level,coalesce(p_note,''),'pending');
  end if;
  return 'requested';
end$$;
revoke all on function public.submit_song_request_v2(text,text,text,text,integer,text) from public;
grant execute on function public.submit_song_request_v2(text,text,text,text,integer,text) to authenticated;

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


select public.merge_song_requests_into_master();
