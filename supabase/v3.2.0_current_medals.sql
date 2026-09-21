-- Apply in Supabase SQL Editor before deploying v3.2.0. Back up the database first.
-- A current-version medal is independent of the all-time medal and is scoped by game_version_id.
begin;

alter table public.user_scores
  add column if not exists current_medal_code text not null default 'none',
  add column if not exists current_medal_manual boolean not null default false;
alter table public.user_version_scores
  add column if not exists current_medal_code text not null default 'none',
  add column if not exists current_medal_manual boolean not null default false;
alter table public.pending_sync_scores add column if not exists current_medal_code text not null default 'none';
alter table public.pending_version_scores add column if not exists current_medal_code text not null default 'none';

-- Derive a basic medal for records saved before current-medal tracking existed.
create or replace function public.psm_medal_from_status(p_status text, p_score integer default 0)
returns text language sql immutable set search_path to '' as $$
 select case lower(coalesce(p_status,''))
  when 'perfect' then 'perfect'
  when 'full_combo' then 'fc_21_plus'
  when 'clear' then 'clear_bad_21_plus'
  when 'easy' then 'easy'
  when 'long_off' then 'long_off'
  when 'unplayed' then 'none'
  when 'failed' then 'failed_0_11'
  else case when coalesce(p_score,0)>0 then 'failed_0_11' else 'none' end
 end
$$;
create or replace function public.psm_medal_category(p_code text)
returns text language sql immutable set search_path to '' as $$
 select case
  when p_code='perfect' then 'perfect'
  when p_code like 'fc_%' then 'full_combo'
  when p_code like 'clear_bad_%' then 'clear'
  when p_code='easy' then 'easy'
  when p_code='long_off' then 'long_off'
  when p_code like 'failed_%' then 'failed'
  else 'unplayed' end
$$;

update public.user_scores
set current_medal_code=public.psm_medal_from_status(current_clear_status,version_score)
where current_medal_code='none' and current_clear_status<>'unplayed'
  and (current_clear_status<>'failed' or version_score>0);
update public.user_version_scores
set current_medal_code=public.psm_medal_from_status(current_clear_status,version_score)
where current_medal_code='none' and current_clear_status<>'unplayed'
  and (current_clear_status<>'failed' or version_score>0);
update public.pending_sync_scores
set current_medal_code=public.psm_medal_from_status(current_clear_status,version_score)
where current_medal_code='none' and current_clear_status<>'unplayed'
  and (current_clear_status<>'failed' or version_score>0);
update public.pending_version_scores
set current_medal_code=public.psm_medal_from_status(current_clear_status,version_score)
where current_medal_code='none' and current_clear_status<>'unplayed'
  and (current_clear_status<>'failed' or version_score>0);

create or replace function public.save_manual_score_v320(
 p_song_id uuid,p_chart text,p_history_score integer,p_version_score integer,
 p_medal_code text,p_rank_code text,p_current_clear_status text,
 p_current_medal_code text,p_game_version_id uuid)
returns boolean language plpgsql security definer set search_path to '' as $function$
declare
 v_code text:=lower(coalesce(p_current_medal_code,''));
 v_status text;
 v_high boolean;
begin
 if auth.uid() is null then raise exception 'login required'; end if;
 if v_code not in ('none','failed_0_11','failed_12_14','failed_15_16','easy','long_off',
                   'clear_bad_1_5','clear_bad_6_20','clear_bad_21_plus',
                   'fc_1_5','fc_6_20','fc_21_plus','perfect') then
   raise exception '今作メダルが不正です。';
 end if;
 v_status:=public.psm_medal_category(v_code);
 if v_status<>p_current_clear_status then raise exception '今作メダルとクリア状況が一致しません。'; end if;
 perform public.save_manual_score_v31(p_song_id,p_chart,p_history_score,p_version_score,
                                      p_medal_code,p_rank_code,v_status,p_game_version_id);
 update public.user_version_scores
 set current_medal_code=v_code,current_medal_manual=true
 where user_id=auth.uid() and song_id=p_song_id and chart=p_chart and game_version_id=p_game_version_id;
 select slug='master_cdbb557d24080162a681ae5c' into v_high
 from public.game_versions where id=p_game_version_id;
 if v_high then
   update public.user_scores
   set current_medal_code=v_code,current_medal_manual=true
   where user_id=auth.uid() and song_id=p_song_id and chart=p_chart;
 end if;
 return true;
end$function$;

-- Run the established sync first to preserve song matching, requests and existing score policy.
-- Then set the current medal for the selected version. No historical medal is changed here.
create or replace function public.sync_my_scores_v320(
 p_records jsonb,p_game_version_id uuid,p_source_path text)
