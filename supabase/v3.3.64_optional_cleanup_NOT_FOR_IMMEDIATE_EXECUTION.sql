-- v3.3.64 cleanup, MANUAL and OPTIONAL. Do not execute before production functional validation.
-- Before running: verify export/backup restoration path. Pro plan is recommended until completion.
-- 1) Preview exact eligible rows, excluding manual medals and unexpected values:
SELECT COUNT(*) AS eligible
FROM public.user_version_scores
WHERE version_score=0
  AND current_clear_status='unplayed'
  AND current_medal_code='none'
  AND current_medal_manual=false;

-- 2) Execute only the statement between BEGIN/COMMIT below to remove UP TO 2000 rows.
--    Repeat in SQL Editor only after checking each run's result and site's behavior.
--    This is deliberately commented out to prevent accidental execution.
/*
BEGIN;
WITH batch AS (
  SELECT ctid FROM public.user_version_scores
  WHERE version_score=0
    AND current_clear_status='unplayed'
    AND current_medal_code='none'
    AND current_medal_manual=false
  LIMIT 2000
  FOR UPDATE SKIP LOCKED
), deleted AS (
  DELETE FROM public.user_version_scores us
  USING batch
  WHERE us.ctid = batch.ctid
  RETURNING us.user_id
)
SELECT COUNT(*) AS deleted_rows FROM deleted;
COMMIT;
*/
-- 3) Confirm application UI, PSR and sync after each small batch.
-- 4) Normal DELETE does not shrink pg_database_size; only investigate VACUUM FULL
--    after a successful backup, when production can be paused. It requires an
--    exclusive lock and temporary free disk space. Do not execute it blindly.
