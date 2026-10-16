-- v3.3.68: Normalize ASCII @ and fullwidth ＠ consistently in all matching paths.
-- Run in Supabase SQL Editor before uploading the version bump files.
-- Transaction rolls back automatically if this change would merge distinct song identities.
BEGIN;
DO $check$
DECLARE v_collisions integer;
BEGIN
  SELECT count(*) INTO v_collisions FROM (
    SELECT public.normalize_popn_text(genre) AS genre_key,
           public.normalize_popn_text(title) AS title_key,
           public.normalize_popn_text(replace(artist, '＠', '@')) AS artist_key
    FROM public.songs
    GROUP BY 1,2,3 HAVING count(*) > 1
  ) duplicates;
  IF v_collisions > 0 THEN
    RAISE EXCEPTION 'Aborted: % song identity collisions after @ normalization. No changes applied.', v_collisions;
  END IF;
END
$check$;

CREATE OR REPLACE FUNCTION public.normalize_popn_text(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT lower(regexp_replace(
    translate(replace(coalesce(p_value,''), '＠', '@'),
      '　０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ＆！？（）／＋－',
      ' 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz&!?()/+-'),
    '[[:space:]]+','','g'))
$$;
COMMIT;

-- Read-only verification after successful commit:
-- SELECT public.normalize_popn_text('cosMo＠暴走P') = public.normalize_popn_text('cosMo@暴走P') AS same_artist;
