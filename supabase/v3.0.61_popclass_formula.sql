-- v3.0.61 ポックラ計算式
-- X = 20000*レベル + 今作スコア - 50000 + クリアボーナス
-- P = ROUNDDOWN(X / (14605.9 - X/116.29) - 1.376, 2)
-- クリアボーナス: 未クリア/EASY=0 / CLEAR=15000 / FULL COMBO=23000 / PERFECT=27000
-- 今作スコアが50000未満なら0。小数点第3位を最終結果で切り捨て。

drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,highest_clear_level smallint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  with raw_values as(
    select us.user_id,us.updated_at,us.medal_code,coalesce(us.version_score,0) version_score,
      case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end level,
      gv.name='pop''n music 29 High☆Cheers!!' is_current,
      case lower(coalesce(us.current_clear_status,'failed'))
        when 'perfect' then 27000
        when 'full_combo' then 23000
        when 'clear' then 15000
        else 0
      end clear_bonus
    from public.user_scores us
    join public.songs s on s.id=us.song_id
    left join public.game_versions gv on gv.id=s.version_id
  ), x_values as(
    select *, (20000*level::numeric + version_score::numeric - 50000 + clear_bonus) x
    from raw_values
  ), chart_values as(
    select user_id,updated_at,medal_code,level,is_current,
      case when version_score<50000 then 0::numeric
      else floor((x/(14605.9-x/116.29)-1.376)*100)/100
      end song_pop_class
    from x_values
  ), ranked as(
    select *,row_number() over(partition by user_id,is_current order by song_pop_class desc) position
    from chart_values
  ), totals as(
    select user_id,floor((sum(song_pop_class) filter(where position<=case when is_current then 20 else 40 end)/60)*100)/100 pop_class
    from ranked group by user_id
  ), clears as(
    select user_id,max(level)::smallint highest_clear_level,max(updated_at) updated_at
    from chart_values
    where lower(medal_code) not in('none','h','i','j','l','m','n','failed_15_16','failed_12_14','failed_0_11')
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
