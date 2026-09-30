-- v3.2.49
-- 一般ログインユーザーがWiki難易度を曲一覧・並び替え・画像共有で読み取れるようにする。
-- 書き込み権限は付与しない。既に同等のv3.2.45 SQLを実行済みでも再実行可能。

begin;

alter table public.song_wiki_difficulties enable row level security;
grant select on public.song_wiki_difficulties to authenticated;

drop policy if exists song_wiki_difficulties_admin_select on public.song_wiki_difficulties;
drop policy if exists song_wiki_difficulties_authenticated_select on public.song_wiki_difficulties;
create policy song_wiki_difficulties_authenticated_select
on public.song_wiki_difficulties for select to authenticated
using (true);

-- Wiki同期後は曲カタログのrevisionを進め、ブラウザの永続キャッシュを更新対象にする。
drop trigger if exists psm_wiki_difficulties_revision on public.song_wiki_difficulties;
create trigger psm_wiki_difficulties_revision
after insert or update or delete on public.song_wiki_difficulties
for each statement execute function public.psm_bump_global_revision('songs');

-- この版を適用した端末が旧カタログキャッシュを使わないようrevisionも進める。
insert into public.psm_global_revisions(revision_key,revision,updated_at)
values('songs',1,now())
on conflict(revision_key) do update
set revision=public.psm_global_revisions.revision+1,updated_at=now();

commit;
