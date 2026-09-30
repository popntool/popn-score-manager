-- v3.2.45: Wiki難易度を一般ログインユーザーの曲一覧・画像共有・並び替えで利用する。
-- 書き込みは引き続きEdge Function（service role）のみ。

alter table public.song_wiki_difficulties enable row level security;
grant select on public.song_wiki_difficulties to authenticated;

drop policy if exists song_wiki_difficulties_admin_select on public.song_wiki_difficulties;
drop policy if exists song_wiki_difficulties_authenticated_select on public.song_wiki_difficulties;
create policy song_wiki_difficulties_authenticated_select
on public.song_wiki_difficulties for select to authenticated
using (true);

-- Wiki同期で値が変わったら、既存の曲カタログrevisionを更新してIndexedDBキャッシュを無効化する。
drop trigger if exists psm_wiki_difficulties_revision on public.song_wiki_difficulties;
create trigger psm_wiki_difficulties_revision
after insert or update or delete on public.song_wiki_difficulties
for each statement execute function public.psm_bump_global_revision('songs');

-- このマイグレーション適用直後も旧キャッシュを一度だけ破棄する。
insert into public.psm_global_revisions(revision_key,revision,updated_at)
values('songs',1,now())
on conflict(revision_key) do update
set revision=public.psm_global_revisions.revision+1,updated_at=now();
