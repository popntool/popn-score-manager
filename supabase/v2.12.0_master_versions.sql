-- v2.12.0 曲マスターの登場バージョンを表示名・slugの表記差にかかわらず反映する
-- このSQLを1回実行後、最新版の曲マスターテキストを再投入してください。

create or replace function public.normalize_popn_version(v text)
returns text language sql immutable parallel safe as $$
  select regexp_replace(
    lower(regexp_replace(replace(trim(coalesce(v,'')),chr(160),' '),'[[:space:]]+',' ','g')),
    '^pop''n[[:space:]]*music[[:space:]]*','','i'
  )
$$;

create or replace function public.import_song_master_v2(p_records jsonb)
returns integer language plpgsql security definer set search_path=public as $$
declare
  r record;
  v_song_id uuid;
  v_version_id uuid;
  v_version_name text;
  affected integer:=0;
begin
  if not public.is_admin() then raise exception 'admin only';end if;

  for r in
    select x.*
    from jsonb_to_recordset(p_records) as x(
      master_key text,banner_url text,genre text,title text,artist text,version_slug text,
      light_level smallint,normal_level smallint,hyper_level smallint,ex_level smallint
    )
    where x.master_key~'^[0-9a-f]{64}$'
      and (x.light_level is null or x.light_level between 1 and 50)
      and (x.normal_level is null or x.normal_level between 1 and 50)
      and (x.hyper_level is null or x.hyper_level between 1 and 50)
      and (x.ex_level is null or x.ex_level between 1 and 50)
  loop
    v_song_id:=null;
    v_version_id:=null;
    v_version_name:=regexp_replace(replace(trim(coalesce(r.version_slug,'')),chr(160),' '),'[[:space:]]+',' ','g');

    if v_version_name<>'' then
      select gv.id into v_version_id
      from public.game_versions gv
      where public.normalize_popn_version(gv.slug)=public.normalize_popn_version(v_version_name)
         or public.normalize_popn_version(gv.name)=public.normalize_popn_version(v_version_name)
      order by case when lower(trim(gv.slug))=lower(trim(v_version_name)) then 0 else 1 end
      limit 1;

      if v_version_id is null then
        insert into public.game_versions(name,slug,sort_order,is_active)
        values(
          v_version_name,
          'master_'||substr(md5(public.normalize_popn_version(v_version_name)),1,24),
          coalesce((select max(sort_order)+1 from public.game_versions),0),
          true
        )
        on conflict(name) do update set is_active=true
        returning id into v_version_id;
      end if;
    end if;

    select s.id into v_song_id from public.songs s where s.master_key=trim(r.master_key) limit 1;
    if v_song_id is null then
      select s.id into v_song_id from public.songs s
      where s.genre=trim(r.genre) and s.title=trim(r.title) and s.artist=trim(r.artist) limit 1;
    end if;

    if v_song_id is null then
      insert into public.songs(master_key,genre,title,artist,banner_url,light_level,normal_level,hyper_level,ex_level,version_id)
      values(trim(r.master_key),trim(r.genre),trim(r.title),trim(r.artist),coalesce(trim(r.banner_url),''),r.light_level,r.normal_level,r.hyper_level,r.ex_level,v_version_id);
    else
      update public.songs set
        master_key=trim(r.master_key),genre=trim(r.genre),title=trim(r.title),artist=trim(r.artist),
        banner_url=case when coalesce(trim(r.banner_url),'')<>'' then trim(r.banner_url) else banner_url end,
        light_level=r.light_level,normal_level=r.normal_level,hyper_level=r.hyper_level,ex_level=r.ex_level,
        version_id=coalesce(v_version_id,version_id),updated_at=now()
      where id=v_song_id;
    end if;
    affected:=affected+1;
  end loop;
  return affected;
end$$;

revoke all on function public.import_song_master_v2(jsonb) from public;
grant execute on function public.import_song_master_v2(jsonb) to authenticated;
