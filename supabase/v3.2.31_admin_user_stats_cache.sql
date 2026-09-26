-- v3.2.31
-- 管理者ユーザーリストの集計をキャッシュ化し、毎回 user_scores 全体を集計しないようにする。
-- 初回実行時のみ既存データを集計してキャッシュを作成する。

create table if not exists public.admin_user_score_stats (
  user_id uuid primary key references auth.users(id) on delete cascade,
  registered_count bigint not null default 0,
  score_sum bigint not null default 0,
  last_updated_at timestamptz
);

alter table public.admin_user_score_stats enable row level security;

-- 既存データから初回キャッシュを作成／更新。
insert into public.admin_user_score_stats(user_id, registered_count, score_sum, last_updated_at)
select
  us.user_id,
  count(*)::bigint,
  coalesce(sum(us.score), 0)::bigint,
  max(us.updated_at)::timestamptz
from public.user_scores us
group by us.user_id
on conflict(user_id) do update set
  registered_count = excluded.registered_count,
  score_sum = excluded.score_sum,
  last_updated_at = excluded.last_updated_at;

-- スコア変更があったユーザーだけを再集計する。
create or replace function public.refresh_admin_user_score_stats_for_users(p_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if p_user_ids is null or cardinality(p_user_ids)=0 then
    return;
  end if;

  delete from public.admin_user_score_stats s
  where s.user_id = any(p_user_ids);

  insert into public.admin_user_score_stats(user_id, registered_count, score_sum, last_updated_at)
  select
    us.user_id,
    count(*)::bigint,
    coalesce(sum(us.score),0)::bigint,
    max(us.updated_at)::timestamptz
  from public.user_scores us
  where us.user_id = any(p_user_ids)
  group by us.user_id;
end;
$$;

-- INSERT は1文で追加されたユーザーだけ再集計。
create or replace function public.admin_user_score_stats_after_insert()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_ids uuid[];
begin
  select array_agg(distinct user_id) into v_ids from new_rows;
  perform public.refresh_admin_user_score_stats_for_users(v_ids);
  return null;
end;
$$;

-- UPDATE は更新前後に含まれるユーザーだけ再集計。
create or replace function public.admin_user_score_stats_after_update()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_ids uuid[];
begin
  select array_agg(distinct user_id) into v_ids
  from (
    select user_id from old_rows
    union
    select user_id from new_rows
  ) u;
  perform public.refresh_admin_user_score_stats_for_users(v_ids);
  return null;
end;
$$;

-- DELETE は削除対象ユーザーだけ再集計。
create or replace function public.admin_user_score_stats_after_delete()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_ids uuid[];
begin
  select array_agg(distinct user_id) into v_ids from old_rows;
  perform public.refresh_admin_user_score_stats_for_users(v_ids);
  return null;
end;
$$;

drop trigger if exists admin_user_score_stats_insert on public.user_scores;
create trigger admin_user_score_stats_insert
after insert on public.user_scores
referencing new table as new_rows
for each statement execute function public.admin_user_score_stats_after_insert();

drop trigger if exists admin_user_score_stats_update on public.user_scores;
create trigger admin_user_score_stats_update
after update on public.user_scores
referencing old table as old_rows new table as new_rows
for each statement execute function public.admin_user_score_stats_after_update();

drop trigger if exists admin_user_score_stats_delete on public.user_scores;
create trigger admin_user_score_stats_delete
after delete on public.user_scores
referencing old table as old_rows
for each statement execute function public.admin_user_score_stats_after_delete();

-- 管理者ユーザーリストはキャッシュだけを参照する。
create or replace function public.admin_list_users_v2(p_search text default '')
returns table(
  user_id uuid,
  username text,
  registered_count bigint,
  average_score integer,
  created_at timestamptz,
  last_updated_at timestamptz
)
language sql
stable
security definer
set search_path=public
as $$
  select
    p.id::uuid as user_id,
    p.username::text as username,
    coalesce(s.registered_count,0)::bigint as registered_count,
    case
      when coalesce(s.registered_count,0)>0
        then round(s.score_sum::numeric / s.registered_count)::integer
      else 0
    end as average_score,
    p.created_at::timestamptz as created_at,
    s.last_updated_at::timestamptz as last_updated_at
  from public.profiles p
  left join public.admin_user_score_stats s on s.user_id=p.id
  where public.is_admin()
    and p.username ilike '%' || coalesce(p_search,'') || '%'
  order by p.created_at desc
  limit 500;
$$;

grant execute on function public.admin_list_users_v2(text) to authenticated;
