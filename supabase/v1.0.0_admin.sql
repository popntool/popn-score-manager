-- v0.2.1 / v0.3.0 から v1.0.0 への管理機能追加
-- 先に v0.3.0_version_score.sql を実行し、その後にこのファイル全体を実行してください。

create table if not exists public.game_versions(
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  slug text not null unique check(slug~'^[a-z0-9_-]+$'),
  sort_order integer not null default 0,
  is_current boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.songs add column if not exists version_id uuid references public.game_versions(id) on delete set null;
create index if not exists songs_version_idx on public.songs(version_id);

create table if not exists public.song_requests(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  genre text not null,title text not null,artist text not null,
  chart text not null check(chart in('LIGHT','NORMAL','HYPER','EX')),
  level smallint not null check(level between 1 and 50),note text not null default '',
  status text not null default 'pending' check(status in('pending','approved','rejected')),
  admin_note text not null default '',created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create index if not exists song_requests_status_idx on public.song_requests(status,created_at desc);
create table if not exists public.feedback_reports(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  category text not null check(category in('request','bug')),message text not null,
  page_url text not null default '',user_agent text not null default '',
  status text not null default 'pending' check(status in('pending','answered','resolved')),
  admin_reply text not null default '',created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create index if not exists feedback_status_idx on public.feedback_reports(status,created_at desc);

drop trigger if exists game_versions_touch on public.game_versions;create trigger game_versions_touch before update on public.game_versions for each row execute function public.touch_updated_at();
drop trigger if exists song_requests_touch on public.song_requests;create trigger song_requests_touch before update on public.song_requests for each row execute function public.touch_updated_at();
drop trigger if exists feedback_reports_touch on public.feedback_reports;create trigger feedback_reports_touch before update on public.feedback_reports for each row execute function public.touch_updated_at();

create or replace function public.enforce_single_current_version() returns trigger language plpgsql security definer set search_path=public as $$
begin if new.is_current then update public.game_versions set is_current=false where id<>new.id and is_current;end if;return new;end$$;
drop trigger if exists game_versions_single_current on public.game_versions;
create trigger game_versions_single_current before insert or update of is_current on public.game_versions for each row when(new.is_current) execute function public.enforce_single_current_version();

create or replace function public.save_manual_score(p_song_id uuid,p_score integer,p_medal_code text,p_rank_code text)
returns boolean language plpgsql security invoker set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'login required';end if;
  insert into public.user_scores(user_id,song_id,score,medal_code,rank_code,source)
  values(auth.uid(),p_song_id,greatest(0,least(100000,p_score)),coalesce(nullif(p_medal_code,''),'none'),coalesce(nullif(p_rank_code,''),'E'),'manual')
  on conflict(user_id,song_id) do update set score=excluded.score,medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='manual',updated_at=now();
  return true;
end$$;

create or replace function public.admin_list_songs(p_search text default '',p_offset integer default 0,p_limit integer default 300)
returns table(id uuid,master_key text,level smallint,genre text,title text,artist text,chart text,banner_url text,version_id uuid,version_name text,total_count bigint)
language sql stable security definer set search_path=public as $$
  select s.id,s.master_key,s.level,s.genre,s.title,s.artist,s.chart,s.banner_url,s.version_id,v.name,count(*) over()
  from public.songs s left join public.game_versions v on v.id=s.version_id
  where public.is_admin() and (coalesce(p_search,'')='' or concat_ws(' ',s.genre,s.title,s.artist,s.chart,v.name) ilike '%'||p_search||'%')
  order by s.title,s.chart offset greatest(p_offset,0) limit least(greatest(p_limit,1),500)
$$;
create or replace function public.admin_list_users(p_search text default '')
returns table(user_id uuid,username text,registered_count bigint,average_score integer,created_at timestamptz,last_updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  select p.id,p.username,count(us.id),coalesce(round(avg(us.score)),0)::integer,p.created_at,max(us.updated_at)
  from public.profiles p left join public.user_scores us on us.user_id=p.id
  where public.is_admin() and p.username ilike '%'||coalesce(p_search,'')||'%'
  group by p.id,p.username,p.created_at order by p.created_at desc limit 500
$$;

alter table public.game_versions enable row level security;alter table public.song_requests enable row level security;alter table public.feedback_reports enable row level security;
drop policy if exists versions_select_public on public.game_versions;create policy versions_select_public on public.game_versions for select to anon,authenticated using(true);
drop policy if exists versions_admin_insert on public.game_versions;create policy versions_admin_insert on public.game_versions for insert to authenticated with check(public.is_admin());
drop policy if exists versions_admin_update on public.game_versions;create policy versions_admin_update on public.game_versions for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists versions_admin_delete on public.game_versions;create policy versions_admin_delete on public.game_versions for delete to authenticated using(public.is_admin());
drop policy if exists song_requests_select on public.song_requests;create policy song_requests_select on public.song_requests for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists song_requests_insert on public.song_requests;create policy song_requests_insert on public.song_requests for insert to authenticated with check(user_id=auth.uid());
drop policy if exists song_requests_admin_update on public.song_requests;create policy song_requests_admin_update on public.song_requests for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists feedback_select on public.feedback_reports;create policy feedback_select on public.feedback_reports for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists feedback_insert on public.feedback_reports;create policy feedback_insert on public.feedback_reports for insert to authenticated with check(user_id=auth.uid());
drop policy if exists feedback_admin_update on public.feedback_reports;create policy feedback_admin_update on public.feedback_reports for update to authenticated using(public.is_admin()) with check(public.is_admin());
grant execute on function public.save_manual_score(uuid,integer,text,text) to authenticated;
grant execute on function public.admin_list_songs(text,integer,integer) to authenticated;
grant execute on function public.admin_list_users(text) to authenticated;
