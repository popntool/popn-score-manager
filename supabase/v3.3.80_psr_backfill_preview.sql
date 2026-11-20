-- v3.3.80 PREVIEW ONLY. Read-only. Run this before the apply script.
-- One-time migration follows the v3.3.79 JS rules; no public visibility settings are changed.
-- Ranking ties are resolved by a stable order; tied chart PSRs are identical.
WITH target_version AS (
  SELECT id, slug, is_current
  FROM public.game_versions
  WHERE is_current = true
  ORDER BY sort_order DESC, id
  LIMIT 1
), user_base AS (
  SELECT p.id AS user_id, p.username, p.psr_public, g.id AS game_version_id,
         g.slug AS version_slug, g.is_current AS version_is_live
  FROM public.profiles p CROSS JOIN target_version g
), score_raw AS (
  SELECT ub.user_id, ub.game_version_id, s.id AS song_id,
    s.title, us.chart::text AS chart,
    coalesce(s.version_id = ub.game_version_id, false) AS version_is_current,
    CASE us.chart::text
      WHEN 'LIGHT' THEN s.light_level
      WHEN 'NORMAL' THEN s.normal_level
      WHEN 'HYPER' THEN s.hyper_level
      WHEN 'EX' THEN s.ex_level
    END::numeric AS level,
    lower(coalesce(us.medal_code::text,'none')) AS historical_medal,
    CASE WHEN ub.version_slug = 'master_cdbb557d24080162a681ae5c'
      THEN coalesce(us.version_score,0)
      ELSE coalesce(uvs.version_score,0) END::numeric AS version_score,
    lower(coalesce(CASE WHEN ub.version_slug = 'master_cdbb557d24080162a681ae5c'
      THEN us.current_clear_status::text ELSE uvs.current_clear_status::text END,'failed')) AS base_status
  FROM user_base ub
  JOIN public.user_scores us ON us.user_id=ub.user_id
  JOIN public.songs s ON s.id=us.song_id
  LEFT JOIN public.user_version_scores uvs ON uvs.user_id=us.user_id
    AND uvs.song_id=us.song_id AND uvs.chart=us.chart
    AND uvs.game_version_id=ub.game_version_id
  -- Mirrors loadMyScores' database row filter, before selecting positive current scores.
  WHERE coalesce(us.score,0)>0 OR coalesce(us.version_score,0)>0
     OR (us.medal_code IS NOT NULL AND us.medal_code::text<>'none')
     OR (us.current_medal_code IS NOT NULL AND us.current_medal_code::text<>'none')
     OR (us.current_clear_status IS NOT NULL AND us.current_clear_status::text<>'unplayed')
), normalized AS (
  SELECT *, CASE
    -- Mirrors currentMedalForNewSong: only currently released songs in active current-version selection.
    WHEN version_is_current AND historical_medal IN ('perfect','a') THEN 'perfect'
    WHEN version_is_current AND historical_medal IN
       ('fc_1_5','fc_6_20','fc_21_plus','b','c','d') THEN 'full_combo'
    WHEN version_is_current AND historical_medal IN
       ('clear_bad_1_5','clear_bad_6_20','clear_bad_21_plus','e','f','g') THEN 'clear'
    WHEN version_is_current AND historical_medal IN ('easy','k') THEN 'easy'
    WHEN version_is_current AND historical_medal='long_off' THEN 'long_off'
    WHEN version_is_current AND historical_medal IN
       ('failed_15_16','failed_12_14','failed_0_11','h','i','j','l','m','n') THEN 'failed'
    ELSE base_status END AS effective_status
  FROM score_raw
), scores AS (
  SELECT *,
    -- JS songPopClass: floor(((level² * clamp(score,0,100000)/6000 + bonus)/200)*100)/100
    floor((
      (greatest(0,coalesce(level,0))*greatest(0,coalesce(level,0))
        *least(100000,greatest(0,version_score))/6000
       + CASE effective_status
          WHEN 'perfect' THEN 3000 WHEN 'full_combo' THEN 2000
          WHEN 'clear' THEN 1000 WHEN 'long_off' THEN 300
          WHEN 'easy' THEN 200 ELSE 0 END
      ) / 200
    )*100)::bigint AS chart_psr_cents
  FROM normalized
  -- Mirrors popClassSelection: only played and non-unplayed scores.
  WHERE version_score>0 AND effective_status<>'unplayed'
), ranked AS (
  SELECT *,row_number() OVER (
    PARTITION BY user_id,version_is_current
    ORDER BY chart_psr_cents DESC,version_score DESC,title COLLATE "C",song_id,chart
  ) AS position_in_group
  FROM scores
), selected AS (
  SELECT * FROM ranked
  WHERE (version_is_current AND position_in_group<=20)
     OR (NOT version_is_current AND position_in_group<=40)
), totals AS (
  SELECT user_id,game_version_id,
         -- JS: total = floor(sum(each_chart_psr_in_cents)/60)/100.
         (floor(sum(chart_psr_cents)::numeric/60)/100)::numeric AS calculated_psr,
         count(*) FILTER(WHERE version_is_current)::int AS new_count,
         count(*) FILTER(WHERE NOT version_is_current)::int AS old_count,
         (sum(chart_psr_cents) FILTER(WHERE version_is_current)::numeric/100) AS new_sum,
         (sum(chart_psr_cents) FILTER(WHERE NOT version_is_current)::numeric/100) AS old_sum
  FROM selected GROUP BY user_id,game_version_id
), clear_stats AS (
  SELECT us.user_id,
    max(CASE us.chart::text WHEN 'LIGHT' THEN s.light_level
      WHEN 'NORMAL' THEN s.normal_level WHEN 'HYPER' THEN s.hyper_level
      WHEN 'EX' THEN s.ex_level END)::smallint AS highest_clear_level,
    max(us.updated_at) AS last_clear_updated_at
  FROM public.user_scores us JOIN public.songs s ON s.id=us.song_id
  WHERE lower(coalesce(us.medal_code::text,'none')) IN
    ('perfect','a','fc_1_5','b','fc_6_20','c','fc_21_plus','d',
     'clear_bad_1_5','e','clear_bad_6_20','f','clear_bad_21_plus','g')
  GROUP BY us.user_id
), payload AS (
  SELECT ub.user_id,ub.username,ub.psr_public,ub.game_version_id,
    coalesce(t.calculated_psr,0)::numeric AS calculated_psr,
    coalesce(t.new_count,0) AS new_count, coalesce(t.old_count,0) AS old_count,
    coalesce(t.new_sum,0)::numeric AS new_sum,
    coalesce(t.old_sum,0)::numeric AS old_sum,
    cs.highest_clear_level,cs.last_clear_updated_at
  FROM user_base ub
  LEFT JOIN totals t ON t.user_id=ub.user_id AND t.game_version_id=ub.game_version_id
  LEFT JOIN clear_stats cs ON cs.user_id=ub.user_id
)
SELECT p.username,p.psr_public,p.new_count,p.old_count,
       p.new_sum,p.old_sum,p.calculated_psr,
       c.pop_class AS previous_psr,
       c.calculation_revision AS previous_revision
FROM payload p LEFT JOIN public.user_summary_cache c
 ON c.user_id=p.user_id AND c.game_version_id=p.game_version_id
ORDER BY p.username;
