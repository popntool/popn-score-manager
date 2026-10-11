-- v3.3.4
-- 管理者ユーザー一覧を30件ずつ取得し、全件取得によるstatement timeoutを防ぐ。

create or replace function public.admin_list_users_v3(
  p_search text default '',
  p_limit integer default 30,
  p_offset integer default 0
)
returns table(
  user_id uuid,
  username text,
  registered_count bigint,
  average_score integer,
  created_at timestamptz,
  last_updated_at timestamptz,
  total_count bigint
)
language sql
stable
security definer
set search_path=public
as $$
  with filtered as (
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
  )
  select
    f.user_id,
    f.username,
    f.registered_count,
    f.average_score,
    f.created_at,
    f.last_updated_at,
    count(*) over()::bigint as total_count
  from filtered f
  order by f.created_at desc
  limit greatest(1, least(coalesce(p_limit,30),100))
  offset greatest(coalesce(p_offset,0),0);
$$;

grant execute on function public.admin_list_users_v3(text,integer,integer) to authenticated;
