-- v2.6.0 公式歴代・手入力歴代・今作スコアの分離
-- Supabase SQL Editorで、このファイル全体を1回実行してください。

alter table public.user_scores
  add column if not exists official_score integer not null default 0 check(official_score between 0 and 100000),
  add column if not exists manual_history_score integer not null default 0 check(manual_history_score between 0 and 100000);

update public.user_scores
set official_score=case when source='sync' then score else official_score end,
    manual_history_score=case when source='manual' and score>version_score then score else manual_history_score end;

create or replace function public.save_manual_score_v3(
  p_song_id uuid,p_chart text,p_history_score integer,p_version_score integer,
  p_medal_code text,p_rank_code text
)
returns boolean language plpgsql security invoker set search_path=public as $$
declare
  v_history integer:=greatest(0,least(100000,coalesce(p_history_score,0)));
  v_version integer:=greatest(0,least(100000,coalesce(p_version_score,0)));
begin
  if auth.uid() is null then raise exception 'login required';end if;
  insert into public.user_scores(
    user_id,song_id,chart,score,official_score,manual_history_score,version_score,
    medal_code,rank_code,source
  ) values(
    auth.uid(),p_song_id,upper(p_chart),greatest(v_history,v_version),0,v_history,v_version,
    coalesce(nullif(p_medal_code,''),'none'),coalesce(nullif(p_rank_code,''),'E'),'manual'
  )
  on conflict(user_id,song_id,chart) do update
    set manual_history_score=excluded.manual_history_score,
        version_score=excluded.version_score,
        score=greatest(public.user_scores.official_score,excluded.manual_history_score,excluded.version_score),
        medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='manual',updated_at=now();
  return true;
end$$;
grant execute on function public.save_manual_score_v3(uuid,text,integer,integer,text,text) to authenticated;

create or replace function public.sync_my_scores(p_records jsonb)
returns table(saved integer,unmatched integer)
language plpgsql security invoker set search_path=public as $$
declare v_saved integer;v_total integer;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  select count(*) into v_total from jsonb_to_recordset(p_records) x(score integer) where coalesce(x.score,0)>0;

  insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
  select auth.uid(),trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),x.level,
         '公式サイト同期で曲マスター未登録','pending'
  from jsonb_to_recordset(p_records) x(master_key text,genre text,title text,artist text,chart text,level smallint,score integer)
  left join public.songs s on s.master_key=x.master_key
  where coalesce(x.score,0)>0 and s.id is null
    and coalesce(trim(x.genre),'')<>'' and coalesce(trim(x.title),'')<>'' and coalesce(trim(x.artist),'')<>''
    and upper(trim(x.chart)) in('LIGHT','NORMAL','HYPER','EX') and x.level between 1 and 50
    and not exists(
      select 1 from public.song_requests r where r.user_id=auth.uid() and r.status='pending'
        and r.genre=trim(x.genre) and r.title=trim(x.title) and r.artist=trim(x.artist)
        and r.chart=upper(trim(x.chart)) and r.level=x.level
    );

  insert into public.user_scores(
    user_id,song_id,chart,score,official_score,manual_history_score,version_score,
    medal_code,rank_code,source
  )
  select auth.uid(),s.id,upper(x.chart),
         greatest(greatest(1,least(100000,x.score)),greatest(0,least(100000,coalesce(x.version_score,0)))),
         greatest(1,least(100000,x.score)),0,greatest(0,least(100000,coalesce(x.version_score,0))),
         coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from jsonb_to_recordset(p_records) x(master_key text,chart text,score integer,version_score integer,medal_code text,rank_code text)
  join public.songs s on s.master_key=x.master_key where coalesce(x.score,0)>0
  on conflict(user_id,song_id,chart) do update
    set official_score=excluded.official_score,
        version_score=excluded.version_score,
        score=greatest(excluded.official_score,public.user_scores.manual_history_score,excluded.version_score),
        medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='sync',updated_at=now();
  get diagnostics v_saved=row_count;
  return query select v_saved,greatest(0,v_total-v_saved);
end$$;
grant execute on function public.sync_my_scores(jsonb) to authenticated;
