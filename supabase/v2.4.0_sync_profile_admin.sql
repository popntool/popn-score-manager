-- v2.4.0 未登録曲の登録依頼・ポプともID・管理者ユーザー削除
-- Supabase SQL Editorで、このファイル全体を1回実行してください。

alter table public.profiles
  add column if not exists poptomo_id text check(poptomo_id is null or poptomo_id~'^[0-9]{12}$'),
  add column if not exists poptomo_public boolean not null default false;

create or replace function public.update_my_poptomo(p_poptomo_id text,p_is_public boolean)
returns boolean language plpgsql security invoker set search_path=public as $$
declare v_id text:=nullif(trim(coalesce(p_poptomo_id,'')),'');
begin
  if auth.uid() is null then raise exception 'login required';end if;
  if v_id is not null and v_id!~'^[0-9]{12}$' then raise exception 'ポプともIDは12桁の数字で入力してください。';end if;
  update public.profiles set poptomo_id=v_id,poptomo_public=coalesce(p_is_public,false) where id=auth.uid();
  return true;
end$$;
grant execute on function public.update_my_poptomo(text,boolean) to authenticated;

drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,registered_count bigint,average_score integer,clear_count bigint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  select p.id,p.username,case when p.poptomo_public then p.poptomo_id else null end,
         count(us.id),coalesce(round(avg(us.score)),0)::integer,
         count(us.id) filter(where us.medal_code not in('none','f')),max(us.updated_at)
  from public.profiles p left join public.user_scores us on us.user_id=p.id
  where p.username ilike '%'||coalesce(p_search,'')||'%'
    and not exists(select 1 from public.admin_users a where a.user_id=p.id)
  group by p.id,p.username,p.poptomo_id,p.poptomo_public
  order by avg(us.score) desc nulls last,p.username
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

create or replace function public.sync_my_scores(p_records jsonb)
returns table(saved integer,unmatched integer)
language plpgsql security invoker set search_path=public as $$
declare v_saved integer;v_total integer;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  select count(*) into v_total from jsonb_to_recordset(p_records) x(score integer) where coalesce(x.score,0)>0;

  insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
  select auth.uid(),trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),x.level,
         '公式サイト同期で曲マスター未登録','pending'
  from jsonb_to_recordset(p_records) x(master_key text,genre text,title text,artist text,chart text,level smallint,score integer)
  left join public.songs s on s.master_key=x.master_key
  where coalesce(x.score,0)>0 and s.id is null
    and coalesce(trim(x.genre),'')<>'' and coalesce(trim(x.title),'')<>'' and coalesce(trim(x.artist),'')<>''
    and upper(trim(x.chart)) in('LIGHT','NORMAL','HYPER','EX') and x.level between 1 and 50
    and not exists(
      select 1 from public.song_requests r where r.user_id=auth.uid() and r.status='pending'
        and r.genre=trim(x.genre) and r.title=trim(x.title) and r.artist=trim(x.artist)
        and r.chart=upper(trim(x.chart)) and r.level=x.level
    );

  insert into public.user_scores(user_id,song_id,chart,score,version_score,medal_code,rank_code,source)
  select auth.uid(),s.id,upper(x.chart),greatest(1,least(100000,x.score)),
         greatest(0,least(100000,coalesce(x.version_score,0))),
         coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from jsonb_to_recordset(p_records) x(master_key text,chart text,score integer,version_score integer,medal_code text,rank_code text)
  join public.songs s on s.master_key=x.master_key where coalesce(x.score,0)>0
  on conflict(user_id,song_id,chart) do update set score=excluded.score,version_score=excluded.version_score,
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='sync',updated_at=now();
  get diagnostics v_saved=row_count;
  return query select v_saved,greatest(0,v_total-v_saved);
end$$;
grant execute on function public.sync_my_scores(jsonb) to authenticated;
