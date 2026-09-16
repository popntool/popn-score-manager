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
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title))=1 then 'title'
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
