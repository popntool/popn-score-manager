-- v3.0.22 公式同期: 曲マスターに本当に存在しない曲だけ登録依頼を作成
-- v3.0.21 のメダルのみ同期対応を維持しつつ、既存曲の誤依頼を防ぎます。
-- このファイル全体を Supabase SQL Editor で1回実行してください。

create index if not exists songs_normalized_identity_idx
on public.songs (
  public.normalize_popn_text(genre),
  public.normalize_popn_text(title),
  public.normalize_popn_text(artist)
);

create index if not exists songs_normalized_title_idx
on public.songs (public.normalize_popn_text(title));

create index if not exists song_requests_sync_lookup_idx
on public.song_requests (
  user_id,status,
  public.normalize_popn_text(genre),
  public.normalize_popn_text(title),
  public.normalize_popn_text(artist),
  chart,level
);

create or replace function public.sync_my_scores(p_records jsonb)
returns table(saved integer,unmatched integer)
language plpgsql security definer set search_path=public as $$
declare
  v_saved integer:=0;
  v_total integer:=0;
begin
  if auth.uid() is null then raise exception 'login required'; end if;

  select count(*) into v_total
  from jsonb_to_recordset(p_records) x(score integer,version_score integer,medal_code text,rank_code text)
  where coalesce(x.score,0)>0 or coalesce(x.version_score,0)>0
     or coalesce(nullif(lower(x.medal_code),'none'),'')<>''
     or coalesce(nullif(lower(x.rank_code),'none'),'')<>'';

  -- 解決順: master_key完全一致 -> 曲情報完全一致(正規化後) -> 正規化タイトルがマスター内で一意。
  -- タイトル一意のフォールバックは、公式側とマスター側のジャンル/アーティスト表記差で
  -- 既存曲が「未登録」と誤判定されるのを防ぐために使う。
  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
  ), resolved as materialized (
    select x.*,coalesce(exact_song.id,identity_song.id,title_song.id) song_id
    from input x
    left join public.songs exact_song on exact_song.master_key=x.master_key
    left join lateral (
      select s.id from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where exact_song.id is null and identity_song.id is null
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
      having count(*)=1
    ) title_song on true
  ), matched as (
    select song_id,
      max(level) filter(where upper(chart)='LIGHT') light_level,
      max(level) filter(where upper(chart)='NORMAL') normal_level,
      max(level) filter(where upper(chart)='HYPER') hyper_level,
      max(level) filter(where upper(chart)='EX') ex_level
    from resolved where song_id is not null group by song_id
  )
  update public.songs s set
    light_level=coalesce(s.light_level,m.light_level),
    normal_level=coalesce(s.normal_level,m.normal_level),
    hyper_level=coalesce(s.hyper_level,m.hyper_level),
    ex_level=coalesce(s.ex_level,m.ex_level),updated_at=now()
  from matched m where s.id=m.song_id;

  -- 上と同じ3段階照合を通しても解決できない曲だけ登録依頼にする。
  -- 同一曲の複数譜面は譜面ごとに依頼するが、同じ pending 依頼は重複作成しない。
  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
  ), unresolved as materialized (
    select x.* from input x
    where not exists(select 1 from public.songs s where s.master_key=x.master_key)
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
          and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      )
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        group by public.normalize_popn_text(s.title)
        having count(*)=1
      )
  )
  insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
  select auth.uid(),trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),x.level,
    '公式サイト同期で曲マスター未登録','pending'
  from unresolved x
  where coalesce(trim(x.genre),'')<>'' and coalesce(trim(x.title),'')<>'' and coalesce(trim(x.artist),'')<>''
    and upper(trim(x.chart)) in('LIGHT','NORMAL','HYPER','EX') and x.level between 1 and 50
    and not exists(
      select 1 from public.song_requests r
      where r.user_id=auth.uid() and r.status='pending'
        and public.normalize_popn_text(r.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(r.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(r.artist)=public.normalize_popn_text(x.artist)
        and upper(r.chart)=upper(trim(x.chart)) and r.level=x.level
    );

  -- スコア保存も同じ解決規則を使う。
  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
  ), resolved as materialized (
    select x.*,coalesce(exact_song.id,identity_song.id,title_song.id) song_id
    from input x
    left join public.songs exact_song on exact_song.master_key=x.master_key
    left join lateral (
      select s.id from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where exact_song.id is null and identity_song.id is null
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
      having count(*)=1
    ) title_song on true
  )
  insert into public.user_scores(
    user_id,song_id,chart,score,official_score,manual_history_score,version_score,
    medal_code,rank_code,source
  )
  select auth.uid(),x.song_id,upper(x.chart),
    greatest(greatest(0,least(100000,coalesce(x.score,0))),greatest(0,least(100000,coalesce(x.version_score,0)))),
    greatest(0,least(100000,coalesce(x.score,0))),0,greatest(0,least(100000,coalesce(x.version_score,0))),
    coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from resolved x where x.song_id is not null
  on conflict(user_id,song_id,chart) do update set
    official_score=excluded.official_score,
    version_score=excluded.version_score,
    score=greatest(excluded.official_score,public.user_scores.manual_history_score,excluded.version_score),
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,
    source='sync',updated_at=now();
  get diagnostics v_saved=row_count;

  -- 過去に誤って作られた依頼も、現在のマスターに解決できるものだけ整理する。
  delete from public.song_requests r
  where r.user_id=auth.uid() and r.status in('pending','approved')
    and (
      exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
          and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
      )
      or exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
        group by public.normalize_popn_text(s.title)
        having count(*)=1
      )
    );

  return query select v_saved,greatest(0,v_total-v_saved);
end$$;

revoke all on function public.sync_my_scores(jsonb) from public;
grant execute on function public.sync_my_scores(jsonb) to authenticated;
