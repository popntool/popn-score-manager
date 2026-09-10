-- v3.0.18 公式サイト同期の保存高速化
-- このファイル全体をSupabase SQL Editorで1回実行してください。
-- 全曲同期の仕様は変えず、master_key完全一致を先に使い、表記ゆれ照合だけをフォールバックにします。

create index if not exists songs_normalized_identity_idx
on public.songs (
  public.normalize_popn_text(genre),
  public.normalize_popn_text(title),
  public.normalize_popn_text(artist)
);

create index if not exists song_requests_sync_lookup_idx
on public.song_requests (
  user_id,
  status,
  public.normalize_popn_text(genre),
  public.normalize_popn_text(title),
  public.normalize_popn_text(artist),
  chart,
  level
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
  from jsonb_to_recordset(p_records) x(score integer)
  where coalesce(x.score,0)>0;

  -- 曲レベル補完。master_keyが一致する通常ケースでは正規化比較を行わない。
  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,medal_code text,rank_code text
    ) where coalesce(score,0)>0
  ), resolved as materialized (
    select x.*,coalesce(exact_song.id,fuzzy_song.id) song_id
    from input x
    left join public.songs exact_song on exact_song.master_key=x.master_key
    left join lateral (
      select s.id from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      limit 1
    ) fuzzy_song on true
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
    ex_level=coalesce(s.ex_level,m.ex_level),
    updated_at=now()
  from matched m where s.id=m.song_id;

  -- マスター未登録譜面だけ依頼へ追加。
  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,medal_code text,rank_code text
    ) where coalesce(score,0)>0
  ), unresolved as (
    select x.* from input x
    left join public.songs s on s.master_key=x.master_key
    where s.id is null
      and not exists (
        select 1 from public.songs f
        where public.normalize_popn_text(f.genre)=public.normalize_popn_text(x.genre)
          and public.normalize_popn_text(f.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(f.artist)=public.normalize_popn_text(x.artist)
      )
  )
  insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
  select auth.uid(),trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),x.level,
    '公式サイト同期で曲マスター未登録','pending'
  from unresolved x
  where coalesce(trim(x.genre),'')<>'' and coalesce(trim(x.title),'')<>'' and coalesce(trim(x.artist),'')<>''
    and upper(trim(x.chart)) in('LIGHT','NORMAL','HYPER','EX') and x.level between 1 and 50
    and not exists (
      select 1 from public.song_requests r
      where r.user_id=auth.uid() and r.status='pending'
        and public.normalize_popn_text(r.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(r.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(r.artist)=public.normalize_popn_text(x.artist)
        and r.chart=upper(trim(x.chart)) and r.level=x.level
    );

  -- スコア保存。ここも完全一致を最優先し、必要なレコードだけ表記ゆれ照合する。
  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,medal_code text,rank_code text
    ) where coalesce(score,0)>0
  ), resolved as materialized (
    select x.*,coalesce(exact_song.id,fuzzy_song.id) song_id
    from input x
    left join public.songs exact_song on exact_song.master_key=x.master_key
    left join lateral (
      select s.id from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      limit 1
    ) fuzzy_song on true
  )
  insert into public.user_scores(
    user_id,song_id,chart,score,official_score,manual_history_score,version_score,
    medal_code,rank_code,source
  )
  select auth.uid(),x.song_id,upper(x.chart),
    greatest(greatest(1,least(100000,x.score)),greatest(0,least(100000,coalesce(x.version_score,0)))),
    greatest(1,least(100000,x.score)),0,greatest(0,least(100000,coalesce(x.version_score,0))),
    coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from resolved x where x.song_id is not null
  on conflict(user_id,song_id,chart) do update set
    official_score=excluded.official_score,
    version_score=excluded.version_score,
    score=greatest(excluded.official_score,public.user_scores.manual_history_score,excluded.version_score),
    medal_code=excluded.medal_code,
    rank_code=excluded.rank_code,
    source='sync',updated_at=now();
  get diagnostics v_saved=row_count;

  -- 今回のユーザーの解決済み依頼だけを整理する。全ユーザー走査を毎バッチ行わない。
  delete from public.song_requests r
  where r.user_id=auth.uid() and r.status in('pending','approved')
    and exists (
      select 1 from public.songs s
      where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
    );

  return query select v_saved,greatest(0,v_total-v_saved);
end$$;

revoke all on function public.sync_my_scores(jsonb) from public;
grant execute on function public.sync_my_scores(jsonb) to authenticated;
