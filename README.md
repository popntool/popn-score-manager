# pop'n Score Manager

pop'n musicのスコア・メダルを管理する非公式Webアプリです。GitHub PagesとSupabaseで動作します。

## ファイル構成

- `index.html`：画面構造
- `css/`：基本、部品、テーマ、スマホ向けスタイル
- `js/app.js`：アプリ起動と画面イベント
- `js/auth.js`：ログイン・新規登録
- `js/scores.js`：スコア登録・同期
- `js/songs.js`：曲検索・曲マスター投入
- `js/users.js`：ユーザー一覧
- `js/supabase.js`：Supabase接続
- `js/config.js`：公開用Supabase設定
- `supabase/schema.sql`：初期データベース
- `tools/`：e-amusement用抽出・同期スクリプト

## 初期設定

1. Supabaseで新規プロジェクトを作成します。
2. SQL Editorで`supabase/schema.sql`全体を実行します。
3. Authenticationのメール確認を無効にします。
4. Project URLとPublishable/Anon Keyを`js/config.js`へ設定します。
5. GitHub Pagesを`main`ブランチのルートから公開します。

`service_role key`、データベースパスワード、個人用アクセストークンはGitHubへ登録しないでください。

