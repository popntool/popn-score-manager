-- v2.9.0 登録依頼の承認を曲マスターへ反映し、処理済み依頼を削除
-- Supabase SQL Editorで、このファイル全体を1回実行してください。

-- 過去の承認済み依頼を既存曲へ統合する。
with matched as (
  select s.id,
    max(r.level) filter(where r.chart='LIGHT') light_level,
    max(r.level) filter(where r.chart='NORMAL') normal_level,
    max(r.level) filter(where r.chart='HYPER') hyper_level,
    max(r.level) filter(where r.chart='EX') ex_level
  from public.songs s join public.song_requests r
    on lower(trim(s.genre))=lower(trim(r.genre))
   and lower(trim(s.title))=lower(trim(r.title))
   and lower(trim(s.artist))=lower(trim(r.artist))
  where r.status='approved' group by s.id
)
update public.songs s set
  light_level=coalesce(s.light_level,m.light_level),normal_level=coalesce(s.normal_level,m.normal_level),
  hyper_level=coalesce(s.hyper_level,m.hyper_level),ex_level=coalesce(s.ex_level,m.ex_level)
from matched m where s.id=m.id;

-- 対応する曲がまだない承認済み依頼から曲マスターを作る。
with approved as (
  select min(trim(r.genre)) genre,min(trim(r.title)) title,min(trim(r.artist)) artist,
    max(r.level) filter(where r.chart='LIGHT') light_level,
    max(r.level) filter(where r.chart='NORMAL') normal_level,
    max(r.level) filter(where r.chart='HYPER') hyper_level,
    max(r.level) filter(where r.chart='EX') ex_level
  from public.song_requests r
  where r.status='approved' and not exists(
    select 1 from public.songs s where lower(trim(s.genre))=lower(trim(r.genre))
      and lower(trim(s.title))=lower(trim(r.title)) and lower(trim(s.artist))=lower(trim(r.artist)))
  group by lower(trim(r.genre)),lower(trim(r.title)),lower(trim(r.artist))
)
insert into public.songs(master_key,genre,title,artist,banner_url,light_level,normal_level,hyper_level,ex_level)
select encode(digest(lower(concat_ws('|',genre,title,artist)),'sha256'),'hex'),genre,title,artist,'',light_level,normal_level,hyper_level,ex_level
from approved on conflict(genre,title,artist) do update set
  light_level=coalesce(public.songs.light_level,excluded.light_level),normal_level=coalesce(public.songs.normal_level,excluded.normal_level),
  hyper_level=coalesce(public.songs.hyper_level,excluded.hyper_level),ex_level=coalesce(public.songs.ex_level,excluded.ex_level);

delete from public.song_requests where status='approved';

create or replace function public.approve_song_request_v2(p_request_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare r public.song_requests%rowtype;s_id uuid;s_key text;
begin
  if not public.is_admin() then raise exception 'admin only';end if;
  select * into r from public.song_requests where id=p_request_id and status='pending' for update;
  if not found then raise exception '未対応の登録依頼が見つかりません。';end if;
  select id into s_id from public.songs where lower(trim(genre))=lower(trim(r.genre))
    and lower(trim(title))=lower(trim(r.title)) and lower(trim(artist))=lower(trim(r.artist)) limit 1;
  if s_id is null then
    s_key:=encode(digest(lower(concat_ws('|',trim(r.genre),trim(r.title),trim(r.artist))),'sha256'),'hex');
    insert into public.songs(master_key,genre,title,artist,banner_url,light_level,normal_level,hyper_level,ex_level)
    values(s_key,trim(r.genre),trim(r.title),trim(r.artist),'',
      case when r.chart='LIGHT' then r.level end,case when r.chart='NORMAL' then r.level end,
      case when r.chart='HYPER' then r.level end,case when r.chart='EX' then r.level end)
    returning id into s_id;
  else
    update public.songs set
      light_level=case when r.chart='LIGHT' then coalesce(light_level,r.level) else light_level end,
      normal_level=case when r.chart='NORMAL' then coalesce(normal_level,r.level) else normal_level end,
      hyper_level=case when r.chart='HYPER' then coalesce(hyper_level,r.level) else hyper_level end,
      ex_level=case when r.chart='EX' then coalesce(ex_level,r.level) else ex_level end
    where id=s_id;
  end if;
  delete from public.song_requests where id=p_request_id;
  return true;
end$$;
revoke all on function public.approve_song_request_v2(uuid) from public;
grant execute on function public.approve_song_request_v2(uuid) to authenticated;

-- 同期メダルの f はFAILEDではなくクリア系。ユーザー一覧の最高クリア判定も統一する。
drop function if exists public.list_user_summaries(text);
create function public.list_user_summaries(p_search text default '')
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,highest_clear_level smallint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  select p.id,p.username,case when p.poptomo_public then p.poptomo_id else null end,null::numeric,
    max(case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end)
      filter(where lower(us.medal_code) not in('none','l','m','n','failed_15_16','failed_12_14','failed_0_11')),
    max(us.updated_at)
  from public.profiles p left join public.user_scores us on us.user_id=p.id left join public.songs s on s.id=us.song_id
  where p.username ilike '%'||coalesce(p_search,'')||'%' and not exists(select 1 from public.admin_users a where a.user_id=p.id)
  group by p.id,p.username,p.poptomo_id,p.poptomo_public order by p.username
$$;
grant execute on function public.list_user_summaries(text) to anon,authenticated;
