-- v3.2.36 管理者向け popn.wiki 難易度同期の保存先
create table if not exists public.song_wiki_difficulties(
  song_id uuid not null references public.songs(id) on delete cascade,
  chart text not null check(chart in('LIGHT','NORMAL','HYPER','EX')),
  level smallint not null check(level between 1 and 50),
  difficulty_text text not null,
  difficulty_label text not null,
  difficulty_value numeric(7,3),
  difficulty_sigma numeric(7,3),
  source_url text not null,
  synced_at timestamptz not null default now(),
  primary key(song_id,chart)
);

alter table public.song_wiki_difficulties enable row level security;
grant select on public.song_wiki_difficulties to authenticated;
revoke insert,update,delete on public.song_wiki_difficulties from anon,authenticated;

drop policy if exists song_wiki_difficulties_admin_select on public.song_wiki_difficulties;
create policy song_wiki_difficulties_admin_select
on public.song_wiki_difficulties for select to authenticated
using(public.is_admin());

create index if not exists song_wiki_difficulties_level_idx
on public.song_wiki_difficulties(level,chart);
