-- v2.19.0 要望・不具合の端末情報、履歴表示、管理者削除
-- Supabase SQL Editorで全体を1回実行してください。

alter table public.feedback_reports add column if not exists device_name text not null default '';
alter table public.feedback_reports add column if not exists browser_name text not null default '';

drop policy if exists feedback_admin_delete on public.feedback_reports;
create policy feedback_admin_delete on public.feedback_reports
for delete to authenticated using(public.is_admin());
