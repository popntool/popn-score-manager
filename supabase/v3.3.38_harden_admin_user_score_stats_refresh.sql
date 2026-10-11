-- v3.3.38
-- Harden admin_user_score_stats refresh used by score-sync triggers.
-- Replaces the v3.3.33/v3.3.37 definition.
--
-- Changes:
-- 1) DISTINCT and ORDER BY are separated into a subquery (avoids PostgreSQL aggregate rule errors).
-- 2) unnest() columns are explicitly named (avoids whole-row/alias ambiguity).
-- 3) affected users are advisory-locked in deterministic UUID order.
-- 4) cache writes use UPSERT, so concurrent refreshes cannot raise the user_id primary-key error.
-- 5) a harmless post-install refresh is executed for one existing user, when available, so
--    SQL inside the PL/pgSQL function is actually exercised during migration.

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
  SELECT array_agg(d.user_id ORDER BY d.user_id)
    INTO v_ids
  FROM (
    SELECT DISTINCT x.user_id
    FROM unnest(coalesce(p_user_ids, ARRAY[]::uuid[])) AS x(user_id)
    WHERE x.user_id IS NOT NULL
  ) AS d;

  IF v_ids IS NULL OR cardinality(v_ids)=0 THEN
    RETURN;
  END IF;

  -- All concurrent refreshes for the same user take the same transaction lock.
  -- The UUID sort order keeps multi-user refreshes deterministic.
  PERFORM pg_advisory_xact_lock(hashtextextended(x.user_id::text, 333::bigint))
  FROM unnest(v_ids) AS x(user_id)
  ORDER BY x.user_id;

  INSERT INTO public.admin_user_score_stats(
    user_id, registered_count, score_sum, last_updated_at
  )
  SELECT
    us.user_id,
    count(*)::bigint,
    coalesce(sum(us.score),0)::bigint,
    max(us.updated_at)::timestamptz
  FROM public.user_scores AS us
  WHERE us.user_id = ANY(v_ids)
  GROUP BY us.user_id
  ON CONFLICT (user_id) DO UPDATE SET
    registered_count = EXCLUDED.registered_count,
    score_sum = EXCLUDED.score_sum,
    last_updated_at = EXCLUDED.last_updated_at;

  DELETE FROM public.admin_user_score_stats AS s
  WHERE s.user_id = ANY(v_ids)
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_scores AS us
      WHERE us.user_id = s.user_id
    );
END;
$$;

-- Exercise the function during migration if score data exists.
-- This is only a recalculation of an already-derived cache row.
DO $$
DECLARE
  v_test_user uuid;
BEGIN
  SELECT us.user_id
    INTO v_test_user
  FROM public.user_scores AS us
  WHERE us.user_id IS NOT NULL
  ORDER BY us.user_id
  LIMIT 1;

  IF v_test_user IS NOT NULL THEN
    PERFORM public.refresh_admin_user_score_stats_for_users(ARRAY[v_test_user]);
  END IF;
END;
$$;

COMMIT;
