-- v3.1.0 / APPLY BEFORE DEPLOYING SITE. Backup database first.
-- High Cheers legacy score columns remain intact; no DELETE or reset occurs.
begin;

alter table public.game_versions add column if not exists sync_path text;
update public.game_versions set sync_path='/game/popn/popn29/'
where slug='master_cdbb557d24080162a681ae5c' and sync_path is null;
alter table public.game_versions drop constraint if exists game_versions_sync_path_format;
alter table public.game_versions add constraint game_versions_sync_path_format
  check(sync_path is null or sync_path ~ '^/game/popn/popn[0-9]+/$');
create unique index if not exists game_versions_sync_path_unique
  on public.game_versions(sync_path) where sync_path is not null;

create table if not exists public.user_version_scores (
 user_id uuid not null references auth.users(id) on delete cascade,
 song_id uuid not null references public.songs(id) on delete cascade,
 chart text not null check(chart in ('LIGHT','NORMAL','HYPER','EX')),
 game_version_id uuid not null references public.game_versions(id) on delete restrict,
 version_score integer not null default 0 check(version_score between 0 and 100000),
 current_clear_status text not null default 'failed' check(current_clear_status in ('unplayed','failed','easy','long_off','clear','full_combo','perfect')),
 updated_at timestamptz not null default now(),
 primary key(user_id,song_id,chart,game_version_id)
);
create index if not exists user_version_scores_by_version on public.user_version_scores(user_id,game_version_id);
alter table public.user_version_scores enable row level security;
drop policy if exists user_version_scores_read_own on public.user_version_scores;
create policy user_version_scores_read_own on public.user_version_scores for select to authenticated using(user_id=auth.uid());
revoke all on public.user_version_scores from PUBLIC,anon,authenticated;
grant select on public.user_version_scores to authenticated;

-- Capture existing High Cheers values before changing synchronization behavior.
insert into public.user_version_scores(user_id,song_id,chart,game_version_id,version_score,current_clear_status)
select s.user_id,s.song_id,s.chart,v.id,s.version_score,s.current_clear_status
from public.user_scores s cross join public.game_versions v
where v.slug='master_cdbb557d24080162a681ae5c'
  and (s.version_score>0 or s.current_clear_status<>'failed')
on conflict(user_id,song_id,chart,game_version_id) do nothing;

create table if not exists public.pending_version_scores (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 game_version_id uuid not null references public.game_versions(id) on delete restrict,
 master_key text not null check(master_key ~ '^[0-9a-f]{64}$'),
 genre text not null,title text not null,artist text not null,
 chart text not null check(chart in ('LIGHT','NORMAL','HYPER','EX')),
 level smallint not null check(level between 1 and 50),
 score integer not null default 0 check(score between 0 and 100000),
 version_score integer not null default 0 check(version_score between 0 and 100000),
 current_clear_status text not null default 'failed' check(current_clear_status in ('unplayed','failed','clear','full_combo','perfect')),
 medal_code text not null default 'none',rank_code text not null default 'none',
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(user_id,game_version_id,master_key,chart)
);
create index if not exists pending_version_scores_lookup_idx on public.pending_version_scores(chart,level);
alter table public.pending_version_scores enable row level security;
revoke all on public.pending_version_scores from PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.sync_my_scores_v31(p_records jsonb,p_game_version_id uuid,p_source_path text)
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
  insert into public.user_version_scores(
    user_id,song_id,chart,game_version_id,version_score,current_clear_status
  )
  select distinct on (x.song_id,upper(x.chart))
    auth.uid(),x.song_id,upper(x.chart),p_game_version_id,
    greatest(0,least(100000,coalesce(x.version_score,0))),
    case lower(coalesce(x.current_clear_status,''))
      when 'unplayed' then 'unplayed' when 'perfect' then 'perfect'
      when 'full_combo' then 'full_combo' when 'clear' then 'clear' else 'failed' end
  from resolved x where x.song_id is not null
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
end$function$;




