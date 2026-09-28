-- v3.2.33
-- 曲マスター／ゲームバージョン／ユーザースコアの「更新番号」だけを返し、
-- ブラウザ側が前回取得済みのスコアカタログを再利用できるようにする。
-- 実データを返さないため、通常の再訪問時のEgressを大幅に抑える目的。

begin;

create table if not exists public.psm_global_revisions (
  revision_key text primary key,
  revision bigint not null default 1,
  updated_at timestamptz not null default now()
);

insert into public.psm_global_revisions(revision_key,revision)
values ('songs',1),('game_versions',1)
on conflict(revision_key) do nothing;

create table if not exists public.psm_user_score_revisions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 1,
  updated_at timestamptz not null default now()
);

-- 既存ユーザーは現在の状態を revision=1 として開始する。
insert into public.psm_user_score_revisions(user_id,revision)
select user_id,1 from (
  select distinct user_id from public.user_scores
  union
  select distinct user_id from public.user_version_scores
) u
on conflict(user_id) do nothing;

create or replace function public.psm_bump_global_revision()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  insert into public.psm_global_revisions(revision_key,revision,updated_at)
  values (tg_argv[0],2,now())
  on conflict(revision_key) do update
    set revision=public.psm_global_revisions.revision+1,
        updated_at=now();
  return null;
end;
$$;

create or replace function public.psm_bump_user_revisions(p_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if p_user_ids is null or cardinality(p_user_ids)=0 then return; end if;
  insert into public.psm_user_score_revisions(user_id,revision,updated_at)
  select id,1,now() from unnest(p_user_ids) as id
  on conflict(user_id) do update
    set revision=public.psm_user_score_revisions.revision+1,
        updated_at=now();
end;
$$;

create or replace function public.psm_user_revision_after_insert()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare ids uuid[];
begin
  select array_agg(distinct user_id) into ids from new_rows;
  perform public.psm_bump_user_revisions(ids);
  return null;
end;
$$;

create or replace function public.psm_user_revision_after_update()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare ids uuid[];
begin
  select array_agg(distinct user_id) into ids
  from (select user_id from old_rows union select user_id from new_rows) u;
  perform public.psm_bump_user_revisions(ids);
  return null;
end;
$$;

create or replace function public.psm_user_revision_after_delete()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare ids uuid[];
begin
  select array_agg(distinct user_id) into ids from old_rows;
  perform public.psm_bump_user_revisions(ids);
  return null;
end;
$$;

-- 曲マスターとバージョン情報は1文につき1回だけ更新番号を進める。
drop trigger if exists psm_songs_revision on public.songs;
create trigger psm_songs_revision
after insert or update or delete on public.songs
for each statement execute function public.psm_bump_global_revision('songs');

drop trigger if exists psm_game_versions_revision on public.game_versions;
create trigger psm_game_versions_revision
after insert or update or delete on public.game_versions
for each statement execute function public.psm_bump_global_revision('game_versions');

-- user_scores はバッチ同期でも1文につき対象ユーザーだけrevisionを更新。
drop trigger if exists psm_user_scores_revision_insert on public.user_scores;
create trigger psm_user_scores_revision_insert
after insert on public.user_scores
referencing new table as new_rows
for each statement execute function public.psm_user_revision_after_insert();

drop trigger if exists psm_user_scores_revision_update on public.user_scores;
create trigger psm_user_scores_revision_update
after update on public.user_scores
referencing old table as old_rows new table as new_rows
for each statement execute function public.psm_user_revision_after_update();

drop trigger if exists psm_user_scores_revision_delete on public.user_scores;
create trigger psm_user_scores_revision_delete
after delete on public.user_scores
referencing old table as old_rows
for each statement execute function public.psm_user_revision_after_delete();

-- 過去作／今作スロット側も同じrevisionへ反映。
drop trigger if exists psm_user_version_scores_revision_insert on public.user_version_scores;
create trigger psm_user_version_scores_revision_insert
after insert on public.user_version_scores
referencing new table as new_rows
for each statement execute function public.psm_user_revision_after_insert();

drop trigger if exists psm_user_version_scores_revision_update on public.user_version_scores;
create trigger psm_user_version_scores_revision_update
after update on public.user_version_scores
referencing old table as old_rows new table as new_rows
for each statement execute function public.psm_user_revision_after_update();

drop trigger if exists psm_user_version_scores_revision_delete on public.user_version_scores;
create trigger psm_user_version_scores_revision_delete
after delete on public.user_version_scores
referencing old table as old_rows
for each statement execute function public.psm_user_revision_after_delete();

create or replace function public.get_score_catalog_revision_v3233()
returns table(
  song_revision bigint,
  game_version_revision bigint,
  user_score_revision bigint
)
language sql
stable
security definer
set search_path=public
as $$
  select
    coalesce((select revision from public.psm_global_revisions where revision_key='songs'),0)::bigint,
    coalesce((select revision from public.psm_global_revisions where revision_key='game_versions'),0)::bigint,
    coalesce((select revision from public.psm_user_score_revisions where user_id=auth.uid()),0)::bigint;
$$;

revoke all on function public.get_score_catalog_revision_v3233() from public,anon;
grant execute on function public.get_score_catalog_revision_v3233() to authenticated;

commit;
