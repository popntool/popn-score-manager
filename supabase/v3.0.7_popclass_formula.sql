-- v3.0.7 ポックラ計算式更新
-- Supabase SQL Editorで全体を1回実行してください。
-- 計算式:
-- (10000*レベル+今作スコア-50000+クリアボーナス)
-- / (10170-(10000*レベル+今作スコア-50000+クリアボーナス)/73) - 0.96
-- 最終結果を小数第3位で切り捨て（小数第2位まで保持）
-- ボーナス: FAILED=0 / EASY=2000 / ロングオフ=2500 / クリア=3000 / FC=4000 / PERFECT=5000

drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,highest_clear_level smallint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  with raw_values as(
    select us.user_id,us.updated_at,us.medal_code,coalesce(us.version_score,0) version_score,
      case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end level,
      gv.name='pop''n music 29 High☆Cheers!!' is_current,
      10000*(case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end)
      +coalesce(us.version_score,0)-50000
      +case
         when lower(us.medal_code) in('a','perfect') then 5000
         when lower(us.medal_code) in('b','c','d','fc_1_5','fc_6_20','fc_21_plus') then 4000
         when lower(us.medal_code) in('e','f','g','clear_bad_1_5','clear_bad_6_20','clear_bad_21_plus') then 3000
         when lower(us.medal_code) in('k','easy') then 2000
         when lower(us.medal_code)='long_off' then 2500
         else 0
       end x
    from public.user_scores us
    join public.songs s on s.id=us.song_id
    left join public.game_versions gv on gv.id=s.version_id
  ), chart_values as(
    select user_id,updated_at,medal_code,level,is_current,
      case when version_score=0 then 0::numeric
      else floor(((x::numeric/(10170-x::numeric/73)-0.96)*100))/100
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
