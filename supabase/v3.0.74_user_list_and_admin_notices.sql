-- v3.0.74 ユーザーリスト最高クリア条件修正
-- 最高クリアは通常クリア以上のみ。EASY / ロングオフ / FAILED / 未プレーは除外。
-- X = 9402*レベル + 今作スコア - 50000
-- P = ROUNDDOWN(X / (6255 - X/145) - 5 + Bonus, 2)
-- 今作クリア状況Bonus: 未クリア/EASY=0 / CLEAR=5.1 / FULL COMBO=8.4 / PERFECT=11.8
-- 今作スコア50000未満は0。

drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,highest_clear_level smallint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  with raw_values as(
    select us.user_id,us.updated_at,us.medal_code,coalesce(us.version_score,0) version_score,
      case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end level,
      coalesce(gv.is_current,false) is_current,
      case lower(coalesce(us.current_clear_status,'failed'))
        when 'perfect' then 11.8
        when 'full_combo' then 8.4
        when 'clear' then 5.1
        else 0
      end clear_bonus
    from public.user_scores us
    join public.songs s on s.id=us.song_id
    left join public.game_versions gv on gv.id=s.version_id
  ), x_values as(
    select *, (9402*level::numeric + version_score::numeric - 50000) x
    from raw_values
  ), chart_values as(
    select user_id,updated_at,medal_code,level,is_current,
      case when version_score<50000 then 0::numeric
      else floor((x/(6255-x/145)-5+clear_bonus)*100)/100
      end song_pop_class
    from x_values
  ), ranked as(
    select *,row_number() over(partition by user_id,is_current order by song_pop_class desc) position
    from chart_values
  ), totals as(
    select user_id,
      floor((
        coalesce(sum(song_pop_class) filter(where is_current and position<=20),0)
        + coalesce(sum(song_pop_class) filter(where not is_current and position<=40),0)
      )/60*100)/100 pop_class
    from ranked
    group by user_id
  ), clears as(
    select user_id,max(level)::smallint highest_clear_level,max(updated_at) updated_at
    from chart_values
    where lower(medal_code) in('perfect','a','fc_1_5','b','fc_6_20','c','fc_21_plus','d','clear_bad_1_5','e','clear_bad_6_20','f','clear_bad_21_plus','g')
    group by user_id
  )
  select p.id,p.username,case when p.poptomo_public then p.poptomo_id else null end,
    coalesce(t.pop_class,0),c.highest_clear_level,c.updated_at
  from public.profiles p
  left join totals t on t.user_id=p.id
  left join clears c on c.user_id=p.id
  where p.username ilike '%'||coalesce(p_search,'')||'%'
    and not exists(select 1 from public.admin_users a where a.user_id=p.id)
  order by p.username
$$;

grant execute on function public.list_user_summaries(text) to anon,authenticated;
