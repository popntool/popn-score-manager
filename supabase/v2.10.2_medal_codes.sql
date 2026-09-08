-- v2.10.2 公式FAILEDメダルコード（h / i / j）をクリア判定から除外
-- Supabase SQL Editorで、このファイル全体を1回実行してください。

drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,highest_clear_level smallint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  select p.id,p.username,case when p.poptomo_public then p.poptomo_id else null end,null::numeric,
    max(case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end)
      filter(where lower(us.medal_code) not in('none','h','i','j','l','m','n','failed_15_16','failed_12_14','failed_0_11')),
    max(us.updated_at)
  from public.profiles p left join public.user_scores us on us.user_id=p.id left join public.songs s on s.id=us.song_id
  where p.username ilike '%'||coalesce(p_search,'')||'%' and not exists(select 1 from public.admin_users a where a.user_id=p.id)
  group by p.id,p.username,p.poptomo_id,p.poptomo_public order by p.username
$$;
grant execute on function public.list_user_summaries(text) to anon,authenticated;
