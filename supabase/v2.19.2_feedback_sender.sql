-- v2.19.2 管理画面の要望・不具合に送信者名を表示
-- Supabase SQL Editorで全体を1回実行してください。

create or replace function public.admin_list_feedback(p_search text default '')
returns table(
  id uuid,user_id uuid,username text,category text,message text,
  device_name text,browser_name text,page_url text,user_agent text,
  status text,admin_reply text,created_at timestamptz,updated_at timestamptz
)
language sql stable security definer set search_path=public as $$
  select f.id,f.user_id,coalesce(p.username,'不明'),f.category,f.message,
    f.device_name,f.browser_name,f.page_url,f.user_agent,
    f.status,f.admin_reply,f.created_at,f.updated_at
  from public.feedback_reports f
  left join public.profiles p on p.id=f.user_id
  where public.is_admin()
    and btrim(f.message)<>''
    and(
      coalesce(p_search,'')=''
      or f.message ilike '%'||p_search||'%'
      or p.username ilike '%'||p_search||'%'
    )
  order by f.created_at desc
  limit 500
$$;

revoke all on function public.admin_list_feedback(text) from public;
grant execute on function public.admin_list_feedback(text) to authenticated;
