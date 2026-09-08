-- v2.8.0 登録依頼の自動統合・同期照合改善・曲バナー画像アップロード
-- Supabase SQL Editorで、このファイル全体を1回実行してください。

-- 既存の未対応依頼を、ジャンル・曲名・アーティストが一致する曲へ統合する。
with matched as (
  select s.id,
    max(r.level) filter(where r.chart='LIGHT') as light_level,
    max(r.level) filter(where r.chart='NORMAL') as normal_level,
    max(r.level) filter(where r.chart='HYPER') as hyper_level,
    max(r.level) filter(where r.chart='EX') as ex_level
  from public.songs s join public.song_requests r
    on lower(trim(s.genre))=lower(trim(r.genre))
   and lower(trim(s.title))=lower(trim(r.title))
   and lower(trim(s.artist))=lower(trim(r.artist))
  where r.status='pending' group by s.id
)
update public.songs s set
  light_level=coalesce(s.light_level,m.light_level),
  normal_level=coalesce(s.normal_level,m.normal_level),
  hyper_level=coalesce(s.hyper_level,m.hyper_level),
  ex_level=coalesce(s.ex_level,m.ex_level)
from matched m where s.id=m.id;

delete from public.song_requests r using public.songs s
where r.status='pending'
  and lower(trim(s.genre))=lower(trim(r.genre))
  and lower(trim(s.title))=lower(trim(r.title))
  and lower(trim(s.artist))=lower(trim(r.artist));

create or replace function public.submit_song_request_v2(
  p_genre text,p_title text,p_artist text,p_chart text,p_level integer,p_note text default ''
) returns text language plpgsql security definer set search_path=public as $$
declare v_song_id uuid;v_chart text:=upper(trim(p_chart));v_level integer:=p_level;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  if coalesce(trim(p_genre),'')='' or coalesce(trim(p_title),'')='' or coalesce(trim(p_artist),'')='' then raise exception '曲情報を入力してください。';end if;
  if v_chart not in('LIGHT','NORMAL','HYPER','EX') or v_level not between 1 and 50 then raise exception '譜面またはレベルが不正です。';end if;
  select id into v_song_id from public.songs
   where lower(trim(genre))=lower(trim(p_genre)) and lower(trim(title))=lower(trim(p_title)) and lower(trim(artist))=lower(trim(p_artist)) limit 1;
  if v_song_id is not null then
    update public.songs set
      light_level=case when v_chart='LIGHT' then coalesce(light_level,v_level) else light_level end,
      normal_level=case when v_chart='NORMAL' then coalesce(normal_level,v_level) else normal_level end,
      hyper_level=case when v_chart='HYPER' then coalesce(hyper_level,v_level) else hyper_level end,
      ex_level=case when v_chart='EX' then coalesce(ex_level,v_level) else ex_level end
    where id=v_song_id;
    delete from public.song_requests where status='pending'
      and lower(trim(genre))=lower(trim(p_genre)) and lower(trim(title))=lower(trim(p_title)) and lower(trim(artist))=lower(trim(p_artist));
    return 'merged';
  end if;
  if not exists(select 1 from public.song_requests where user_id=auth.uid() and status='pending'
    and lower(trim(genre))=lower(trim(p_genre)) and lower(trim(title))=lower(trim(p_title))
    and lower(trim(artist))=lower(trim(p_artist)) and chart=v_chart and level=v_level) then
    insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
    values(auth.uid(),trim(p_genre),trim(p_title),trim(p_artist),v_chart,v_level,coalesce(p_note,''),'pending');
  end if;
  return 'requested';
end$$;
revoke all on function public.submit_song_request_v2(text,text,text,text,integer,text) from public;
grant execute on function public.submit_song_request_v2(text,text,text,text,integer,text) to authenticated;

