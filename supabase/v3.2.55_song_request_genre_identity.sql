-- v3.2.55: 曲登録依頼の同一曲判定を修正
-- 曲名・アーティストが同じでも、ジャンルが異なる曲は別曲として承認できるようにする。
-- 既存曲への紐付けは「ジャンル・曲名・アーティスト」の正規化一致時のみ。

begin;

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

  -- 曲の同一判定は「ジャンル・曲名・アーティスト」の3項目で行う。
  -- 曲名・アーティストが同じでもジャンルが異なる場合は別曲として扱うため、
  -- タイトル＋アーティストだけで既存曲へ自動的に寄せたり、候補重複エラーにはしない。

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
    current_clear_status,current_medal_code,medal_code,rank_code,source
  )
  select distinct on (p.user_id,p.chart) p.user_id,s_id,p.chart,
    greatest(p.score,p.version_score),p.score,0,p.version_score,
    p.current_clear_status,p.current_medal_code,p.medal_code,p.rank_code,'sync'
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
      when public.user_scores.current_medal_manual and
        (public.psm_medal_category(public.user_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_scores.current_medal_code in ('easy','long_off')))
        then public.psm_medal_category(public.user_scores.current_medal_code)
      else excluded.current_clear_status end,
    current_medal_code=case
      when public.user_scores.current_medal_manual and
        (public.psm_medal_category(public.user_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_scores.current_medal_code in ('easy','long_off')))
        then public.user_scores.current_medal_code
      else excluded.current_medal_code end,
    current_medal_manual=public.user_scores.current_medal_manual and
        (public.psm_medal_category(public.user_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_scores.current_medal_code in ('easy','long_off'))),
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
      version_score,current_clear_status,current_medal_code)
  select distinct on (p.user_id,p.chart,p.game_version_id)
      p.user_id,s_id,p.chart,p.game_version_id,p.version_score,p.current_clear_status,p.current_medal_code
  from public.pending_version_scores p
  where public.normalize_popn_text(p.genre)=public.normalize_popn_text(r.genre)
    and public.normalize_popn_text(p.title)=public.normalize_popn_text(r.title)
    and public.normalize_popn_text(p.artist)=public.normalize_popn_text(r.artist)
    and p.chart=upper(r.chart) and p.level=r.level
  order by p.user_id,p.chart,p.game_version_id,p.updated_at desc,p.id
  on conflict(user_id,song_id,chart,game_version_id) do update set
     version_score=excluded.version_score,
     current_clear_status=case when public.user_version_scores.current_medal_manual and
         (public.psm_medal_category(public.user_version_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_version_scores.current_medal_code in ('easy','long_off')))
         then public.psm_medal_category(public.user_version_scores.current_medal_code)
         else excluded.current_clear_status end,
     current_medal_code=case when public.user_version_scores.current_medal_manual and
         (public.psm_medal_category(public.user_version_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_version_scores.current_medal_code in ('easy','long_off')))
         then public.user_version_scores.current_medal_code else excluded.current_medal_code end,
     current_medal_manual=public.user_version_scores.current_medal_manual and
         (public.psm_medal_category(public.user_version_scores.current_medal_code)=excluded.current_clear_status
          or (excluded.current_clear_status='failed' and public.user_version_scores.current_medal_code in ('easy','long_off'))),
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

revoke all on function public.approve_song_request_v2(uuid) from PUBLIC, anon;
grant execute on function public.approve_song_request_v2(uuid) to authenticated;

commit;
