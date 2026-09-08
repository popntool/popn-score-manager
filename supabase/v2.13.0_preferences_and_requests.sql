-- v2.13.0 端末共通の表示設定と、既存曲に対する登録依頼の自動統合
-- Supabase SQL Editorで全体を1回実行してください。

alter table public.profiles add column if not exists default_level smallint;
alter table public.profiles drop constraint if exists profiles_default_level_check;
alter table public.profiles add constraint profiles_default_level_check check(default_level between 1 and 50);

create or replace function public.merge_song_requests_into_master()
returns integer language plpgsql security definer set search_path=public as $$
declare v_deleted integer;
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'admin only';end if;
  with request_match as(
    select r.id,r.chart,r.level,
      coalesce(
        (select s.id from public.songs s
         where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
           and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
           and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist) limit 1),
        (select min(s.id::text)::uuid from public.songs s
         where public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
         having count(*)=1)
      ) song_id
    from public.song_requests r where r.status in('pending','approved')
  ), matched as(
    select song_id,
      max(level) filter(where upper(chart)='LIGHT') light_level,
      max(level) filter(where upper(chart)='NORMAL') normal_level,
      max(level) filter(where upper(chart)='HYPER') hyper_level,
      max(level) filter(where upper(chart)='EX') ex_level
    from request_match where song_id is not null group by song_id
  )
  update public.songs s set
    light_level=coalesce(s.light_level,m.light_level),normal_level=coalesce(s.normal_level,m.normal_level),
    hyper_level=coalesce(s.hyper_level,m.hyper_level),ex_level=coalesce(s.ex_level,m.ex_level),updated_at=now()
  from matched m where s.id=m.song_id;

  with request_match as(
    select r.id,
      coalesce(
        (select s.id from public.songs s
         where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
           and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
           and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist) limit 1),
        (select min(s.id::text)::uuid from public.songs s
         where public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
         having count(*)=1)
      ) song_id
    from public.song_requests r where r.status in('pending','approved')
  )
  delete from public.song_requests r using request_match m where r.id=m.id and m.song_id is not null;
  get diagnostics v_deleted=row_count;
  return v_deleted;
end$$;

revoke all on function public.merge_song_requests_into_master() from public;
grant execute on function public.merge_song_requests_into_master() to authenticated;

select public.merge_song_requests_into_master();
