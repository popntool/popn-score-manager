-- v3.3.33
-- Fix duplicate-key failures on admin_user_score_stats during score synchronization.
-- Run once in Supabase SQL Editor before/with the site deployment.

BEGIN;

CREATE OR REPLACE FUNCTION public.refresh_admin_user_score_stats_for_users(p_user_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  v_ids uuid[];
BEGIN
  SELECT array_agg(DISTINCT u ORDER BY u::text)
    INTO v_ids
  FROM unnest(coalesce(p_user_ids, ARRAY[]::uuid[])) AS u
  WHERE u IS NOT NULL;

  IF v_ids IS NULL OR cardinality(v_ids)=0 THEN
    RETURN;
  END IF;

  -- Multiple sync RPC batches for the same user can finish at the same time.
  -- Lock each affected user deterministically so cache refreshes cannot race.
  PERFORM pg_advisory_xact_lock(hashtextextended(u::text, 333))
  FROM unnest(v_ids) AS u
  ORDER BY u::text;

  -- Recalculate users that still have score rows. ON CONFLICT makes the cache
  -- refresh idempotent even if a trigger fires for both INSERT and UPDATE.
  INSERT INTO public.admin_user_score_stats(
    user_id, registered_count, score_sum, last_updated_at
  )
  SELECT
    us.user_id,
    count(*)::bigint,
    coalesce(sum(us.score),0)::bigint,
    max(us.updated_at)::timestamptz
  FROM public.user_scores us
  WHERE us.user_id = ANY(v_ids)
  GROUP BY us.user_id
  ON CONFLICT(user_id) DO UPDATE SET
    registered_count = excluded.registered_count,
    score_sum = excluded.score_sum,
    last_updated_at = excluded.last_updated_at;

  -- If a user's last score was deleted, remove the stale cache row.
  DELETE FROM public.admin_user_score_stats s
  WHERE s.user_id = ANY(v_ids)
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_scores us
      WHERE us.user_id = s.user_id
    );
END;
$$;

COMMIT;
