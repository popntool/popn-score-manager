-- v3.3.65: Include score-zero clear / FC / perfect records in the legacy sync stage.
-- Apply this before deploying frontend. Keeps v3.3.64 sparse storage and existing RPC signature.
-- This changes a function only; it does not modify existing scores.
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
     or lower(coalesce(x.current_clear_status,'')) in ('failed','clear','full_combo','perfect');

  -- Song master levels are managed through the request/approval workflow.

  with input as materialized (
    select * from jsonb_to_recordset(p_records) x(
      master_key text,genre text,title text,artist text,chart text,level smallint,
      score integer,version_score integer,current_clear_status text,medal_code text,rank_code text
    ) where coalesce(score,0)>0 or coalesce(version_score,0)>0
       or coalesce(nullif(lower(medal_code),'none'),'')<>''
       or coalesce(nullif(lower(rank_code),'none'),'')<>''
       or lower(coalesce(current_clear_status,'')) in ('failed','clear','full_combo','perfect')
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
       or lower(coalesce(current_clear_status,'')) in ('failed','clear','full_combo','perfect')
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
       or lower(coalesce(current_clear_status,'')) in ('failed','clear','full_combo','perfect')
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
       or lower(coalesce(current_clear_status,'')) in ('failed','clear','full_combo','perfect')
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
      and lower(coalesce(x.current_clear_status,'')) = 'unplayed'
      and coalesce(nullif(lower(x.medal_code),'none'),'') = ''
      and coalesce(nullif(lower(x.rank_code),'none'),'') = ''
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


COMMIT;
