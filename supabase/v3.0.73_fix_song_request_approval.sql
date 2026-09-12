-- v3.0.73 登録依頼承認時の digest()/pgcrypto 依存を除去
-- Supabase SQL Editorで、このファイル全体を1回実行してください。
--
-- approve_song_request_v2() が新規曲を作成するときに digest(..., 'sha256') を
-- 呼んでいたため、pgcrypto が利用できない環境では
-- "function digest(text, unknown) does not exist" で承認に失敗していました。
--
-- 既存曲の照合は normalize_popn_text() を使用し、新規曲の仮 master_key は
-- PostgreSQL標準の md5() を2本連結した64桁hexで生成します。
-- 後から正式な曲マスターを投入した場合は、既存の import_song_master() が
-- (genre,title,artist) の競合時に正式な master_key へ更新できます。

create or replace function public.approve_song_request_v2(p_request_id uuid)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
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

  -- 完全な曲情報一致が無い場合、正規化した曲名がマスター内で一意なら同じ曲として扱う。
  if s_id is null then
    select min(s.id::text)::uuid into s_id
    from public.songs s
    where public.normalize_popn_text(s.title)=public.normalize_popn_text(r.title)
    having count(*)=1;
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

  delete from public.song_requests where id=p_request_id;
  return true;
end
$$;

revoke all on function public.approve_song_request_v2(uuid) from public;
grant execute on function public.approve_song_request_v2(uuid) to authenticated;
