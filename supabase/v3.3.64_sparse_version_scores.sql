-- Popn Score Manager v3.3.64 - staged sparse storage for version score rows.
-- Apply while on Pro, only AFTER a full backup and after reviewing attached instructions.
-- Does not purge historical records. Does not modify PSR formula.
-- Functions are copied from the user's 2026-10-16 database export and minimally patched.
-- Existing permissions/security definer / signatures preserved.
BEGIN;
CREATE OR REPLACE FUNCTION public.sync_my_scores_v31(p_records jsonb, p_game_version_id uuid, p_source_path text)
 RETURNS TABLE(saved integer, unmatched integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_saved integer:=0;
  v_total integer:=0;
  v_sync_path text;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  select sync_path into v_sync_path from public.game_versions
    where id=p_game_version_id and is_active=true;
  if v_sync_path is null or v_sync_path<>p_source_path
      or p_source_path !~ '^/game/popn/popn[0-9]+/$' then
    raise exception '公式サイトURLとゲームバージョンが一致しません。同期を中止しました。';
  end if;
  if exists(select 1 from public.game_versions where id=p_game_version_id
       and slug='master_cdbb557d24080162a681ae5c') then
    return query select * from public.sync_my_scores(p_records);
    return;
  end if;

  select count(*) into v_total
  from jsonb_to_recordset(p_records) x(score integer,version_score integer,current_clear_status text,medal_code text,rank_code text)
  where coalesce(x.score,0)>0 or coalesce(x.version_score,0)>0
     or coalesce(nullif(lower(x.medal_code),'none'),'')<>''
     or coalesce(nullif(lower(x.rank_code),'none'),'')<>''
     or lower(coalesce(x.current_clear_status,''))='unplayed';

  -- Song master levels are managed through the request/approval workflow.

  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,current_clear_status text,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
       or lower(coalesce(current_clear_status,''))='unplayed'
  ), unresolved as materialized (
    select x.* from input x
    where not exists(select 1 from public.songs s where s.master_key=x.master_key)
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
          and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace(x.artist, '＠', '@'))
      )
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace(x.artist, '＠', '@'))
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
        and public.normalize_popn_text(replace(r.artist, '＠', '@'))=public.normalize_popn_text(replace(x.artist, '＠', '@'))
        and upper(r.chart)=upper(trim(x.chart)) and r.level=x.level
    );

  -- 未登録曲のスコアは正式なuser_scoresへ入れず、所有者ごとに仮保存する。
  -- 照合条件は上の登録依頼生成と同一。既存の依頼の補足は上書きしない。
  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,current_clear_status text,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
       or lower(coalesce(current_clear_status,''))='unplayed'
  ), unresolved as materialized (
    select x.* from input x
    where not exists(select 1 from public.songs s where s.master_key=x.master_key)
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
          and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace(x.artist, '＠', '@'))
      )
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace(x.artist, '＠', '@'))
        having count(*)=1
      )
  )
  insert into public.pending_version_scores(
    user_id,game_version_id,master_key,genre,title,artist,chart,level,score,version_score,
    current_clear_status,medal_code,rank_code
  )
  select distinct on (x.master_key,upper(trim(x.chart)))
    auth.uid(),p_game_version_id,x.master_key,trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),x.level,
    greatest(0,least(100000,coalesce(x.score,0))),
    greatest(0,least(100000,coalesce(x.version_score,0))),
    case lower(coalesce(x.current_clear_status,''))
      when 'unplayed' then 'unplayed' when 'perfect' then 'perfect'
      when 'full_combo' then 'full_combo' when 'clear' then 'clear' else 'failed' end,
    coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none')
  from unresolved x
  where x.master_key ~ '^[0-9a-f]{64}$'
    and coalesce(trim(x.genre),'')<>'' and coalesce(trim(x.title),'')<>''
    and coalesce(trim(x.artist),'')<>''
    and char_length(x.genre)<=512 and char_length(x.title)<=512 and char_length(x.artist)<=512
    and upper(trim(x.chart)) in ('LIGHT','NORMAL','HYPER','EX') and x.level between 1 and 50
  order by x.master_key,upper(trim(x.chart)),x.version_score desc nulls last,x.score desc nulls last
  on conflict (user_id,game_version_id,master_key,chart) do update set
    genre=excluded.genre,title=excluded.title,artist=excluded.artist,level=excluded.level,
    score=excluded.score,version_score=excluded.version_score,
    current_clear_status=excluded.current_clear_status,
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,updated_at=now();

  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,current_clear_status text,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
       or lower(coalesce(current_clear_status,''))='unplayed'
  ), resolved as materialized (
    select x.*,coalesce(exact_song.id,identity_song.id,title_artist_song.id) song_id
    from input x
    left join public.songs exact_song on exact_song.master_key=x.master_key
    left join lateral (
      select s.id from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace(x.artist, '＠', '@'))
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where exact_song.id is null and identity_song.id is null
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace(x.artist, '＠', '@'))
      having count(*)=1
    ) title_artist_song on true
  )
  insert into public.user_scores(
    user_id,song_id,chart,score,official_score,manual_history_score,version_score,
    current_clear_status,medal_code,rank_code,source
  )
  select auth.uid(),x.song_id,upper(x.chart),
    greatest(greatest(0,least(100000,coalesce(x.score,0))),greatest(0,least(100000,coalesce(x.version_score,0)))),
    greatest(0,least(100000,coalesce(x.score,0))),0,0,
    'failed',
    coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from resolved x where x.song_id is not null
  on conflict(user_id,song_id,chart) do update set
    official_score=greatest(excluded.official_score,public.user_scores.official_score),
    score=greatest(excluded.official_score,public.user_scores.official_score,public.user_scores.manual_history_score,public.user_scores.version_score),
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,
    source='sync',updated_at=now();
  get diagnostics v_saved=row_count;

  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,current_clear_status text,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
       or lower(coalesce(current_clear_status,''))='unplayed'
  ), resolved as materialized (
    select x.*,coalesce(exact_song.id,identity_song.id,title_artist_song.id) song_id
    from input x
    left join public.songs exact_song on exact_song.master_key=x.master_key
    left join lateral (
      select s.id from public.songs s
      where exact_song.id is null
        and public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace(x.artist, '＠', '@'))
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where exact_song.id is null and identity_song.id is null
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(replace(x.artist, '＠', '@'))
      having count(*)=1
    ) title_artist_song on true
  )
  insert into public.user_version_scores(
    user_id,song_id,chart,game_version_id,version_score,current_clear_status
  )
  select distinct on (x.song_id,upper(x.chart))
    auth.uid(),x.song_id,upper(x.chart),p_game_version_id,
    greatest(0,least(100000,coalesce(x.version_score,0))),
    case lower(coalesce(x.current_clear_status,''))
      when 'unplayed' then 'unplayed' when 'perfect' then 'perfect'
      when 'full_combo' then 'full_combo' when 'clear' then 'clear' else 'failed' end
  from resolved x
  where x.song_id is not null
    and NOT (
      coalesce(x.version_score,0)=0
      and lower(coalesce(x.current_clear_status,''))='unplayed'
    )
  order by x.song_id,upper(x.chart),x.version_score desc nulls last,x.score desc nulls last
  on conflict(user_id,song_id,chart,game_version_id) do update set
    version_score=excluded.version_score,
    current_clear_status=case when excluded.current_clear_status='failed'
      and public.user_version_scores.current_clear_status in ('easy','long_off')
      then public.user_version_scores.current_clear_status
      else excluded.current_clear_status end,
    updated_at=now();

  -- Do not delete song requests during score synchronization.

  return query select v_saved,greatest(0,v_total-v_saved);
