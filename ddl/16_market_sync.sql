-- =====================================================================
-- 16_market_sync.sql -- market.flagged_for_review + market_sync_run
--
-- Goes in ddl/.
--
-- WHY: `market` was populated once at load time and never updated
-- after -- if a client's markets change on the engine side, cpde-web
-- silently drifts out of sync with no error and no signal. A scheduled
-- job (api/app/market_sync.py) now reconciles against the engine's own
-- GET /v1/markets per client.
--
-- MATCHING IS BY NAME ONLY. GET /v1/markets (cda_engine's own
-- runtime/api.py) returns bare display-name strings, no code or id of
-- any kind -- the engine's own MarketEntry model has only name and
-- differential. There is therefore no stable key to detect a rename;
-- one is structurally indistinguishable from "old market gone, new one
-- appeared." Confirmed by reading the engine's code directly, not
-- assumed. So: a name present in the engine's response but not locally
-- is CREATED as new; a local market whose name the engine no longer
-- reports is FLAGGED, never deleted or renamed in place.
--
-- flagged_for_review is deliberately SEPARATE from is_active (same
-- precedent as org_node.is_test_fixture in 15_test_fixture_flag.sql):
-- is_active controls whether a market is offered as a NEW choice in a
-- picker (portfolio.py's /markets, /reference); flagged_for_review is
-- a pure signal that the engine no longer reports this market, for a
-- person to act on. A flagged market's own is_active is never touched
-- by the sync job, and every pursuit that already references it keeps
-- working unmodified -- bootstrap.py/portfolio.py only ever LEFT JOIN
-- market, with no is_active or flagged_for_review predicate on the
-- pursuit-reading queries themselves.
--
-- market_sync_run is a run-log, not audited via fn_audit -- same
-- reasoning as client_escalation_rate (14_staffing_escalation.sql):
-- it IS the record of what happened, a generic changed-row diff on top
-- of it would be noise, not signal.
--
-- fn_list_active_clients() is a narrowly-scoped SECURITY DEFINER
-- function, same idiom as fn_lookup_login() (08_auth.sql) -- the sync
-- job runs before any tenant context exists (it must enumerate EVERY
-- client to sync each one in turn), so it needs the same kind of
-- explicit, minimal cross-tenant read login already relies on. It
-- returns only the columns a per-client engine call actually needs --
-- never pursuit or business data.
-- =====================================================================

BEGIN;

ALTER TABLE market
    ADD COLUMN flagged_for_review BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN flagged_at TIMESTAMPTZ,
    ADD COLUMN flagged_reason TEXT;

CREATE TABLE market_sync_run (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID NOT NULL REFERENCES client(id) ON DELETE CASCADE,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at     TIMESTAMPTZ,
    status          TEXT NOT NULL DEFAULT 'running'
                        CHECK (status IN ('running', 'succeeded', 'failed')),
    error_message   TEXT,
    created_names   TEXT[] NOT NULL DEFAULT '{}',
    flagged_names   TEXT[] NOT NULL DEFAULT '{}',
    unflagged_names TEXT[] NOT NULL DEFAULT '{}'
);

ALTER TABLE market_sync_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE market_sync_run FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON market_sync_run;
CREATE POLICY tenant_isolation ON market_sync_run
    USING (client_id = current_tenant())
    WITH CHECK (client_id = current_tenant());

GRANT SELECT, INSERT ON market_sync_run TO cpde_app;

CREATE OR REPLACE FUNCTION fn_list_active_clients()
 RETURNS TABLE(id UUID, code TEXT, name TEXT, engine_client_code TEXT,
              engine_base_url TEXT, engine_secret_ref TEXT)
 LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT c.id, c.code, c.name, c.engine_client_code,
           c.engine_base_url, c.engine_secret_ref
      FROM client c
     WHERE c.is_active
     ORDER BY c.code;
$$;

GRANT EXECUTE ON FUNCTION fn_list_active_clients() TO cpde_app;

COMMIT;

-- =====================================================================
-- VERIFY
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'market' AND column_name LIKE 'flagged%';
--   -- expect flagged_for_review, flagged_at, flagged_reason
--   SELECT * FROM fn_list_active_clients();
--   -- expect one row per active client (DEMO, AERO today)
-- =====================================================================
