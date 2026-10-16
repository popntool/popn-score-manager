# Popn Score Manager v3.3.64 – sparse version scores (staged)

**Do not run the cleanup SQL yet.** This ZIP includes changed files only, preserving their original hierarchy.

## Scope
- Sync v31: avoid writing version records when the official status is `unplayed` and version score is 0.
- Sync v320: on an untouched/unplayed/zero record, remove only an existing empty, non-manual version record; preserve history (`user_scores`) and manual medals.
- Song approval: avoid materializing empty version score records from pending requests.
- No changes to PSR calculation, scores display, login or registration screens.
- Manual save functions remain unchanged. An explicitly saved manual medal, including `none`, is retained because it is a user action.
- SQL was generated from exported function definitions, NOT tested against a real Supabase database. SQL must be run BEFORE publishing frontend version files.

## Apply
1. Ensure a restorable backup exists. Keep Pro plan during migration.
2. Execute `supabase/v3.3.64_sparse_version_scores.sql` in Supabase SQL Editor; stop immediately if it errors.
3. Publish the changed version files to GitHub only after SQL succeeds.
4. Test normal score sync, unmatched-song approval, manual medal editing, NO PLAY display, High☆Cheers!! and Jam&Fizz summaries, rivals, and verify the version table never grows by thousands of empty rows during sync.
5. Only once tests pass: consider `supabase/v3.3.64_optional_cleanup_NOT_FOR_IMMEDIATE_EXECUTION.sql` (DELETE is commented out; requires deliberate manual activation).
6. Do not downgrade to Free before physical size is measured to be comfortably under 500 MB and monthly Egress is under Free quota.

## Limitations
- This does NOT perform database cleanup or compact table files, and no 350MB reduction is guaranteed.
- Frontend never changed because the current `js/scores.js` already treats absent version rows as NO PLAY; verify in browser.
- The sync v31 function can be called directly by older code and now skips empty current-version records. Any caller that expects an explicit empty row should be checked.
- PostgreSQL `DELETE` triggers still fire and must be watched during batches.