end$function$
;

CREATE OR REPLACE FUNCTION public.sync_my_scores_v320(p_records jsonb, p_game_version_id uuid, p_source_path text)
 RETURNS TABLE(saved integer, unmatched integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
   -- Sparse version rows: missing row represents an untouched, unplayed chart.
   -- Preserve manually marked charts and any played/failed state.
   if v_score=0 and v_new_status='unplayed' and v_new_code='none' and not v_keep then
     delete from public.user_version_scores
     where user_id=auth.uid() and song_id=v_song_id
       and chart=v_chart and game_version_id=p_game_version_id
       and version_score=0
       and current_clear_status='unplayed'
       and current_medal_code='none'
       and current_medal_manual=false;
     -- User history table has an independent historical score and must be preserved.
     if v_high then
       update public.user_scores
       set current_clear_status=v_new_status,current_medal_code=v_new_code,
           current_medal_manual=false,updated_at=now()
       where user_id=auth.uid() and song_id=v_song_id and chart=v_chart;
     end if;
     continue;
   end if;
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
end$function$
;

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

  -- 曲の同一判定は「ジャンル・曲名・アーティスト」の3項目で行う。
  -- 曲名・アーティストが同じでもジャンルが異なる場合は別曲として扱うため、
  -- タイトル＋アーティストだけで既存曲へ自動的に寄せたり、候補重複エラーにはしない。

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
    and not (
      coalesce(p.version_score,0)=0
      and lower(coalesce(p.current_clear_status,''))='unplayed'
      and lower(coalesce(p.current_medal_code,'none'))='none'
    )
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
$function$
;
COMMIT;
