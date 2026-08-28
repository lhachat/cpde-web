-- =====================================================================
-- 10_presence.sql -- Advisory presence. NOT a lock.
--
-- Goes in ddl/.
--
-- WHY NOT A LOCK: there is no reliable signal that someone left. A tab
-- closes, a laptop sleeps, someone opens a pursuit and goes to lunch. A
-- real lock outlives the person and locks a capture manager out of their
-- own pursuit at 4:55pm before a proposal is due. Presence tells you
-- someone else is there; optimistic concurrency on the write is what
-- actually prevents data loss.
--
-- Rows are transient. Anything older than PRESENCE_TTL is ignored on read
-- and swept on write, so a stale row is harmless rather than obstructive.
-- =====================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS pursuit_presence (
    pursuit_id  UUID NOT NULL REFERENCES pursuit(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    client_id   UUID NOT NULL,
    opened_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (pursuit_id, user_id)
);

CREATE INDEX IF NOT EXISTS ix_presence_seen ON pursuit_presence(last_seen);

-- client_id derived, never supplied -- same discipline as everywhere else.
DROP TRIGGER IF EXISTS trg_cid ON pursuit_presence;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON pursuit_presence
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_pursuit();

ALTER TABLE pursuit_presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE pursuit_presence FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON pursuit_presence;
CREATE POLICY tenant_isolation ON pursuit_presence
    USING (client_id = current_tenant())
    WITH CHECK (client_id = current_tenant());

GRANT SELECT, INSERT, UPDATE, DELETE ON pursuit_presence TO cpde_app;

-- Deliberately NOT audited. Presence is ephemeral noise; auditing every
-- heartbeat would bury the changes that matter.

COMMENT ON TABLE pursuit_presence IS
    'Advisory only. Who currently has a pursuit open, so a second person '
    'sees "Frantz opened this 2 minutes ago" before they start editing. '
    'It prevents collisions socially. It does not and must not block a '
    'write -- optimistic concurrency on updated_at does that.';

COMMIT;
