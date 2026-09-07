-- v2.2.0 マイページ（ユーザー名変更）
-- Supabase SQL Editorで、このファイル全体を1回実行してください。

create or replace function public.change_my_username(p_username text,p_login_email text)
returns boolean
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  v_name text:=trim(p_username);
begin
  if auth.uid() is null then raise exception 'login required';end if;
  if char_length(v_name)<1 or char_length(v_name)>32 then raise exception 'ユーザー名は1～32文字で入力してください。';end if;
  if p_login_email!~'^u_[0-9a-f]{64}@users[.]popn-score-manager[.]local$' then raise exception 'invalid login id';end if;
  if exists(select 1 from public.profiles where lower(username)=lower(v_name) and id<>auth.uid()) then raise exception 'そのユーザー名は既に使用されています。';end if;

  update public.profiles set username=v_name where id=auth.uid();
  update auth.users
     set email=p_login_email,
         raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||jsonb_build_object('username',v_name),
         updated_at=now()
   where id=auth.uid();
  update auth.identities
     set identity_data=jsonb_set(coalesce(identity_data,'{}'::jsonb),'{email}',to_jsonb(p_login_email),true),
         updated_at=now()
   where user_id=auth.uid() and provider='email';
  return true;
end$$;

revoke all on function public.change_my_username(text,text) from public;
grant execute on function public.change_my_username(text,text) to authenticated;

create or replace function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,registered_count bigint,average_score integer,clear_count bigint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  select p.id,p.username,count(us.id),coalesce(round(avg(us.score)),0)::integer,
         count(us.id) filter(where us.medal_code not in('none','f')),max(us.updated_at)
  from public.profiles p left join public.user_scores us on us.user_id=p.id
  where p.username ilike '%'||coalesce(p_search,'')||'%'
    and not exists(select 1 from public.admin_users a where a.user_id=p.id)
  group by p.id,p.username order by avg(us.score) desc nulls last,p.username
$$;
grant execute on function public.list_user_summaries(text) to anon,authenticated;
