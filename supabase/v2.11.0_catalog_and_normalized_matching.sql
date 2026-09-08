-- v2.11.0 最新曲マスターとの依頼統合・表記ゆれを吸収した同期照合
-- このファイル全体をSupabase SQL Editorで1回実行してください。

create or replace function public.normalize_popn_text(p_value text)
returns text language sql immutable parallel safe as $$
  select lower(regexp_replace(
    translate(coalesce(p_value,''),
      '　０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ＆！？（）／＋－',
      ' 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz&!?()/+-'),
    '[[:space:]]+','','g'))
$$;
revoke all on function public.normalize_popn_text(text) from public;

-- 現在および今後の依頼を最新版マスターへ統合する。既存難易度はマスターを正とする。
create or replace function public.merge_song_requests_into_master()
returns integer language plpgsql security definer set search_path=public as $$
declare v_deleted integer;
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'admin only';end if;
  with matched as(
    select s.id,
      max(r.level) filter(where upper(r.chart)='LIGHT') light_level,
      max(r.level) filter(where upper(r.chart)='NORMAL') normal_level,
      max(r.level) filter(where upper(r.chart)='HYPER') hyper_level,
      max(r.level) filter(where upper(r.chart)='EX') ex_level
    from public.songs s join public.song_requests r
      on public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
     and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
     and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist)
    where r.status in('pending','approved') group by s.id
  )
  update public.songs s set
    light_level=coalesce(s.light_level,m.light_level),normal_level=coalesce(s.normal_level,m.normal_level),
    hyper_level=coalesce(s.hyper_level,m.hyper_level),ex_level=coalesce(s.ex_level,m.ex_level),updated_at=now()
  from matched m where s.id=m.id;
  delete from public.song_requests r using public.songs s
  where r.status in('pending','approved')
    and public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist);
  get diagnostics v_deleted=row_count;
  return v_deleted;
end$$;
revoke all on function public.merge_song_requests_into_master() from public;
grant execute on function public.merge_song_requests_into_master() to authenticated;

select public.merge_song_requests_into_master();

