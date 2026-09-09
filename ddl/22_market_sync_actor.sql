-- =====================================================================
-- 22_market_sync_actor.sql -- a real, resolvable actor identity for the
-- market sync background job.
--
-- Goes in ddl/.
--
-- market_sync.py writes market/market_sync_run rows via tenant_tx()
-- with no user_id, so trg_audit's audit_log rows for those writes carry
-- a NULL actor -- indistinguishable, in the audit view, from "nobody
-- recorded who did this" rather than "an automated job did this".
--
-- One reserved app_user row per client, is_active = FALSE so
-- fn_lookup_login() (which requires u.is_active) can never
-- authenticate as it -- it exists purely to be resolved by id and
-- LEFT JOINed for display (routers/write.py's own audit-history and
-- audit-log queries), the same way every real user's row already is.
--
-- Manual per-client bootstrap, same as this project's other per-client
-- rows (no client-onboarding trigger exists yet) -- give a newly
-- onboarded client this same row (client_id, this same reserved email)
-- when it's created.
-- =====================================================================

BEGIN;

INSERT INTO app_user (client_id, email, display_name, is_active)
SELECT id, 'service.market-sync@cpde.internal', 'Market Sync (automated)', false
  FROM client
    ON CONFLICT (client_id, email) DO NOTHING;

COMMIT;
