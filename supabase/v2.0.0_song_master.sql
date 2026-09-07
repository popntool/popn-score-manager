-- v2.0.0 曲単位マスターへの移行（既存スコアを保持）
alter table public.user_scores rename to user_scores_chart_legacy;
alter table public.songs rename to songs_chart_legacy;

create table public.songs(
 id uuid primary key default gen_random_uuid(),master_key text not null unique check(master_key~'^[0-9a-f]{64}$'),
 genre text not null,title text not null,artist text not null,banner_url text not null default '',
 light_level smallint check(light_level between 1 and 50),normal_level smallint check(normal_level between 1 and 50),
 hyper_level smallint check(hyper_level between 1 and 50),ex_level smallint check(ex_level between 1 and 50),
 version_id uuid references public.game_versions(id) on delete set null,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(genre,title,artist)
);
insert into public.songs(master_key,genre,title,artist,banner_url,light_level,normal_level,hyper_level,ex_level,version_id)
select encode(digest(lower(concat_ws('|',genre,title,artist)),'sha256'),'hex'),genre,title,artist,max(banner_url),
 max(level) filter(where chart='LIGHT'),max(level) filter(where chart='NORMAL'),max(level) filter(where chart='HYPER'),max(level) filter(where chart='EX'),min(version_id::text)::uuid
from public.songs_chart_legacy group by genre,title,artist;

create table public.user_scores(
 id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id) on delete cascade,
 song_id uuid not null references public.songs(id) on delete cascade,chart text not null check(chart in('LIGHT','NORMAL','HYPER','EX')),
 score integer not null default 0 check(score between 0 and 100000),version_score integer not null default 0 check(version_score between 0 and 100000),
 medal_code text not null default 'none',rank_code text not null default 'none',source text not null default 'manual' check(source in('manual','sync')),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(user_id,song_id,chart)
);
insert into public.user_scores(id,user_id,song_id,chart,score,version_score,medal_code,rank_code,source,created_at,updated_at)
select us.id,us.user_id,s.id,l.chart,us.score,us.version_score,us.medal_code,us.rank_code,us.source,us.created_at,us.updated_at
from public.user_scores_chart_legacy us join public.songs_chart_legacy l on l.id=us.song_id
join public.songs s on s.genre=l.genre and s.title=l.title and s.artist=l.artist where us.score>0;
create index user_scores_v2_user_updated_idx on public.user_scores(user_id,updated_at desc);create index user_scores_v2_song_idx on public.user_scores(song_id);
create index songs_v2_title_idx on public.songs using gin(to_tsvector('simple',title));create index songs_v2_version_idx on public.songs(version_id);
create trigger songs_touch before update on public.songs for each row execute function public.touch_updated_at();create trigger user_scores_touch before update on public.user_scores for each row execute function public.touch_updated_at();

alter table public.songs enable row level security;alter table public.user_scores enable row level security;
grant select on public.songs to anon,authenticated;grant insert,update,delete on public.songs to authenticated;grant select on public.user_scores to anon,authenticated;grant insert,update,delete on public.user_scores to authenticated;
create policy songs_select_public on public.songs for select to anon,authenticated using(true);create policy songs_admin_insert on public.songs for insert to authenticated with check(public.is_admin());create policy songs_admin_update on public.songs for update to authenticated using(public.is_admin()) with check(public.is_admin());create policy songs_admin_delete on public.songs for delete to authenticated using(public.is_admin());
create policy user_scores_select_public on public.user_scores for select to anon,authenticated using(true);create policy user_scores_insert_own on public.user_scores for insert to authenticated with check(user_id=auth.uid());create policy user_scores_update_own on public.user_scores for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());create policy user_scores_delete_own on public.user_scores for delete to authenticated using(user_id=auth.uid());

