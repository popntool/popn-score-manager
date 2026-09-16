-- PSR snapshots: private to the authenticated owner; never exposed through user/rival RPCs.
create table if not exists public.psr_snapshots (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(),
 total numeric(8,2) not null check (total >= 0),
 official_popn_class numeric(8,2),
 rows jsonb not null check (jsonb_typeof(rows) = 'array' and jsonb_array_length(rows) <= 60),
 automatic boolean not null default false
);
create index if not exists psr_snapshots_user_created_idx on public.psr_snapshots(user_id,created_at desc);
alter table public.psr_snapshots enable row level security;
revoke all on public.psr_snapshots from anon;
grant select,insert,delete on public.psr_snapshots to authenticated;
drop policy if exists psr_snapshots_select_self on public.psr_snapshots;
create policy psr_snapshots_select_self on public.psr_snapshots for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists psr_snapshots_insert_self on public.psr_snapshots;
create policy psr_snapshots_insert_self on public.psr_snapshots for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists psr_snapshots_delete_self on public.psr_snapshots;
create policy psr_snapshots_delete_self on public.psr_snapshots for delete to authenticated using (user_id = (select auth.uid()));