create or replace function public.submit_song_request_v2(
  p_genre text,p_title text,p_artist text,p_chart text,p_level integer,p_note text default ''
) returns text language plpgsql security definer set search_path=public as $$
declare v_song_id uuid;v_chart text:=upper(trim(p_chart));v_level integer:=p_level;
begin
  if auth.uid() is null then raise exception 'login required';end if;
  if coalesce(trim(p_genre),'')='' or coalesce(trim(p_title),'')='' or coalesce(trim(p_artist),'')='' then raise exception '曲情報を入力してください。';end if;
  if v_chart not in('LIGHT','NORMAL','HYPER','EX') or v_level not between 1 and 50 then raise exception '譜面またはレベルが不正です。';end if;
  select id into v_song_id from public.songs
   where public.normalize_popn_text(genre)=public.normalize_popn_text(p_genre)
     and public.normalize_popn_text(title)=public.normalize_popn_text(p_title)
     and public.normalize_popn_text(artist)=public.normalize_popn_text(p_artist) limit 1;
  if v_song_id is not null then
    update public.songs set
      light_level=case when v_chart='LIGHT' then coalesce(light_level,v_level) else light_level end,
      normal_level=case when v_chart='NORMAL' then coalesce(normal_level,v_level) else normal_level end,
      hyper_level=case when v_chart='HYPER' then coalesce(hyper_level,v_level) else hyper_level end,
      ex_level=case when v_chart='EX' then coalesce(ex_level,v_level) else ex_level end,
      updated_at=now()
    where id=v_song_id;
    delete from public.song_requests where status in('pending','approved')
      and public.normalize_popn_text(genre)=public.normalize_popn_text(p_genre)
      and public.normalize_popn_text(title)=public.normalize_popn_text(p_title)
      and public.normalize_popn_text(artist)=public.normalize_popn_text(p_artist);
    return 'merged';
  end if;
  if not exists(select 1 from public.song_requests where user_id=auth.uid() and status='pending'
    and public.normalize_popn_text(genre)=public.normalize_popn_text(p_genre)
    and public.normalize_popn_text(title)=public.normalize_popn_text(p_title)
    and public.normalize_popn_text(artist)=public.normalize_popn_text(p_artist)
    and chart=v_chart and level=v_level) then
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

  with matched as(
    select s.id,
      max(x.level) filter(where upper(x.chart)='LIGHT') light_level,
      max(x.level) filter(where upper(x.chart)='NORMAL') normal_level,
      max(x.level) filter(where upper(x.chart)='HYPER') hyper_level,
      max(x.level) filter(where upper(x.chart)='EX') ex_level
    from public.songs s join jsonb_to_recordset(p_records)
      x(master_key text,genre text,title text,artist text,chart text,level smallint,score integer)
      on s.master_key=x.master_key or(
        public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
        and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
        and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist))
    where coalesce(x.score,0)>0 group by s.id
  )
  update public.songs s set
    light_level=coalesce(s.light_level,m.light_level),normal_level=coalesce(s.normal_level,m.normal_level),
    hyper_level=coalesce(s.hyper_level,m.hyper_level),ex_level=coalesce(s.ex_level,m.ex_level),updated_at=now()
  from matched m where s.id=m.id;

  insert into public.song_requests(user_id,genre,title,artist,chart,level,note,status)
  select auth.uid(),trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),x.level,'公式サイト同期で曲マスター未登録','pending'
  from jsonb_to_recordset(p_records) x(master_key text,genre text,title text,artist text,chart text,level smallint,score integer)
  where coalesce(x.score,0)>0 and coalesce(trim(x.genre),'')<>'' and coalesce(trim(x.title),'')<>'' and coalesce(trim(x.artist),'')<>''
    and upper(trim(x.chart)) in('LIGHT','NORMAL','HYPER','EX') and x.level between 1 and 50
    and not exists(select 1 from public.songs s where s.master_key=x.master_key or(
      public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
      and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
      and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)))
    and not exists(select 1 from public.song_requests r where r.user_id=auth.uid() and r.status='pending'
      and public.normalize_popn_text(r.genre)=public.normalize_popn_text(x.genre)
      and public.normalize_popn_text(r.title)=public.normalize_popn_text(x.title)
      and public.normalize_popn_text(r.artist)=public.normalize_popn_text(x.artist)
      and r.chart=upper(trim(x.chart)) and r.level=x.level);

  insert into public.user_scores(user_id,song_id,chart,score,official_score,manual_history_score,version_score,medal_code,rank_code,source)
  select auth.uid(),m.id,upper(x.chart),greatest(greatest(1,least(100000,x.score)),greatest(0,least(100000,coalesce(x.version_score,0)))),
    greatest(1,least(100000,x.score)),0,greatest(0,least(100000,coalesce(x.version_score,0))),
    coalesce(nullif(x.medal_code,''),'none'),coalesce(nullif(x.rank_code,''),'none'),'sync'
  from jsonb_to_recordset(p_records) x(master_key text,genre text,title text,artist text,chart text,score integer,version_score integer,medal_code text,rank_code text)
  join lateral(select s.id from public.songs s where s.master_key=x.master_key or(
    public.normalize_popn_text(s.genre)=public.normalize_popn_text(x.genre)
    and public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
    and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist))
    order by (s.master_key=x.master_key) desc limit 1) m on true
  where coalesce(x.score,0)>0
  on conflict(user_id,song_id,chart) do update set
    official_score=excluded.official_score,version_score=excluded.version_score,
    score=greatest(excluded.official_score,public.user_scores.manual_history_score,excluded.version_score),
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,source='sync',updated_at=now();
  get diagnostics v_saved=row_count;

  delete from public.song_requests r using public.songs s where r.status in('pending','approved')
    and public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.artist);
  return query select v_saved,greatest(0,v_total-v_saved);
end$$;
revoke all on function public.sync_my_scores(jsonb) from public;
grant execute on function public.sync_my_scores(jsonb) to authenticated;
