-- v2.19.1 曲マスター内の全角スペースを半角スペースへ統一
-- Supabase SQL Editorで全体を1回実行してください。

create temporary table song_space_merge on commit drop as
with ranked as(
  select id,
    first_value(id) over(
      partition by trim(replace(genre,'　',' ')),trim(replace(title,'　',' ')),trim(replace(artist,'　',' '))
      order by created_at,id
    ) keep_id
  from public.songs
)
select id drop_id,keep_id from ranked where id<>keep_id;

insert into public.user_scores(
  user_id,song_id,chart,score,official_score,manual_history_score,version_score,
  medal_code,rank_code,source,created_at,updated_at
)
select us.user_id,m.keep_id,us.chart,us.score,us.official_score,us.manual_history_score,us.version_score,
  us.medal_code,us.rank_code,us.source,us.created_at,us.updated_at
from public.user_scores us join song_space_merge m on m.drop_id=us.song_id
on conflict(user_id,song_id,chart) do update set
  score=greatest(public.user_scores.score,excluded.score),
  official_score=greatest(public.user_scores.official_score,excluded.official_score),
  manual_history_score=greatest(public.user_scores.manual_history_score,excluded.manual_history_score),
  version_score=greatest(public.user_scores.version_score,excluded.version_score),
  medal_code=case when excluded.updated_at>=public.user_scores.updated_at then excluded.medal_code else public.user_scores.medal_code end,
  rank_code=case when excluded.updated_at>=public.user_scores.updated_at then excluded.rank_code else public.user_scores.rank_code end,
  source=case when excluded.updated_at>=public.user_scores.updated_at then excluded.source else public.user_scores.source end,
  updated_at=greatest(public.user_scores.updated_at,excluded.updated_at);

delete from public.user_scores where song_id in(select drop_id from song_space_merge);
delete from public.songs where id in(select drop_id from song_space_merge);

update public.songs set
  master_key=trim(replace(master_key,'　',' ')),
  genre=trim(replace(genre,'　',' ')),
  title=trim(replace(title,'　',' ')),
  artist=trim(replace(artist,'　',' ')),
  banner_url=trim(replace(coalesce(banner_url,''),'　',' '))
where master_key like '%　%'
   or genre like '%　%'
   or title like '%　%'
   or artist like '%　%'
   or banner_url like '%　%';

create or replace function public.normalize_song_master_spaces()
returns trigger language plpgsql set search_path=public as $$
begin
  new.master_key:=trim(replace(new.master_key,'　',' '));
  new.genre:=trim(replace(new.genre,'　',' '));
  new.title:=trim(replace(new.title,'　',' '));
  new.artist:=trim(replace(new.artist,'　',' '));
  new.banner_url:=trim(replace(coalesce(new.banner_url,''),'　',' '));
  return new;
end$$;

drop trigger if exists songs_normalize_spaces on public.songs;
create trigger songs_normalize_spaces
before insert or update on public.songs
for each row execute function public.normalize_song_master_spaces();
