-- v3.0.126: apply only after saving the existing function definitions.
-- Replaces the sync fallback with a unique normalized title+artist match.
-- Does not update songs or delete song_requests.
-- Existing diagnosis column names are retained for frontend compatibility.

-- Review and run in Supabase SQL Editor. Changes only sync_my_scores function definition.
-- Keep a backup of the existing definition before applying.
CREATE OR REPLACE FUNCTION public.sync_my_scores(p_records jsonb)
 RETURNS TABLE(saved integer, unmatched integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_saved integer:=0;
  v_total integer:=0;
begin
  if auth.uid() is null then raise exception 'login required'; end if;

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
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      )
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
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
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      limit 1
    ) identity_song on true
    left join lateral (
      select min(s.id::text)::uuid id
      from public.songs s
      where exact_song.id is null and identity_song.id is null
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      having count(*)=1
    ) title_artist_song on true
  )
  insert into public.user_scores(
    user_id,song_id,chart,score,official_score,manual_history_score,version_score,
    current_clear_status,medal_code,rank_code,source
  )
  select auth.uid(),x.song_id,upper(x.chart),
    greatest(greatest(0,least(100000,coalesce(x.score,0))),greatest(0,least(100000,coalesce(x.version_score,0)))),
    greatest(0,least(100000,coalesce(x.score,0))),0,greatest(0,least(100000,coalesce(x.version_score,0))),
    case lower(coalesce(x.current_clear_status,'')) when 'unplayed' then 'unplayed' when 'perfect' then 'perfect' when 'full_combo' then 'full_combo' when 'clear' then 'clear' else 'failed' end,
    coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from resolved x where x.song_id is not null
  on conflict(user_id,song_id,chart) do update set
    official_score=excluded.official_score,
    version_score=excluded.version_score,
    score=greatest(excluded.official_score,public.user_scores.manual_history_score,excluded.version_score),
    current_clear_status=case
      when excluded.current_clear_status='failed' and public.user_scores.current_clear_status in ('easy','long_off')
        then public.user_scores.current_clear_status
      else excluded.current_clear_status
    end,
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,
    source='sync',updated_at=now();
  get diagnostics v_saved=row_count;

  -- Do not delete song requests during score synchronization.

  return query select v_saved,greatest(0,v_total-v_saved);
end$function$;


-- v3.0.124: read-only diagnostic of the existing sync_my_scores matching rules.
-- Install before deploying the matching v3.0.124 frontend.
create or replace function public.diagnose_sync_matches(p_records jsonb)
returns table(key_match integer, identity_match integer, title_only_match integer, unmatched integer)
language plpgsql security invoker set search_path = public as $function$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if jsonb_typeof(p_records) is distinct from 'array' then raise exception 'records must be an array'; end if;
  return query
  with input as materialized (
    select x.* from jsonb_to_recordset(p_records) x(
      master_key text, genre text, title text, artist text, chart text,
      score integer, version_score integer, current_clear_status text,
      medal_code text, rank_code text
    )
    where coalesce(x.score,0)>0 or coalesce(x.version_score,0)>0
       or coalesce(nullif(lower(x.medal_code),'none'),'')<>''
       or coalesce(nullif(lower(x.rank_code),'none'),'')<>''
       or lower(coalesce(x.current_clear_status,''))='unplayed'
  ), classified as (
    select case
      when exists (select 1 from public.songs s where s.master_key=x.master_key) then 'key'
      when exists (select 1 from public.songs s
        where public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
          and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)) then 'identity'
      when (select count(*) from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist))=1 then 'identity'
      when exists (select 1 from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)) then 'title'
      else 'unmatched' end as match_type
    from input x
  )
  select count(*) filter(where match_type='key')::integer,
         count(*) filter(where match_type='identity')::integer,
         count(*) filter(where match_type='title')::integer,
         count(*) filter(where match_type='unmatched')::integer
  from classified;
end $function$;
revoke all on function public.diagnose_sync_matches(jsonb) from public, anon;
grant execute on function public.diagnose_sync_matches(jsonb) to authenticated;


-- v3.0.125: read-only metadata for records resolved only by a unique title.
-- This function does not insert, update, or delete data and returns no scores/user IDs.
create or replace function public.diagnose_title_only_matches(p_records jsonb)
returns table(input_genre text,input_title text,input_artist text,
              song_genre text,song_title text,song_artist text)
language plpgsql security invoker set search_path = public as $function$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if jsonb_typeof(p_records) is distinct from 'array' then raise exception 'records must be an array'; end if;
  return query
  with input as materialized (
    select x.* from jsonb_to_recordset(p_records) x(
      master_key text, genre text, title text, artist text, chart text,
      score integer, version_score integer, current_clear_status text,
      medal_code text, rank_code text
    )
    where coalesce(x.score,0)>0 or coalesce(x.version_score,0)>0
       or coalesce(nullif(lower(x.medal_code),'none'),'')<>''
       or coalesce(nullif(lower(x.rank_code),'none'),'')<>''
       or lower(coalesce(x.current_clear_status,''))='unplayed'
  )
  select x.genre,x.title,x.artist,s.genre,s.title,s.artist
  from input x
  join public.songs s on public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
  where not exists(select 1 from public.songs k where k.master_key=x.master_key)
    and not exists(select 1 from public.songs i
      where public.normalize_popn_text(i.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(i.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(i.artist)=public.normalize_popn_text(x.artist))
    and (select count(*) from public.songs a
      where public.normalize_popn_text(a.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(a.artist)=public.normalize_popn_text(x.artist))<>1
  order by x.title,x.genre,x.artist,s.genre,s.artist;
end $function$;
revoke all on function public.diagnose_title_only_matches(jsonb) from public, anon;
grant execute on function public.diagnose_title_only_matches(jsonb) to authenticated;
