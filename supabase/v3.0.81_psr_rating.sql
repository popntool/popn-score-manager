-- v3.0.81 Popn Score Rating (PSR)
-- 曲別PSR = (レベル^2 * 今作スコア / 6000 + クリアボーナス) / 200
-- Bonus: FAILED=0 / EASY=200 / LONG OFF=300 / CLEAR=1000 / FULL COMBO=2000 / PERFECT=3000
-- TOTAL PSR = 新曲枠上位20曲 + 旧曲枠上位40曲 の合計 / 60（不足時も常に60で割る）

drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,highest_clear_level smallint,updated_at timestamptz)
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
    coalesce(t.pop_class,0),c.highest_clear_level,c.updated_at
  from public.profiles p
  left join totals t on t.user_id=p.id
  left join clears c on c.user_id=p.id
  where p.username ilike '%'||coalesce(p_search,'')||'%'
    and not exists(select 1 from public.admin_users a where a.user_id=p.id)
  order by p.username
$$;

grant execute on function public.list_user_summaries(text) to anon,authenticated;