create or replace function public.save_manual_score_v31(
 p_song_id uuid,p_chart text,p_history_score integer,p_version_score integer,
 p_medal_code text,p_rank_code text,p_current_clear_status text,p_game_version_id uuid)
returns boolean language plpgsql security definer set search_path to '' as $function$
declare
 v_history integer:=greatest(0,least(100000,coalesce(p_history_score,0)));
 v_version integer:=greatest(0,least(100000,coalesce(p_version_score,0)));
 v_status text:=case lower(coalesce(p_current_clear_status,''))
  when 'unplayed' then 'unplayed' when 'easy' then 'easy'
  when 'long_off' then 'long_off' when 'perfect' then 'perfect'
  when 'full_combo' then 'full_combo' when 'clear' then 'clear' else 'failed' end;
 v_high boolean;
begin
 if auth.uid() is null then raise exception 'login required'; end if;
 select slug='master_cdbb557d24080162a681ae5c' into v_high
 from public.game_versions where id=p_game_version_id and is_active=true;
 if v_high is null then raise exception '保存先のゲームバージョンが無効です。'; end if;
 if p_chart not in ('LIGHT','NORMAL','HYPER','EX') or not exists(
    select 1 from public.songs where id=p_song_id) then raise exception '譜面が不正です。'; end if;
 if v_high then
   perform public.save_manual_score_v3(p_song_id,p_chart,v_history,v_version,
      p_medal_code,p_rank_code,v_status);
 else
   insert into public.user_scores(user_id,song_id,chart,score,official_score,
     manual_history_score,version_score,current_clear_status,medal_code,rank_code,source)
   values(auth.uid(),p_song_id,p_chart,greatest(v_history,v_version),0,
     greatest(v_history,v_version),0,'failed',coalesce(nullif(p_medal_code,''),'none'),
     coalesce(nullif(p_rank_code,''),'E'),'manual')
   on conflict(user_id,song_id,chart) do update set
     manual_history_score=greatest(public.user_scores.manual_history_score,excluded.manual_history_score),
     score=greatest(public.user_scores.official_score,public.user_scores.manual_history_score,excluded.manual_history_score,
         public.user_scores.version_score,v_version),
     medal_code=excluded.medal_code,rank_code=excluded.rank_code,
     source='manual',updated_at=now();
 end if;
 insert into public.user_version_scores(user_id,song_id,chart,game_version_id,
     version_score,current_clear_status)
 values(auth.uid(),p_song_id,p_chart,p_game_version_id,v_version,v_status)
 on conflict(user_id,song_id,chart,game_version_id) do update set
   version_score=excluded.version_score,current_clear_status=excluded.current_clear_status,
   updated_at=now();
 return true;
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
      version_score,current_clear_status)
  select distinct on (p.user_id,p.chart,p.game_version_id)
      p.user_id,s_id,p.chart,p.game_version_id,p.version_score,p.current_clear_status
  from public.pending_version_scores p
  where public.normalize_popn_text(p.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(p.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(p.artist)=public.normalize_popn_text(r.artist)
    and p.chart=upper(r.chart) and p.level=r.level
  order by p.user_id,p.chart,p.game_version_id,p.updated_at desc,p.id
  on conflict(user_id,song_id,chart,game_version_id) do update set
     version_score=excluded.version_score,current_clear_status=excluded.current_clear_status,
     updated_at=now();
  delete from public.pending_version_scores p
  where public.normalize_popn_text(p.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(p.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(p.artist)=public.normalize_popn_text(r.artist)
    and p.chart=upper(r.chart) and p.level=r.level;

  delete from public.song_requests where id=p_request_id;
  return true;
end
$function$;


-- Public user-list PSR uses the selected game's score slots, not High Cheers legacy values.
create or replace function public.list_user_summaries_v31(p_search text,p_game_version_id uuid)
returns table(user_id uuid,username text,poptomo_id text,pop_class numeric,official_popn_class numeric,highest_clear_level smallint,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  with raw_values as(
    select us.user_id,us.updated_at,us.medal_code,case when active_version.slug='master_cdbb557d24080162a681ae5c'
       then coalesce(us.version_score,0) else coalesce(slot.version_score,0) end version_score,
      case us.chart when 'LIGHT' then s.light_level when 'NORMAL' then s.normal_level when 'HYPER' then s.hyper_level when 'EX' then s.ex_level end level,
      coalesce(gv.id=active_version.id,false) is_current,
      lower(coalesce(case when active_version.slug='master_cdbb557d24080162a681ae5c'
          then us.current_clear_status else slot.current_clear_status end,'failed')) current_clear_status,
      case lower(coalesce(case when active_version.slug='master_cdbb557d24080162a681ae5c'
          then us.current_clear_status else slot.current_clear_status end,'failed'))
        when 'perfect' then 3000
        when 'full_combo' then 2000
        when 'clear' then 1000
        when 'long_off' then 300
        when 'easy' then 200
        else 0
      end clear_bonus
    from public.user_scores us
    join public.songs s on s.id=us.song_id
    left join public.game_versions gv on gv.id=s.version_id
    left join public.game_versions active_version on active_version.id=p_game_version_id and active_version.is_active=true
    left join public.user_version_scores slot on slot.user_id=us.user_id and slot.song_id=us.song_id
       and slot.chart=us.chart and slot.game_version_id=active_version.id
  ), chart_values as(
    select user_id,updated_at,medal_code,level,is_current,
      case when current_clear_status='unplayed' or version_score<=0 then 0::numeric
      else floor((((level::numeric*level::numeric*version_score::numeric/6000)+clear_bonus)/200)*100)/100
      end song_psr
    from raw_values
  ), ranked as(
    select *,row_number() over(partition by user_id,is_current order by song_psr desc) position
    from chart_values
  ), totals as(
    select user_id,
      floor(((
        coalesce(sum(song_psr) filter(where is_current and position<=20),0)
        + coalesce(sum(song_psr) filter(where not is_current and position<=40),0)
      )/60)*100)/100 pop_class
    from ranked
    group by user_id
  ), clears as(
    select user_id,max(level)::smallint highest_clear_level,max(updated_at) updated_at
    from chart_values
    where lower(medal_code) in('perfect','a','fc_1_5','b','fc_6_20','c','fc_21_plus','d','clear_bad_1_5','e','clear_bad_6_20','f','clear_bad_21_plus','g')
    group by user_id
  )
  select p.id,p.username,case when p.poptomo_public then p.poptomo_id else null end,
    case when p.psr_public then coalesce(t.pop_class,0) else null end,case when p.popn_class_public then p.official_popn_class else null end,case when p.highest_clear_public then c.highest_clear_level else null end,c.updated_at
  from public.profiles p
  left join totals t on t.user_id=p.id
  left join clears c on c.user_id=p.id
  where p.username ilike '%'||coalesce(p_search,'')||'%'
    and (not exists(select 1 from public.admin_users a where a.user_id=p.id) or exists(select 1 from public.visible_admin_users v where v.user_id=p.id))
  order by p.username
$$;
revoke all on function public.list_user_summaries_v31(text,uuid) from PUBLIC;
grant execute on function public.list_user_summaries_v31(text,uuid) to anon,authenticated;

revoke all on function public.sync_my_scores_v31(jsonb,uuid,text) from PUBLIC,anon;
grant execute on function public.sync_my_scores_v31(jsonb,uuid,text) to authenticated;
revoke all on function public.save_manual_score_v31(uuid,text,integer,integer,text,text,text,uuid) from PUBLIC,anon;
grant execute on function public.save_manual_score_v31(uuid,text,integer,integer,text,text,text,uuid) to authenticated;
revoke all on function public.approve_song_request_v2(uuid) from PUBLIC,anon;
grant execute on function public.approve_song_request_v2(uuid) to authenticated;
commit;
