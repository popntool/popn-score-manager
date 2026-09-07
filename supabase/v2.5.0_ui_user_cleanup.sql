-- v2.5.0 ユーザー一覧・空の要望データ修正・管理者ユーザー削除
-- v2.4.0適用後、Supabase SQL Editorで全体を1回実行してください。

delete from public.feedback_reports where btrim(coalesce(message,''))='';
alter table public.feedback_reports drop constraint if exists feedback_reports_message_not_blank;
alter table public.feedback_reports add constraint feedback_reports_message_not_blank check(btrim(message)<>'');

drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,highest_clear_level smallint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  select p.id,p.username,case when p.poptomo_public then p.poptomo_id else null end,
         null::numeric,
         max(case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end)
           filter(where us.medal_code not in('none','f','failed_15_16','failed_12_14','failed_0_11')),
         max(us.updated_at)
  from public.profiles p
  left join public.user_scores us on us.user_id=p.id
  left join public.songs s on s.id=us.song_id
  where p.username ilike '%'||coalesce(p_search,'')||'%'
    and not exists(select 1 from public.admin_users a where a.user_id=p.id)
  group by p.id,p.username,p.poptomo_id,p.poptomo_public
  order by p.username
$$;
grant execute on function public.list_user_summaries(text) to anon,authenticated;

create or replace function public.admin_delete_user(p_user_id uuid)
returns boolean language plpgsql security definer set search_path=public,auth as $$
begin
  if not public.is_admin() then raise exception 'admin only';end if;
  if p_user_id=auth.uid() then raise exception '自分自身は削除できません。';end if;
  delete from auth.users where id=p_user_id;
  if not found then raise exception 'ユーザーが見つかりません。';end if;
  return true;
end$$;
revoke all on function public.admin_delete_user(uuid) from public;
grant execute on function public.admin_delete_user(uuid) to authenticated;
