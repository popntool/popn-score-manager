-- v2.3.0 手動登録を「今作スコア入力・歴代スコア自動更新」に変更
-- Supabase SQL Editorで、このファイル全体を1回実行してください。

create or replace function public.save_manual_score_v2(
  p_song_id uuid,
  p_chart text,
  p_version_score integer,
  p_medal_code text,
  p_rank_code text
)
returns boolean
language plpgsql
security invoker
set search_path=public
as $$
declare
  v_score integer:=greatest(0,least(100000,coalesce(p_version_score,0)));
begin
  if auth.uid() is null then raise exception 'login required';end if;

  insert into public.user_scores(
    user_id,song_id,chart,score,version_score,medal_code,rank_code,source
  ) values(
    auth.uid(),p_song_id,upper(p_chart),v_score,v_score,
    coalesce(nullif(p_medal_code,''),'none'),coalesce(nullif(p_rank_code,''),'E'),'manual'
  )
  on conflict(user_id,song_id,chart) do update
    set score=greatest(public.user_scores.score,excluded.version_score),
        version_score=excluded.version_score,
        medal_code=excluded.medal_code,
        rank_code=excluded.rank_code,
        source='manual',updated_at=now();
  return true;
end$$;

grant execute on function public.save_manual_score_v2(uuid,text,integer,text,text) to authenticated;