returns table(saved integer,unmatched integer)
language plpgsql security definer set search_path to '' as $function$
declare
 v_saved integer;
 v_unmatched integer;
 v_record jsonb;
 v_song_id uuid;
 v_chart text;
 v_key text;
 v_code text;
 v_status text;
 v_old_code text;
 v_old_manual boolean;
 v_new_code text;
 v_new_status text;
 v_keep boolean;
 v_high boolean;
 v_score integer;
 v_count integer;
begin
 if auth.uid() is null then raise exception 'login required'; end if;
 if jsonb_typeof(p_records)<>'array' then raise exception 'invalid score records'; end if;
 select x.saved,x.unmatched into v_saved,v_unmatched
 from public.sync_my_scores_v31(p_records,p_game_version_id,p_source_path) x;
 select (slug='master_cdbb557d24080162a681ae5c') into v_high
 from public.game_versions where id=p_game_version_id;

 for v_record in select value from jsonb_array_elements(p_records) as j(value) loop
   v_chart:=upper(trim(coalesce(v_record->>'chart','')));
   if v_chart not in ('LIGHT','NORMAL','HYPER','EX') then continue; end if;
   v_key:=v_record->>'master_key';
   v_song_id:=null;
   select id into v_song_id from public.songs where master_key=v_key limit 1;
   if v_song_id is null then
     -- Only use an identity fallback when it is unambiguous.
     select min(s.id::text)::uuid,count(*) into v_song_id,v_count
     from public.songs s
     where public.normalize_popn_text(s.genre)=public.normalize_popn_text(v_record->>'genre')
       and public.normalize_popn_text(s.title)=public.normalize_popn_text(v_record->>'title')
       and public.normalize_popn_text(s.artist)=public.normalize_popn_text(v_record->>'artist');
     if v_count<>1 then v_song_id:=null; end if;
   end if;
   if v_song_id is null then
     select min(s.id::text)::uuid,count(*) into v_song_id,v_count
     from public.songs s
     where public.normalize_popn_text(s.title)=public.normalize_popn_text(v_record->>'title')
       and public.normalize_popn_text(s.artist)=public.normalize_popn_text(v_record->>'artist');
     if v_count<>1 then v_song_id:=null; end if;
   end if;
   v_status:=lower(coalesce(v_record->>'current_clear_status','failed'));
   if v_status not in ('unplayed','failed','clear','full_combo','perfect') then v_status:='failed'; end if;
   v_score:=greatest(0,least(100000,coalesce(nullif(v_record->>'version_score','')::integer,0)));
   v_code:=public.psm_medal_from_status(v_status,v_score);
   if v_song_id is null then
      -- Pending records retain the basic current medal until their song is approved.
      if v_high then
        update public.pending_sync_scores set current_medal_code=v_code
        where user_id=auth.uid() and master_key=v_key and chart=v_chart;
      else
        update public.pending_version_scores set current_medal_code=v_code
        where user_id=auth.uid() and game_version_id=p_game_version_id
          and master_key=v_key and chart=v_chart;
      end if;
      continue;
   end if;
   select current_medal_code,current_medal_manual into v_old_code,v_old_manual
   from public.user_version_scores
   where user_id=auth.uid() and song_id=v_song_id and chart=v_chart and game_version_id=p_game_version_id;
   if not found and v_high then
     select current_medal_code,current_medal_manual into v_old_code,v_old_manual
     from public.user_scores where user_id=auth.uid() and song_id=v_song_id and chart=v_chart;
   end if;
   v_keep:=coalesce(v_old_manual,false) and
      (public.psm_medal_category(v_old_code)=v_status
       or (v_status='failed' and v_old_code in ('easy','long_off')));
   v_new_code:=case when v_keep then v_old_code else v_code end;
   v_new_status:=public.psm_medal_category(v_new_code);
   insert into public.user_version_scores(
      user_id,song_id,chart,game_version_id,version_score,current_clear_status,
      current_medal_code,current_medal_manual)
   values(auth.uid(),v_song_id,v_chart,p_game_version_id,v_score,v_new_status,
          v_new_code,v_keep)
   on conflict(user_id,song_id,chart,game_version_id) do update set
      version_score=excluded.version_score,
      current_clear_status=excluded.current_clear_status,
      current_medal_code=excluded.current_medal_code,
      current_medal_manual=excluded.current_medal_manual,
      updated_at=now();
   if v_high then
     update public.user_scores
     set current_clear_status=v_new_status,current_medal_code=v_new_code,
         current_medal_manual=v_keep,updated_at=now()
     where user_id=auth.uid() and song_id=v_song_id and chart=v_chart;
   end if;
 end loop;
 return query select coalesce(v_saved,0),coalesce(v_unmatched,0);
