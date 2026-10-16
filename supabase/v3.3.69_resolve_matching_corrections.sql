-- v3.3.69: Close only old pending correction requests whose full song identity
-- (genre + title + artist) safely matches exactly one current master.
-- Requires v3.3.68 normalization to have been applied first.
-- Does not modify songs, song IDs, master keys or user scores.
BEGIN;

DO $guard$
DECLARE v_ambiguous integer;
BEGIN
  IF public.normalize_popn_text('＠n　H＠ppy　Choice') <> public.normalize_popn_text('@n H@ppy Choice')
     OR public.normalize_popn_text('cosMo＠暴走P') <> public.normalize_popn_text('cosMo@暴走P') THEN
    RAISE EXCEPTION 'v3.3.68 normalization is not active. Aborted.';
  END IF;
  SELECT count(*) INTO v_ambiguous
  FROM public.sync_song_correction_requests r
  WHERE r.status='pending'
    AND r.official_title IN (
      '彼岸花','MADSPEED狂信道','MADSPEED狂信道(UPPER)',
      'Last Twilight','バンブーソード・ガール',
      '@n H@ppy Choice','＠n　H＠ppy　Choice'
    )
    AND (SELECT count(*) FROM public.songs s
         WHERE public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.official_genre)
           AND public.normalize_popn_text(s.title)=public.normalize_popn_text(r.official_title)
           AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.official_artist)) > 1;
  IF v_ambiguous > 0 THEN
    RAISE EXCEPTION 'Multiple matching songs found for % pending request(s); no changes applied.',v_ambiguous;
  END IF;
END
$guard$;

WITH uniquely_matched AS (
 SELECT r.fingerprint, min(s.id::text)::uuid AS song_id
 FROM public.sync_song_correction_requests r
 JOIN public.songs s
   ON public.normalize_popn_text(s.genre)=public.normalize_popn_text(r.official_genre)
  AND public.normalize_popn_text(s.title)=public.normalize_popn_text(r.official_title)
  AND public.normalize_popn_text(s.artist)=public.normalize_popn_text(r.official_artist)
 WHERE r.status='pending'
   AND r.official_title IN (
     '彼岸花','MADSPEED狂信道','MADSPEED狂信道(UPPER)',
     'Last Twilight','バンブーソード・ガール',
     '@n H@ppy Choice','＠n　H＠ppy　Choice'
   )
 GROUP BY r.fingerprint
 HAVING count(DISTINCT s.id)=1
), closed AS (
 UPDATE public.sync_song_correction_requests r
 SET status='approved',target_song_id=m.song_id,reviewed_at=now()
 FROM uniquely_matched m
 WHERE r.fingerprint=m.fingerprint AND r.status='pending'
 RETURNING r.official_genre,r.official_title,r.official_artist,r.status,r.target_song_id
)
SELECT * FROM closed ORDER BY official_title;
COMMIT;

-- Check remaining pending items separately (zero rows means all targeted requests resolved):
SELECT r.official_genre,r.official_title,r.official_artist,r.status
FROM public.sync_song_correction_requests r
WHERE r.status='pending'
  AND r.official_title IN (
    '彼岸花','MADSPEED狂信道','MADSPEED狂信道(UPPER)',
    'Last Twilight','バンブーソード・ガール',
    '@n H@ppy Choice','＠n　H＠ppy　Choice'
  )
ORDER BY r.official_title;
