-- v3.0.55 今作クリア状況を保存し、ポックラのクリアボーナス判定を歴代メダルから分離
-- Supabase SQL Editorで全体を1回実行してください。
-- current_clear_status: failed / clear / full_combo / perfect

alter table public.user_scores
  add column if not exists current_clear_status text not null default 'failed';

alter table public.user_scores
  drop constraint if exists user_scores_current_clear_status_check;
alter table public.user_scores
  add constraint user_scores_current_clear_status_check
  check (current_clear_status in ('failed','clear','full_combo','perfect'));

-- 手動登録。歴代メダルは従来どおり保存するが、ポックラ用の今作クリア状況は別列に保存する。
drop function if exists public.save_manual_score_v3(uuid,text,integer,integer,text,text);
drop function if exists public.save_manual_score_v3(uuid,text,integer,integer,text,text,text);
create function public.save_manual_score_v3(
  p_song_id uuid,p_chart text,p_history_score integer,p_version_score integer,
  p_medal_code text,p_rank_code text,p_current_clear_status text
)
returns boolean language plpgsql security invoker set search_path=public as $$
declare
  v_history integer:=greatest(0,least(100000,coalesce(p_history_score,0)));
  v_version integer:=greatest(0,least(100000,coalesce(p_version_score,0)));
  v_status text:=case lower(coalesce(p_current_clear_status,''))
    when 'perfect' then 'perfect'
    when 'full_combo' then 'full_combo'
    when 'clear' then 'clear'
    else 'failed'
  end;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  insert into public.user_scores(
    user_id,song_id,chart,score,official_score,manual_history_score,version_score,
    current_clear_status,medal_code,rank_code,source
  ) values(
    auth.uid(),p_song_id,upper(p_chart),greatest(v_history,v_version),0,v_history,v_version,
    v_status,coalesce(nullif(p_medal_code,''),'none'),coalesce(nullif(p_rank_code,''),'E'),'manual'
  )
  on conflict(user_id,song_id,chart) do update
    set manual_history_score=excluded.manual_history_score,
        version_score=excluded.version_score,
        score=greatest(public.user_scores.official_score,excluded.manual_history_score,excluded.version_score),
        current_clear_status=excluded.current_clear_status,
        medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='manual',updated_at=now();
  return true;
end$$;
grant execute on function public.save_manual_score_v3(uuid,text,integer,integer,text,text,text) to authenticated;

-- 公式同期。v3.0.22の曲マスター照合仕様を維持し、今作クリア状況を追加保存する。
create or replace function public.sync_my_scores(p_records jsonb)
returns table(saved integer,unmatched integer)
language plpgsql security definer set search_path=public as $$
declare
  v_saved integer:=0;
  v_total integer:=0;
