-- v3.2.54: Supabase Security Advisor対応 / 要望・不具合送信の保護
-- Supabase SQL Editorで全体を1回実行してください。
-- 既存データは変更しません。

begin;

-- Security Advisor: publicスキーマの補助テーブルにもRLSを必ず有効化する。
-- これらはブラウザから直接読み書きせず、既存のSECURITY DEFINER関数・トリガー経由でのみ利用する。
alter table public.psm_global_revisions enable row level security;
alter table public.psm_user_score_revisions enable row level security;
alter table public.visible_admin_users enable row level security;

revoke all on table public.psm_global_revisions from public, anon, authenticated;
revoke all on table public.psm_user_score_revisions from public, anon, authenticated;
revoke all on table public.visible_admin_users from public, anon, authenticated;

-- feedback_reportsへの直接INSERTを止め、入力検証・送信間隔制限を行うRPCだけを公開する。
-- SELECT/UPDATE/DELETEは既存RLSポリシーをそのまま利用する。
revoke insert on table public.feedback_reports from anon, authenticated;

create or replace function public.submit_feedback_v3254(
  p_category text,
  p_message text,
  p_device_name text default '',
  p_browser_name text default '',
  p_page_url text default '',
  p_user_agent text default ''
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_user_id uuid := auth.uid();
  v_category text := lower(btrim(coalesce(p_category,'')));
  v_message text := btrim(coalesce(p_message,''));
  v_device text := btrim(coalesce(p_device_name,''));
  v_browser text := btrim(coalesce(p_browser_name,''));
  v_page text := btrim(coalesce(p_page_url,''));
  v_agent text := btrim(coalesce(p_user_agent,''));
  v_id uuid;
  v_official_count integer;
  v_registered_count integer;
begin
  if v_user_id is null then
    raise exception 'ログインが必要です。';
  end if;
  if v_category not in ('request','bug') then
    raise exception '種類が不正です。';
  end if;
  if v_message='' then
    raise exception '内容を入力してください。';
  end if;
  if char_length(v_message)>3000 then
    raise exception '内容は3000文字以内で入力してください。';
  end if;
  if char_length(v_device)>100 or char_length(v_browser)>100 then
    raise exception '機種名・ブラウザ名は100文字以内で入力してください。';
  end if;

  -- PCM本体には存在しない自動照合ログが、そのまま大量投稿されるケースを防ぐ。
  -- 1件だけの差異説明は許可し、複数件の機械生成ログだけを拒否する。
  v_official_count := (char_length(lower(v_message))-char_length(replace(lower(v_message),'official:',''))) / char_length('official:');
  v_registered_count := (char_length(lower(v_message))-char_length(replace(lower(v_message),'registered:',''))) / char_length('registered:');
  if v_official_count>=2 and v_registered_count>=2 then
    raise exception '自動生成された照合ログはそのまま送信できません。問題の内容を要約して送信してください。';
  end if;

  -- 誤操作・スクリプト暴走による短時間の連続投稿を抑止する。
  if exists(
    select 1 from public.feedback_reports
    where user_id=v_user_id and created_at>now()-interval '15 seconds'
  ) then
    raise exception '連続送信を防ぐため、少し待ってから再度送信してください。';
  end if;

  insert into public.feedback_reports(
    user_id,category,message,device_name,browser_name,page_url,user_agent
  ) values (
    v_user_id,
    v_category,
    v_message,
    left(v_device,100),
    left(v_browser,100),
    left(v_page,1000),
    left(v_agent,1000)
  ) returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_feedback_v3254(text,text,text,text,text,text) from public, anon;
grant execute on function public.submit_feedback_v3254(text,text,text,text,text,text) to authenticated;

commit;
