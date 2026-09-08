-- v2.10.0 登場バージョン付き曲マスターの再投入に対応
-- Supabase SQL Editorで、このファイル全体を1回実行してください。

create or replace function public.import_song_master_v2(p_records jsonb)
returns integer language plpgsql security definer set search_path=public as $$
declare affected integer;
begin
  if not public.is_admin() then raise exception 'admin only';end if;
  insert into public.songs(master_key,genre,title,artist,banner_url,light_level,normal_level,hyper_level,ex_level,version_id)
  select trim(x.master_key),trim(x.genre),trim(x.title),trim(x.artist),coalesce(x.banner_url,''),
    x.light_level,x.normal_level,x.hyper_level,x.ex_level,v.id
  from jsonb_to_recordset(p_records) as x(
    master_key text,banner_url text,genre text,title text,artist text,version_slug text,
    light_level smallint,normal_level smallint,hyper_level smallint,ex_level smallint
  )
  left join public.game_versions v on v.slug=nullif(trim(x.version_slug),'')
  where x.master_key~'^[0-9a-f]{64}$'
  on conflict(genre,title,artist) do update set
    master_key=excluded.master_key,banner_url=excluded.banner_url,
    light_level=excluded.light_level,normal_level=excluded.normal_level,
    hyper_level=excluded.hyper_level,ex_level=excluded.ex_level,
    version_id=coalesce(excluded.version_id,public.songs.version_id);
  get diagnostics affected=row_count;
  return affected;
end$$;
revoke all on function public.import_song_master_v2(jsonb) from public;
grant execute on function public.import_song_master_v2(jsonb) to authenticated;
