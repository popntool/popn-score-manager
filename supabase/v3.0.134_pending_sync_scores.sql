-- v3.0.134: 未登録譜面を仮保存し、曲登録依頼の承認と同時に全ユーザーの該当スコアを正式反映。
-- 既存の仮保存以前の同期データは復元できません。デプロイ前にDBバックアップ推奨。
-- SQL Editor で全体を1回実行。先にこのSQLを適用し、次にサイトを更新してください。
begin;

create table if not exists public.pending_sync_scores (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  master_key text not null check(master_key ~ '^[0-9a-f]{64}$'),
  genre text not null, title text not null, artist text not null,
  chart text not null check(chart in ('LIGHT','NORMAL','HYPER','EX')),
  level smallint not null check(level between 1 and 50),
  score integer not null default 0 check(score between 0 and 100000),
  version_score integer not null default 0 check(version_score between 0 and 100000),
  current_clear_status text not null default 'failed'
    check(current_clear_status in ('unplayed','failed','clear','full_combo','perfect')),
  medal_code text not null default 'none', rank_code text not null default 'none',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(user_id,master_key,chart)
);
create index if not exists pending_sync_scores_lookup_idx
  on public.pending_sync_scores(chart,level);
alter table public.pending_sync_scores enable row level security;
-- サーバー側の SECURITY DEFINER 関数のみが仮データを読み書きする。
revoke all on table public.pending_sync_scores from PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.sync_my_scores(p_records jsonb)
 RETURNS TABLE(saved integer, unmatched integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
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
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
      )
      and not exists(
        select 1 from public.songs s
        where public.normalize_popn_text(s.title)=public.normalize_popn_text(x.title)
          and public.normalize_popn_text(s.artist)=public.normalize_popn_text(x.artist)
        having count(*)=1
      )
  )
  insert into public.pending_sync_scores(
    user_id,master_key,genre,title,artist,chart,level,score,version_score,
    current_clear_status,medal_code,rank_code
  )
  select distinct on (x.master_key,upper(trim(x.chart)))
    auth.uid(),x.master_key,trim(x.genre),trim(x.title),trim(x.artist),upper(trim(x.chart)),x.level,
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
  on conflict (user_id,master_key,chart) do update set
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
    current_clear_status,medal_code,rank_code,source
  )
  select distinct on (p.user_id,p.chart) p.user_id,s_id,p.chart,
    greatest(p.score,p.version_score),p.score,0,p.version_score,
    p.current_clear_status,p.medal_code,p.rank_code,'sync'
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
      when excluded.current_clear_status='failed'
       and public.user_scores.current_clear_status in ('easy','long_off')
        then public.user_scores.current_clear_status
      else excluded.current_clear_status end,
    medal_code=excluded.medal_code,rank_code=excluded.rank_code,
    source='sync',updated_at=now();

  -- 正式反映まで成功した仮データのみ削除する。エラー時は承認全体がロールバックされる。
  delete from public.pending_sync_scores p
  where public.normalize_popn_text(p.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(p.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(p.artist)=public.normalize_popn_text(r.artist)
    and p.chart=upper(r.chart) and p.level=r.level;

  delete from public.song_requests where id=p_request_id;
  return true;
end
$function$;

-- PUBLICのデフォルト関数実行権限も取り消す。
revoke all on function public.sync_my_scores(jsonb) from PUBLIC, anon;
grant execute on function public.sync_my_scores(jsonb) to authenticated;
revoke all on function public.approve_song_request_v2(uuid) from PUBLIC, anon;
grant execute on function public.approve_song_request_v2(uuid) to authenticated;
commit;