create or replace function public.sync_my_scores(p_records jsonb)
returns table(saved integer,unmatched integer)
language plpgsql security definer set search_path=public as $$
declare v_saved integer;v_total integer;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  select count(*) into v_total from jsonb_to_recordset(p_records) x(score integer) where coalesce(x.score,0)>0;

  with matched as (
    select s.id,
      max(x.level) filter(where upper(x.chart)='LIGHT') as light_level,
      max(x.level) filter(where upper(x.chart)='NORMAL') as normal_level,
      max(x.level) filter(where upper(x.chart)='HYPER') as hyper_level,
      max(x.level) filter(where upper(x.chart)='EX') as ex_level
    from public.songs s join jsonb_to_recordset(p_records)
      x(master_key text,genre text,title text,artist text,chart text,level smallint,score integer)
      on s.master_key=x.master_key or (lower(trim(s.genre))=lower(trim(x.genre)) and lower(trim(s.title))=lower(trim(x.title)) and lower(trim(s.artist))=lower(trim(x.artist)))
    where coalesce(x.score,0)>0 group by s.id
  )
  update public.songs s set light_level=coalesce(s.light_level,m.light_level),normal_level=coalesce(s.normal_level,m.normal_level),
    hyper_level=coalesce(s.hyper_level,m.hyper_level),ex_level=coalesce(s.ex_level,m.ex_level)
  from matched m where s.id=m.id;

  insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
  select auth.uid(),trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),x.level,'公式サイト同期で曲マスター未登録','pending'
  from jsonb_to_recordset(p_records) x(master_key text,genre text,title text,artist text,chart text,level smallint,score integer)
  where coalesce(x.score,0)>0 and coalesce(trim(x.genre),'')<>'' and coalesce(trim(x.title),'')<>'' and coalesce(trim(x.artist),'')<>''
    and upper(trim(x.chart)) in('LIGHT','NORMAL','HYPER','EX') and x.level between 1 and 50
    and not exists(select 1 from public.songs s where s.master_key=x.master_key or (
      lower(trim(s.genre))=lower(trim(x.genre)) and lower(trim(s.title))=lower(trim(x.title)) and lower(trim(s.artist))=lower(trim(x.artist))))
    and not exists(select 1 from public.song_requests r where r.user_id=auth.uid() and r.status='pending'
      and lower(trim(r.genre))=lower(trim(x.genre)) and lower(trim(r.title))=lower(trim(x.title)) and lower(trim(r.artist))=lower(trim(x.artist))
      and r.chart=upper(trim(x.chart)) and r.level=x.level);

  insert into public.user_scores(user_id,song_id,chart,score,official_score,manual_history_score,version_score,medal_code,rank_code,source)
  select auth.uid(),m.id,upper(x.chart),greatest(greatest(1,least(100000,x.score)),greatest(0,least(100000,coalesce(x.version_score,0)))),
    greatest(1,least(100000,x.score)),0,greatest(0,least(100000,coalesce(x.version_score,0))),
    coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from jsonb_to_recordset(p_records) x(master_key text,genre text,title text,artist text,chart text,score integer,version_score integer,medal_code text,rank_code text)
  join lateral(select s.id from public.songs s where s.master_key=x.master_key or (
    lower(trim(s.genre))=lower(trim(x.genre)) and lower(trim(s.title))=lower(trim(x.title)) and lower(trim(s.artist))=lower(trim(x.artist)))
    order by (s.master_key=x.master_key) desc limit 1) m on true
  where coalesce(x.score,0)>0
  on conflict(user_id,song_id,chart) do update set
    official_score=excluded.official_score,version_score=excluded.version_score,
    score=greatest(excluded.official_score,public.user_scores.manual_history_score,excluded.version_score),
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='sync',updated_at=now();
  get diagnostics v_saved=row_count;

  delete from public.song_requests r using public.songs s where r.status='pending'
    and lower(trim(s.genre))=lower(trim(r.genre)) and lower(trim(s.title))=lower(trim(r.title)) and lower(trim(s.artist))=lower(trim(r.artist));
  return query select v_saved,greatest(0,v_total-v_saved);
end$$;
revoke all on function public.sync_my_scores(jsonb) from public;
grant execute on function public.sync_my_scores(jsonb) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('song-banners','song-banners',true,2097152,array['image/png','image/jpeg','image/webp','image/gif'])
on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists song_banners_public_read on storage.objects;
create policy song_banners_public_read on storage.objects for select using(bucket_id='song-banners');
drop policy if exists song_banners_admin_insert on storage.objects;
create policy song_banners_admin_insert on storage.objects for insert to authenticated with check(bucket_id='song-banners' and public.is_admin());
drop policy if exists song_banners_admin_update on storage.objects;
create policy song_banners_admin_update on storage.objects for update to authenticated using(bucket_id='song-banners' and public.is_admin()) with check(bucket_id='song-banners' and public.is_admin());
drop policy if exists song_banners_admin_delete on storage.objects;
create policy song_banners_admin_delete on storage.objects for delete to authenticated using(bucket_id='song-banners' and public.is_admin());
