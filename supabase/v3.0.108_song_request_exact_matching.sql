-- v3.0.108: 完全一致した譜面依頼だけを整理する。相違・未登録譜面は保留。
-- 要望・不具合(feedback_reports)には一切変更を加えない。
create or replace function public.submit_song_request_v2(
  p_genre text,p_title text,p_artist text,p_chart text,p_level integer,p_note text default ''
) returns text language plpgsql security definer set search_path=public as $$
declare v_chart text:=upper(trim(p_chart));v_level integer:=p_level;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  if coalesce(trim(p_genre),'')='' or coalesce(trim(p_title),'')='' or coalesce(trim(p_artist),'')='' then raise exception '曲情報を入力してください。';end if;
  if v_chart not in('LIGHT','NORMAL','HYPER','EX') or v_level not between 1 and 50 then raise exception '譜面またはレベルが不正です。';end if;
  -- 曲情報と譜面レベルの全項目が一致し、対象曲が一意な場合のみ自動統合。
  if (select count(*) from public.songs s
      where public.normalize_popn_text(s.genre)=public.normalize_popn_text(p_genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(p_artist)
        and case v_chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level
          when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end=v_level)=1
     and (select count(*) from public.songs s
      where public.normalize_popn_text(s.genre)=public.normalize_popn_text(p_genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(p_title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(p_artist))=1 then
    return 'merged';
  end if;
  -- 未登録譜面、レベル差異、ジャンル・アーティスト差異は依頼として保持。
  if not exists(select 1 from public.song_requests r where r.user_id=auth.uid() and r.status='pending'
    and public.normalize_popn_text(r.genre)=public.normalize_popn_text(p_genre)
    and public.normalize_popn_text(r.title)=public.normalize_popn_text(p_title)
    and public.normalize_popn_text(r.artist)=public.normalize_popn_text(p_artist)
    and upper(r.chart)=v_chart and r.level=v_level) then
    insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
    values(auth.uid(),trim(p_genre),trim(p_title),trim(p_artist),v_chart,v_level,coalesce(p_note,''),'pending');
  end if;
  return 'requested';
end$$;
revoke all on function public.submit_song_request_v2(text,text,text,text,integer,text) from public;
grant execute on function public.submit_song_request_v2(text,text,text,text,integer,text) to authenticated;

create or replace function public.merge_song_requests_into_master()
returns integer language plpgsql security definer set search_path=public as $$
declare v_deleted integer;
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'admin only';end if;
  -- レベル未登録・不一致や別曲の可能性がある依頼は削除しない。
  delete from public.song_requests r
  where r.status='pending'
    and (select count(*) from public.songs s
      where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist))=1
    and exists(select 1 from public.songs s
      where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
        and case upper(r.chart) when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level
          when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end=r.level);
  get diagnostics v_deleted=row_count;
  return v_deleted;
end$$;
revoke all on function public.merge_song_requests_into_master() from public;
grant execute on function public.merge_song_requests_into_master() to authenticated;
-- 自動実行・一括削除はしない。必要な場合のみ管理者が明示的に実行する。