create or replace function public.import_song_master(p_records jsonb) returns integer language plpgsql security definer set search_path=public as $$declare affected integer;begin
 if not public.is_admin() then raise exception 'admin only';end if;
 insert into public.songs(master_key,genre,title,artist,banner_url,light_level,normal_level,hyper_level,ex_level)
 select trim(x.master_key),trim(x.genre),trim(x.title),trim(x.artist),coalesce(x.banner_url,''),x.light_level,x.normal_level,x.hyper_level,x.ex_level
 from jsonb_to_recordset(p_records) as x(master_key text,genre text,title text,artist text,banner_url text,light_level smallint,normal_level smallint,hyper_level smallint,ex_level smallint)
 where x.master_key~'^[0-9a-f]{64}$'
 on conflict(genre,title,artist) do update set master_key=excluded.master_key,banner_url=excluded.banner_url,light_level=excluded.light_level,normal_level=excluded.normal_level,hyper_level=excluded.hyper_level,ex_level=excluded.ex_level;
 get diagnostics affected=row_count;return affected;end$$;
create or replace function public.save_manual_score(p_song_id uuid,p_chart text,p_score integer,p_medal_code text,p_rank_code text) returns boolean language plpgsql security invoker set search_path=public as $$begin
 if auth.uid() is null then raise exception 'login required';end if;
 insert into public.user_scores(user_id,song_id,chart,score,medal_code,rank_code,source) values(auth.uid(),p_song_id,upper(p_chart),greatest(0,least(100000,p_score)),p_medal_code,p_rank_code,'manual')
 on conflict(user_id,song_id,chart) do update set score=excluded.score,medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='manual',updated_at=now();return true;end$$;
create or replace function public.sync_my_scores(p_records jsonb) returns table(saved integer,unmatched integer) language plpgsql security invoker set search_path=public as $$declare v_saved integer;v_total integer;begin
 select count(*) into v_total from jsonb_to_recordset(p_records) x(score integer) where x.score>0;
 insert into public.user_scores(user_id,song_id,chart,score,version_score,medal_code,rank_code,source)
 select auth.uid(),s.id,upper(x.chart),x.score,coalesce(x.version_score,0),coalesce(x.medal_code,'none'),coalesce(x.rank_code,'none'),'sync'
 from jsonb_to_recordset(p_records) x(master_key text,chart text,score integer,version_score integer,medal_code text,rank_code text) join public.songs s on s.master_key=x.master_key where x.score>0
 on conflict(user_id,song_id,chart) do update set score=excluded.score,version_score=excluded.version_score,medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='sync',updated_at=now();
 get diagnostics v_saved=row_count;return query select v_saved,greatest(0,v_total-v_saved);end$$;
grant execute on function public.save_manual_score(uuid,text,integer,text,text) to authenticated;

drop table public.user_scores_chart_legacy cascade;drop table public.songs_chart_legacy cascade;
create or replace function public.list_user_summaries(p_search text default '') returns table(user_id uuid,username text,registered_count bigint,average_score integer,clear_count bigint,updated_at timestamptz) language sql stable security definer set search_path=public as $$select p.id,p.username,count(us.id),coalesce(round(avg(us.score)),0)::integer,count(us.id) filter(where us.medal_code not in('none','f')),max(us.updated_at) from public.profiles p left join public.user_scores us on us.user_id=p.id where p.username ilike '%'||coalesce(p_search,'')||'%' and not exists(select 1 from public.admin_users a where a.user_id=p.id) group by p.id,p.username order by avg(us.score) desc nulls last,p.username limit 500$$;
create or replace function public.admin_list_users(p_search text default '') returns table(user_id uuid,username text,registered_count bigint,average_score integer,created_at timestamptz,last_updated_at timestamptz) language sql stable security definer set search_path=public as $$select p.id,p.username,count(us.id),coalesce(round(avg(us.score)),0)::integer,p.created_at,max(us.updated_at) from public.profiles p left join public.user_scores us on us.user_id=p.id where public.is_admin() and p.username ilike '%'||coalesce(p_search,'')||'%' group by p.id,p.username,p.created_at order by p.created_at desc limit 500$$;
grant execute on function public.list_user_summaries(text) to anon,authenticated;grant execute on function public.admin_list_users(text) to authenticated;
