-- v3.3.37
-- Fix PostgreSQL error:
--   in an aggregate with DISTINCT, ORDER BY expressions must appear in argument list
-- This replaces the v3.3.33 refresh function definition.

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
  -- ORDER BY must use the same DISTINCT expression in PostgreSQL.
  SELECT array_agg(DISTINCT u ORDER BY u)
    INTO v_ids
  FROM unnest(coalesce(p_user_ids, ARRAY[]::uuid[])) AS u
  WHERE u IS NOT NULL;

  IF v_ids IS NULL OR cardinality(v_ids)=0 THEN
    RETURN;
  END IF;

  -- Serialize refreshes for the same users so parallel sync batches do not race.
  PERFORM pg_advisory_xact_lock(hashtextextended(u::text, 333))
  FROM unnest(v_ids) AS u
  ORDER BY u;

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
