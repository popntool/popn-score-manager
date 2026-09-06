-- pop'n Score Manager 初期スキーマ v0.2.0
-- 新規SupabaseプロジェクトのSQL Editorで、このファイル全体を1回実行してください。

create extension if not exists pgcrypto;

create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check(char_length(username) between 1 and 32),
  theme text not null default 'light' check(theme in('light','dark')),
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.admin_users(user_id uuid primary key references auth.users(id) on delete cascade,created_at timestamptz not null default now());
create table if not exists public.songs(
  id uuid primary key default gen_random_uuid(),master_key text not null unique check(master_key~'^[0-9a-f]{64}$'),
  level smallint not null check(level between 1 and 50),genre text not null,title text not null,artist text not null,
  chart text not null check(chart in('LIGHT','NORMAL','HYPER','EX')),banner_url text not null default '',
  created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(genre,title,artist,chart,level)
);
create index if not exists songs_title_idx on public.songs using gin(to_tsvector('simple',title));
create index if not exists songs_level_chart_idx on public.songs(level,chart);
create table if not exists public.user_scores(
  id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id) on delete cascade,
  song_id uuid not null references public.songs(id) on delete cascade,score integer not null default 0 check(score between 0 and 100000),
  medal_code text not null default 'none',rank_code text not null default 'none',source text not null default 'manual' check(source in('manual','sync')),
  created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(user_id,song_id)
);
create index if not exists user_scores_user_updated_idx on public.user_scores(user_id,updated_at desc);
create index if not exists user_scores_song_idx on public.user_scores(song_id);
create table if not exists public.user_favorites(
  user_id uuid not null references auth.users(id) on delete cascade,favorite_user_id uuid not null references auth.users(id) on delete cascade,
  sort_order smallint not null default 1 check(sort_order between 1 and 10),created_at timestamptz not null default now(),
  primary key(user_id,favorite_user_id),check(user_id<>favorite_user_id)
);

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public
as $$select exists(select 1 from public.admin_users where user_id=auth.uid())$$;
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.profiles(id,username) values(new.id,coalesce(nullif(trim(new.raw_user_meta_data->>'username'),''),'USER-'||left(new.id::text,8))) on conflict(id) do nothing;return new;end$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$begin new.updated_at=now();return new;end$$;
drop trigger if exists profiles_touch on public.profiles;create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists songs_touch on public.songs;create trigger songs_touch before update on public.songs for each row execute function public.touch_updated_at();
drop trigger if exists user_scores_touch on public.user_scores;create trigger user_scores_touch before update on public.user_scores for each row execute function public.touch_updated_at();

create or replace function public.import_song_master(p_records jsonb) returns integer language plpgsql security definer set search_path=public as $$
declare affected integer;
begin
  if not public.is_admin() then raise exception 'admin only';end if;
  insert into public.songs(master_key,level,genre,title,artist,chart,banner_url)
  select trim(x.master_key),x.level,trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),coalesce(x.banner_url,'')
  from jsonb_to_recordset(p_records) as x(master_key text,level smallint,genre text,title text,artist text,chart text,banner_url text)
  where x.master_key~'^[0-9a-f]{64}$' and x.level between 1 and 50 and upper(trim(x.chart)) in('LIGHT','NORMAL','HYPER','EX')
  on conflict(master_key) do update set level=excluded.level,genre=excluded.genre,title=excluded.title,artist=excluded.artist,chart=excluded.chart,banner_url=excluded.banner_url;
  get diagnostics affected=row_count;return affected;
end$$;
create or replace function public.sync_my_scores(p_records jsonb)
returns table(saved integer,unmatched integer) language plpgsql security invoker set search_path=public as $$
declare v_saved integer;v_total integer;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  select count(*) into v_total from jsonb_array_elements(p_records);
  insert into public.user_scores(user_id,song_id,score,medal_code,rank_code,source)
  select auth.uid(),s.id,greatest(0,least(100000,x.score)),coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from jsonb_to_recordset(p_records) as x(master_key text,score integer,medal_code text,rank_code text) join public.songs s on s.master_key=x.master_key
  on conflict(user_id,song_id) do update set score=excluded.score,medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='sync',updated_at=now();
  get diagnostics v_saved=row_count;return query select v_saved,greatest(0,v_total-v_saved);
end$$;
create or replace function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,registered_count bigint,average_score integer,clear_count bigint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  select p.id,p.username,count(us.id),coalesce(round(avg(us.score)),0)::integer,count(us.id) filter(where us.medal_code not in('none','f')),max(us.updated_at)
  from public.profiles p left join public.user_scores us on us.user_id=p.id
  where p.username ilike '%'||coalesce(p_search,'')||'%' and not exists(select 1 from public.admin_users a where a.user_id=p.id)
  group by p.id,p.username order by avg(us.score) desc nulls last,p.username asc limit 500
$$;

alter table public.profiles enable row level security;alter table public.admin_users enable row level security;alter table public.songs enable row level security;alter table public.user_scores enable row level security;alter table public.user_favorites enable row level security;
create policy profiles_select_public on public.profiles for select to anon,authenticated using(true);
create policy profiles_update_own on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy admin_users_select_own on public.admin_users for select to authenticated using(user_id=auth.uid());
create policy songs_select_public on public.songs for select to anon,authenticated using(true);
create policy songs_admin_insert on public.songs for insert to authenticated with check(public.is_admin());
create policy songs_admin_update on public.songs for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy songs_admin_delete on public.songs for delete to authenticated using(public.is_admin());
create policy user_scores_select_public on public.user_scores for select to anon,authenticated using(true);
create policy user_scores_insert_own on public.user_scores for insert to authenticated with check(user_id=auth.uid());
create policy user_scores_update_own on public.user_scores for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy user_scores_delete_own on public.user_scores for delete to authenticated using(user_id=auth.uid());
create policy favorites_select_own on public.user_favorites for select to authenticated using(user_id=auth.uid());
create policy favorites_insert_own on public.user_favorites for insert to authenticated with check(user_id=auth.uid());
create policy favorites_update_own on public.user_favorites for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy favorites_delete_own on public.user_favorites for delete to authenticated using(user_id=auth.uid());
grant execute on function public.is_admin() to authenticated;
grant execute on function public.import_song_master(jsonb) to authenticated;
grant execute on function public.sync_my_scores(jsonb) to authenticated;
grant execute on function public.list_user_summaries(text) to anon,authenticated;

-- 管理者登録は、サイトで最初のユーザーを作成した後に行います。
-- insert into public.admin_users(user_id) values('管理者ユーザーのUUID');

