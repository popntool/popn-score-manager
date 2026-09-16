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
  join lateral (
    select min(t.id::text)::uuid as id
    from public.songs t
    where public.normalize_popn_text(t.title)=public.normalize_popn_text(x.title)
    having count(*)=1
  ) unique_title on true
  join public.songs s on s.id=unique_title.id
  where not exists(select 1 from public.songs k where k.master_key=x.master_key)
    and not exists(select 1 from public.songs i
      where public.normalize_popn_text(i.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(i.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(i.artist)=public.normalize_popn_text(x.artist))
  order by x.title,x.genre,x.artist;
end $function$;
revoke all on function public.diagnose_title_only_matches(jsonb) from public, anon;
grant execute on function public.diagnose_title_only_matches(jsonb) to authenticated;
