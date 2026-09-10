-- v3.0.39: 管理者ユーザー一覧を安定したJSONオブジェクトで返す
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
    count(us.id)::bigint as registered_count,
    coalesce(round(avg(us.score)),0)::integer as average_score,
    p.created_at::timestamptz as created_at,
    max(us.updated_at)::timestamptz as last_updated_at
  from public.profiles p
  left join public.user_scores us on us.user_id=p.id
  where public.is_admin()
    and p.username ilike '%' || coalesce(p_search,'') || '%'
  group by p.id,p.username,p.created_at
  order by p.created_at desc
  limit 500;
$$;

grant execute on function public.admin_list_users_v2(text) to authenticated;