end$function$;

-- Preserve current medals when pending songs are approved.
CREATE OR REPLACE FUNCTION public.approve_song_request_v2(p_request_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r public.song_requests%rowtype;
  s_id uuid;
  s_key text;
  source_text text;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;

  select * into r
  from public.song_requests
  where id=p_request_id and status='pending'
  for update;

  if not found then
    raise exception '未対応の登録依頼が見つかりません。';
  end if;

  -- まずジャンル・曲名・アーティストの正規化一致で既存曲を探す。
  select s.id into s_id
  from public.songs s
  where public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
  order by s.id
  limit 1;

  -- ジャンルだけが異なる場合は、曲名＋アーティストが一致し、
  -- マスター内の候補が1曲に限られるときだけ既存曲へ紐付ける。
  -- 曲名だけでの照合は、別アーティストの曲への誤登録を防ぐため行わない。
  if s_id is null then
    select min(s.id::text)::uuid into s_id
    from public.songs s
    where public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
      and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
    having count(*)=1;
  end if;

  if s_id is null and exists (
    select 1 from public.songs s
    where public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
      and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
  ) then
    raise exception '同じ曲名・アーティストの候補が複数あります。曲マスターを確認してください。';
  end if;

  -- 既存譜面のレベルと依頼レベルが矛盾する場合は安全のため承認しない。
  if s_id is not null and exists (
    select 1 from public.songs s where s.id=s_id
      and case upper(r.chart)
        when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level
        when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end is not null
      and case upper(r.chart)
        when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level
        when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end <> r.level
  ) then
    raise exception '登録済みの譜面レベルと依頼が異なります。マスターを確認してください。';
  end if;

  if s_id is null then
    -- pgcrypto/digest() には依存しない。
    -- songs.master_key の64桁hex制約を満たす安定した仮キーを生成する。
    source_text:=lower(concat_ws('|',trim(r.genre),trim(r.title),trim(r.artist)));
    s_key:=md5(source_text)||md5('popn-score-manager|'||source_text);

    insert into public.songs(
      master_key,genre,title,artist,banner_url,
      light_level,normal_level,hyper_level,ex_level
    ) values (
      s_key,trim(r.genre),trim(r.title),trim(r.artist),'',
      case when upper(r.chart)='LIGHT' then r.level end,
      case when upper(r.chart)='NORMAL' then r.level end,
      case when upper(r.chart)='HYPER' then r.level end,
      case when upper(r.chart)='EX' then r.level end
    )
    on conflict(genre,title,artist) do update set
      light_level=coalesce(public.songs.light_level,excluded.light_level),
      normal_level=coalesce(public.songs.normal_level,excluded.normal_level),
      hyper_level=coalesce(public.songs.hyper_level,excluded.hyper_level),
      ex_level=coalesce(public.songs.ex_level,excluded.ex_level),
      updated_at=now()
    returning id into s_id;
  else
    update public.songs set
      light_level=case when upper(r.chart)='LIGHT' then coalesce(light_level,r.level) else light_level end,
      normal_level=case when upper(r.chart)='NORMAL' then coalesce(normal_level,r.level) else normal_level end,
      hyper_level=case when upper(r.chart)='HYPER' then coalesce(hyper_level,r.level) else hyper_level end,
      ex_level=case when upper(r.chart)='EX' then coalesce(ex_level,r.level) else ex_level end,
      updated_at=now()
    where id=s_id;
  end if;

  -- 曲マスター作成と仮スコア反映を同一トランザクションで実行する。
  -- 全ユーザーのうち、承認依頼と曲情報・譜面・レベルが一致したものだけ反映する。
  -- source key が一致するが曲情報が異なるデータは自動登録しない。
  insert into public.user_scores(
    user_id,song_id,chart,score,official_score,manual_history_score,version_score,
    current_clear_status,current_medal_code,medal_code,rank_code,source
  )
  select distinct on (p.user_id,p.chart) p.user_id,s_id,p.chart,
    greatest(p.score,p.version_score),p.score,0,p.version_score,
    p.current_clear_status,p.current_medal_code,p.medal_code,p.rank_code,'sync'
  from public.pending_sync_scores p
  where public.normalize_popn_text(p.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(p.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(p.artist)=public.normalize_popn_text(r.artist)
    and p.chart=upper(r.chart) and p.level=r.level
  order by p.user_id,p.chart,p.updated_at desc,p.id
  on conflict (user_id,song_id,chart) do update set
    official_score=excluded.official_score,
    version_score=excluded.version_score,
    score=greatest(excluded.official_score,public.user_scores.manual_history_score,excluded.version_score),
    current_clear_status=case
      when public.user_scores.current_medal_manual and
        (public.psm_medal_category(public.user_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_scores.current_medal_code in ('easy','long_off')))
        then public.psm_medal_category(public.user_scores.current_medal_code)
      else excluded.current_clear_status end,
    current_medal_code=case
      when public.user_scores.current_medal_manual and
        (public.psm_medal_category(public.user_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_scores.current_medal_code in ('easy','long_off')))
        then public.user_scores.current_medal_code
      else excluded.current_medal_code end,
    current_medal_manual=public.user_scores.current_medal_manual and
        (public.psm_medal_category(public.user_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_scores.current_medal_code in ('easy','long_off'))),
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,
    source='sync',updated_at=now();

  -- 正式反映まで成功した仮データのみ削除する。エラー時は承認全体がロールバックされる。
  delete from public.pending_sync_scores p
  where public.normalize_popn_text(p.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(p.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(p.artist)=public.normalize_popn_text(r.artist)
    and p.chart=upper(r.chart) and p.level=r.level;


  -- Pending scores from all newer game versions: historical best and version slot.
  insert into public.user_scores(user_id,song_id,chart,score,official_score,
      manual_history_score,version_score,current_clear_status,medal_code,rank_code,source)
  select distinct on (p.user_id,p.chart) p.user_id,s_id,p.chart,
      greatest(p.score,p.version_score),p.score,0,0,'failed',p.medal_code,p.rank_code,'sync'
  from public.pending_version_scores p
  where public.normalize_popn_text(p.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(p.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(p.artist)=public.normalize_popn_text(r.artist)
    and p.chart=upper(r.chart) and p.level=r.level
  order by p.user_id,p.chart,p.score desc,p.updated_at desc,p.id
  on conflict(user_id,song_id,chart) do update set
     official_score=greatest(public.user_scores.official_score,excluded.official_score),
     score=greatest(public.user_scores.official_score,excluded.official_score,
         public.user_scores.manual_history_score,public.user_scores.version_score),
     medal_code=excluded.medal_code,rank_code=excluded.rank_code,updated_at=now();

  insert into public.user_version_scores(user_id,song_id,chart,game_version_id,
      version_score,current_clear_status,current_medal_code)
  select distinct on (p.user_id,p.chart,p.game_version_id)
      p.user_id,s_id,p.chart,p.game_version_id,p.version_score,p.current_clear_status,p.current_medal_code
  from public.pending_version_scores p
  where public.normalize_popn_text(p.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(p.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(p.artist)=public.normalize_popn_text(r.artist)
    and p.chart=upper(r.chart) and p.level=r.level
  order by p.user_id,p.chart,p.game_version_id,p.updated_at desc,p.id
  on conflict(user_id,song_id,chart,game_version_id) do update set
     version_score=excluded.version_score,
     current_clear_status=case when public.user_version_scores.current_medal_manual and
         (public.psm_medal_category(public.user_version_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_version_scores.current_medal_code in ('easy','long_off')))
         then public.psm_medal_category(public.user_version_scores.current_medal_code)
         else excluded.current_clear_status end,
     current_medal_code=case when public.user_version_scores.current_medal_manual and
         (public.psm_medal_category(public.user_version_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_version_scores.current_medal_code in ('easy','long_off')))
         then public.user_version_scores.current_medal_code else excluded.current_medal_code end,
     current_medal_manual=public.user_version_scores.current_medal_manual and
         (public.psm_medal_category(public.user_version_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_version_scores.current_medal_code in ('easy','long_off'))),
     updated_at=now();
  delete from public.pending_version_scores p
  where public.normalize_popn_text(p.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(p.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(p.artist)=public.normalize_popn_text(r.artist)
    and p.chart=upper(r.chart) and p.level=r.level;

  delete from public.song_requests where id=p_request_id;
  return true;
end
$function$;

revoke all on function public.save_manual_score_v320(uuid,text,integer,integer,text,text,text,text,uuid) from PUBLIC,anon;
revoke all on function public.sync_my_scores_v320(jsonb,uuid,text) from PUBLIC,anon;
grant execute on function public.save_manual_score_v320(uuid,text,integer,integer,text,text,text,text,uuid) to authenticated;
grant execute on function public.sync_my_scores_v320(jsonb,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