begin
  if auth.uid() is null then raise exception 'login required'; end if;

  select count(*) into v_total
  from jsonb_to_recordset(p_records) x(score integer,version_score integer,medal_code text,rank_code text)
  where coalesce(x.score,0)>0 or coalesce(x.version_score,0)>0
     or coalesce(nullif(lower(x.medal_code),'none'),'')<>''
     or coalesce(nullif(lower(x.rank_code),'none'),'')<>'';

  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,current_clear_status text,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
  ), resolved as materialized (
    select x.*,coalesce(exact_song.id,identity_song.id,title_song.id) song_id
    from input x
    left join public.songs exact_song on exact_song.master_key=x.master_key
    left join lateral (
      select s.id from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where exact_song.id is null and identity_song.id is null
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
      having count(*)=1
    ) title_song on true
  ), matched as (
    select song_id,
      max(level) filter(where upper(chart)='LIGHT') light_level,
      max(level) filter(where upper(chart)='NORMAL') normal_level,
      max(level) filter(where upper(chart)='HYPER') hyper_level,
      max(level) filter(where upper(chart)='EX') ex_level
    from resolved where song_id is not null group by song_id
  )
  update public.songs s set
    light_level=coalesce(s.light_level,m.light_level),
    normal_level=coalesce(s.normal_level,m.normal_level),
    hyper_level=coalesce(s.hyper_level,m.hyper_level),
    ex_level=coalesce(s.ex_level,m.ex_level),updated_at=now()
  from matched m where s.id=m.song_id;

  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,current_clear_status text,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
  ), unresolved as materialized (
    select x.* from input x
    where not exists(select 1 from public.songs s where s.master_key=x.master_key)
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
          and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      )
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        group by public.normalize_popn_text(s.title)
        having count(*)=1
      )
  )
  insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
  select auth.uid(),trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),x.level,
    '公式サイト同期で曲マスター未登録','pending'
  from unresolved x
  where coalesce(trim(x.genre),'')<>'' and coalesce(trim(x.title),'')<>'' and coalesce(trim(x.artist),'')<>''
    and upper(trim(x.chart)) in('LIGHT','NORMAL','HYPER','EX') and x.level between 1 and 50
    and not exists(
      select 1 from public.song_requests r
      where r.user_id=auth.uid() and r.status='pending'
        and public.normalize_popn_text(r.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(r.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(r.artist)=public.normalize_popn_text(x.artist)
        and upper(r.chart)=upper(trim(x.chart)) and r.level=x.level
    );

  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,current_clear_status text,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
  ), resolved as materialized (
    select x.*,coalesce(exact_song.id,identity_song.id,title_song.id) song_id
    from input x
    left join public.songs exact_song on exact_song.master_key=x.master_key
    left join lateral (
      select s.id from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where exact_song.id is null and identity_song.id is null
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
      having count(*)=1
    ) title_song on true
  )
  insert into public.user_scores(
    user_id,song_id,chart,score,official_score,manual_history_score,version_score,
    current_clear_status,medal_code,rank_code,source
  )
  select auth.uid(),x.song_id,upper(x.chart),
    greatest(greatest(0,least(100000,coalesce(x.score,0))),greatest(0,least(100000,coalesce(x.version_score,0)))),
    greatest(0,least(100000,coalesce(x.score,0))),0,greatest(0,least(100000,coalesce(x.version_score,0))),
    case lower(coalesce(x.current_clear_status,'')) when 'perfect' then 'perfect' when 'full_combo' then 'full_combo' when 'clear' then 'clear' else 'failed' end,
    coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from resolved x where x.song_id is not null
  on conflict(user_id,song_id,chart) do update set
    official_score=excluded.official_score,
    version_score=excluded.version_score,
    score=greatest(excluded.official_score,public.user_scores.manual_history_score,excluded.version_score),
    current_clear_status=excluded.current_clear_status,
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,
    source='sync',updated_at=now();
  get diagnostics v_saved=row_count;

  delete from public.song_requests r
  where r.user_id=auth.uid() and r.status in('pending','approved')
    and (
      exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
          and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
      )
      or exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
        group by public.normalize_popn_text(s.title)
        having count(*)=1
      )
    );

  return query select v_saved,greatest(0,v_total-v_saved);
end$$;

revoke all on function public.sync_my_scores(jsonb) from public;
grant execute on function public.sync_my_scores(jsonb) to authenticated;

-- ユーザー一覧のポックラも今作クリア状況だけでボーナス判定する。
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
      +case lower(coalesce(us.current_clear_status,'failed'))
         when 'perfect' then 9400
         when 'full_combo' then 7100
         when 'clear' then 5000
         else 0
       end x
    from public.user_scores us
    join public.songs s on s.id=us.song_id
    left join public.game_versions gv on gv.id=s.version_id
  ), chart_values as(
    select user_id,updated_at,medal_code,level,is_current,
      case when version_score<50000 then 0::numeric
      else floor(((x::numeric/(8230-x::numeric/105.3)+8.57)*100))/100
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
