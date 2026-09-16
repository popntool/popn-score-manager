-- v3.0.110: visibility defaults and visible operations administrator.
-- Preserve existing users' deliberate privacy choices; change defaults only for new profiles.
alter table public.profiles alter column highest_clear_public set default false;
alter table public.profiles alter column popn_class_public set default false;
alter table public.profiles alter column psr_public set default false;
alter table public.profiles alter column rival_scores_public set default false;
alter table public.profiles alter column rival_medals_public set default false;
alter table public.profiles alter column poptomo_public set default false;

-- Record the exact user UUID so changing a username cannot transfer privileges.
create table if not exists public.visible_admin_users (user_id uuid primary key references public.profiles(id) on delete cascade);
revoke all on public.visible_admin_users from public,anon,authenticated;
do $$
declare v_id uuid;
begin
 select id into v_id from public.profiles where username='FIZZ(運営)';
 if v_id is null then raise exception 'FIZZ(運営) のアカウントが見つかりません。ユーザー名を確認してから再実行してください。'; end if;
 insert into public.admin_users(user_id) values(v_id) on conflict do nothing;
 insert into public.visible_admin_users(user_id) values(v_id) on conflict do nothing;
end $$;

-- Permit adding the visible operations account as a rival.
create or replace function public.toggle_my_rival(p_target uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare n integer;
begin
 if auth.uid() is null then raise exception 'login required'; end if;
 if p_target=auth.uid() then raise exception '自分自身は登録できません'; end if;
 if not exists(select 1 from public.profiles p where p.id=p_target and (not exists(select 1 from public.admin_users a where a.user_id=p_target) or exists(select 1 from public.visible_admin_users v where v.user_id=p_target))) then raise exception 'ユーザーが見つかりません'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 delete from public.user_favorites where user_id=auth.uid() and favorite_user_id=p_target;
 if found then return false; end if;
 select count(*) into n from public.user_favorites where user_id=auth.uid();
 if n>=10 then raise exception 'ライバルは最大10人です'; end if;
 insert into public.user_favorites(user_id,favorite_user_id,sort_order)
 values(auth.uid(),p_target,(select coalesce(min(s),1) from generate_series(1,10) s where not exists(select 1 from public.user_favorites f where f.user_id=auth.uid() and f.sort_order=s)))
 on conflict(user_id,favorite_user_id) do nothing;
 return true;
end$$;

drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,official_popn_class numeric,highest_clear_level smallint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  with raw_values as(
    select us.user_id,us.updated_at,us.medal_code,coalesce(us.version_score,0) version_score,
      case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end level,
      coalesce(gv.is_current,false) is_current,
      lower(coalesce(us.current_clear_status,'failed')) current_clear_status,
      case lower(coalesce(us.current_clear_status,'failed'))
        when 'perfect' then 3000
        when 'full_combo' then 2000
        when 'clear' then 1000
        when 'long_off' then 300
        when 'easy' then 200
        else 0
      end clear_bonus
    from public.user_scores us
    join public.songs s on s.id=us.song_id
    left join public.game_versions gv on gv.id=s.version_id
  ), chart_values as(
    select user_id,updated_at,medal_code,level,is_current,
      case when current_clear_status='unplayed' then 0::numeric
      else floor((((level::numeric*level::numeric*version_score::numeric/6000)+clear_bonus)/200)*100)/100
      end song_psr
    from raw_values
  ), ranked as(
    select *,row_number() over(partition by user_id,is_current order by song_psr desc) position
    from chart_values
  ), totals as(
    select user_id,
      floor(((
        coalesce(sum(song_psr) filter(where is_current and position<=20),0)
        + coalesce(sum(song_psr) filter(where not is_current and position<=40),0)
      )/60)*100)/100 pop_class
    from ranked
    group by user_id
  ), clears as(
    select user_id,max(level)::smallint highest_clear_level,max(updated_at) updated_at
    from chart_values
    where lower(medal_code) in('perfect','a','fc_1_5','b','fc_6_20','c','fc_21_plus','d','clear_bad_1_5','e','clear_bad_6_20','f','clear_bad_21_plus','g')
    group by user_id
  )
  select p.id,p.username,case when p.poptomo_public then p.poptomo_id else null end,
    case when p.psr_public then coalesce(t.pop_class,0) else null end,case when p.popn_class_public then p.official_popn_class else null end,case when p.highest_clear_public then c.highest_clear_level else null end,c.updated_at
  from public.profiles p
  left join totals t on t.user_id=p.id
  left join clears c on c.user_id=p.id
  where p.username ilike '%'||coalesce(p_search,'')||'%'
    and (not exists(select 1 from public.admin_users a where a.user_id=p.id) or exists(select 1 from public.visible_admin_users v where v.user_id=p.id))
  order by p.username
$$;


