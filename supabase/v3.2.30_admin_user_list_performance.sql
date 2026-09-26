-- v3.2.30: 管理者ユーザーリストの集計対象を先に絞り、statement timeout を避ける
-- 既存の admin_list_users_v2 と同じ引数・返却列を維持するため、フロント側の変更は不要。

create index if not exists profiles_created_at_idx
  on public.profiles(created_at desc);

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
  with selected_profiles as materialized (
    select
      p.id,
      p.username,
      p.created_at
    from public.profiles p
    where public.is_admin()
      and p.username ilike '%' || coalesce(p_search,'') || '%'
    order by p.created_at desc
    limit 500
  ),
  score_stats as (
    select
      us.user_id,
      count(*)::bigint as registered_count,
      coalesce(round(avg(us.score)),0)::integer as average_score,
      max(us.updated_at)::timestamptz as last_updated_at
    from public.user_scores us
    join selected_profiles sp on sp.id=us.user_id
    group by us.user_id
  )
  select
    sp.id::uuid as user_id,
    sp.username::text as username,
    coalesce(ss.registered_count,0)::bigint as registered_count,
    coalesce(ss.average_score,0)::integer as average_score,
    sp.created_at::timestamptz as created_at,
    ss.last_updated_at::timestamptz as last_updated_at
  from selected_profiles sp
  left join score_stats ss on ss.user_id=sp.id
  order by sp.created_at desc;
$$;

grant execute on function public.admin_list_users_v2(text) to authenticated;
