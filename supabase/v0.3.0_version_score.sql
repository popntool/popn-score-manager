-- v0.3.0：今作スコア追加・0点記録削除
-- 既存プロジェクトのSQL Editorで1回実行してください。

alter table public.user_scores
  add column if not exists version_score integer not null default 0
  check(version_score between 0 and 100000);

delete from public.user_scores where score=0;

create or replace function public.sync_my_scores(p_records jsonb)
returns table(saved integer,unmatched integer)
language plpgsql security invoker set search_path=public as $$
declare v_saved integer;v_total integer;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  select count(*) into v_total
  from jsonb_to_recordset(p_records) as x(score integer)
  where coalesce(x.score,0)>0;

  insert into public.user_scores(user_id,song_id,score,version_score,medal_code,rank_code,source)
  select auth.uid(),s.id,greatest(1,least(100000,x.score)),greatest(0,least(100000,coalesce(x.version_score,0))),
    coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from jsonb_to_recordset(p_records) as x(master_key text,score integer,version_score integer,medal_code text,rank_code text)
  join public.songs s on s.master_key=x.master_key
  where coalesce(x.score,0)>0
  on conflict(user_id,song_id) do update set score=excluded.score,version_score=excluded.version_score,
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='sync',updated_at=now();
  get diagnostics v_saved=row_count;
  return query select v_saved,greatest(0,v_total-v_saved);
end$$;

grant execute on function public.sync_my_scores(jsonb) to authenticated;

