-- v3.0.107: rivals and server-enforced visibility. Apply after v3.0.106.
alter table public.profiles add column if not exists highest_clear_public boolean not null default true;
alter table public.profiles add column if not exists popn_class_public boolean not null default true;
alter table public.profiles add column if not exists psr_public boolean not null default true;
alter table public.profiles add column if not exists rival_scores_public boolean not null default false;
alter table public.profiles add column if not exists rival_medals_public boolean not null default false;
-- Existing public SELECT policies expose private columns and scores even if the UI hides them.
drop policy if exists profiles_select_public on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
drop policy if exists user_scores_select_public on public.user_scores;
create policy user_scores_select_own on public.user_scores for select to authenticated using(user_id=auth.uid() or public.is_admin());
-- Do not expose the old public aggregate endpoints with unrestricted private information.
-- Public user summaries below explicitly mask each optional metric.
create or replace function public.my_rivals()
returns table(user_id uuid,username text) language sql stable security definer set search_path=public as $$
 select p.id,p.username from public.user_favorites f join public.profiles p on p.id=f.favorite_user_id
 where f.user_id=auth.uid() order by f.created_at,p.username;
$$;
create or replace function public.toggle_my_rival(p_target uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare n integer;
begin
 if auth.uid() is null then raise exception 'login required'; end if;
 if p_target=auth.uid() then raise exception '自分自身は登録できません'; end if;
 if not exists(select 1 from public.profiles where id=p_target and not exists(select 1 from public.admin_users where user_id=p_target)) then raise exception 'ユーザーが見つかりません'; end if;
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
create or replace function public.update_my_visibility(p_poptomo_id text,p_poptomo_public boolean,p_highest_clear_public boolean,p_popn_class_public boolean,p_psr_public boolean,p_rival_scores_public boolean,p_rival_medals_public boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'login required'; end if;
 if p_poptomo_id is not null and p_poptomo_id !~ '^[0-9]{12}$' then raise exception 'ポプともIDは12桁で入力してください'; end if;
 update public.profiles set poptomo_id=p_poptomo_id,poptomo_public=coalesce(p_poptomo_public,false),highest_clear_public=coalesce(p_highest_clear_public,false),popn_class_public=coalesce(p_popn_class_public,false),psr_public=coalesce(p_psr_public,false),rival_scores_public=coalesce(p_rival_scores_public,false),rival_medals_public=coalesce(p_rival_medals_public,false) where id=auth.uid();
end$$;
create or replace function public.rival_song_scores(p_song_id uuid,p_chart text)
returns table(user_id uuid,username text,score integer,version_score integer,medal_code text)
language sql stable security definer set search_path=public as $$
 select p.id,p.username,case when p.rival_scores_public then us.score else null end,
 case when p.rival_scores_public then us.version_score else null end,
 case when p.rival_medals_public then us.medal_code else null end
 from public.user_favorites f join public.profiles p on p.id=f.favorite_user_id
 left join public.user_scores us on us.user_id=p.id and us.song_id=p_song_id and us.chart=p_chart
 where f.user_id=auth.uid() and (p.rival_scores_public or p.rival_medals_public)
 order by p.username;
$$;

-- Preserve the current 20/40 PSR calculation while masking non-public summary fields.
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
    and not exists(select 1 from public.admin_users a where a.user_id=p.id)
  order by p.username
$$;

grant execute on function public.list_user_summaries(text) to anon,authenticated;

revoke execute on function public.my_rivals() from public,anon;
revoke execute on function public.toggle_my_rival(uuid) from public,anon;
revoke execute on function public.update_my_visibility(text,boolean,boolean,boolean,boolean,boolean,boolean) from public,anon;
revoke execute on function public.rival_song_scores(uuid,text) from public,anon;
grant execute on function public.my_rivals(),public.toggle_my_rival(uuid),public.update_my_visibility(text,boolean,boolean,boolean,boolean,boolean,boolean),public.rival_song_scores(uuid,text) to authenticated;
-- Only the guarded RPC may mutate rival rows; direct inserts must not bypass the 10-person limit.
revoke insert,update,delete on public.user_favorites from public,anon,authenticated;
