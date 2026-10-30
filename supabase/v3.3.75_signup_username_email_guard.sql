-- v3.3.75: block email-like usernames only when creating new auth users.
-- Existing users and change_my_username updates are unaffected.
-- Run in Supabase SQL Editor before publishing the frontend change.
CREATE OR REPLACE FUNCTION public.psm_reject_email_like_signup_username()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $body$
DECLARE
  candidate text;
BEGIN
  candidate := COALESCE(NEW.raw_user_meta_data ->> 'username', '');
  -- Convert fullwidth printable ASCII to ASCII, then remove whitespace.
  candidate := translate(candidate, $fullwidth$！＂＃＄％＆＇（）＊＋，－．／０１２３４５６７８９：；＜＝＞？＠ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ［＼］＾＿｀ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ｛｜｝～$fullwidth$, $ascii$!"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~$ascii$);
  candidate := lower(regexp_replace(candidate, '[[:space:]　]+', '', 'g'));
  IF candidate ~ '[^@]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}' THEN
    RAISE EXCEPTION 'メールアドレス形式の文字列はユーザー名に使用できません。' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$body$;

DROP TRIGGER IF EXISTS psm_reject_email_like_signup_username_trigger ON auth.users;
CREATE TRIGGER psm_reject_email_like_signup_username_trigger
BEFORE INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.psm_reject_email_like_signup_username();

REVOKE ALL ON FUNCTION public.psm_reject_email_like_signup_username() FROM PUBLIC;
