-- v3.0.59 ポックラ計算式
-- 今作スコアが50000未満なら0。
-- 50000以上: 2.1*レベル + 0.00094*(今作スコア-50000) + クリアボーナス + 23
-- クリアボーナス: 未クリア=0 / クリア=5.0 / FULL COMBO=17.5 / PERFECT=24.0
-- 小数点第3位を最終結果で切り捨て、小数点2桁まで扱う。

drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,highest_clear_level smallint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  with raw_values as(
    select us.user_id,us.updated_at,us.medal_code,coalesce(us.version_score,0) version_score,
      case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end level,
      gv.name='pop''n music 29 High☆Cheers!!' is_current,
      case lower(coalesce(us.current_clear_status,'failed'))
        when 'perfect' then 24.0
        when 'full_combo' then 17.5
        when 'clear' then 5.0
        else 0.0
      end clear_bonus
    from public.user_scores us
    join public.songs s on s.id=us.song_id
    left join public.game_versions gv on gv.id=s.version_id
  ), chart_values as(
    select user_id,updated_at,medal_code,level,is_current,
      case when version_score<50000 then 0::numeric
      else floor((
        2.1*level::numeric
        +0.00094*(version_score::numeric-50000)
        +clear_bonus
        +23
      )*100)/100
      end song_pop_class
    from raw_values
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
