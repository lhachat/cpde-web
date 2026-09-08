-- =====================================================================
-- 19_dashboard_layout.sql -- per-user dashboard card order.
--
-- Goes in ddl/.
--
-- One row per user (user_id is the PRIMARY KEY, not a separate surrogate)
-- -- "a per-user preference row", same language the Configure Dashboard
-- panel already used to describe this before it was built (see the note
-- in vDash()/cfgPanel() in api/static/index.html). A tenant-wide default
-- layout is deliberately NOT a thing here: show/hide and chart-type
-- (DASH_CFG) are already per-user, client-side settings, and card order
-- is the same kind of personal preference, not a product setting.
--
-- Absent row means "use the current default order" -- there is no
-- separate default-order table; the default lives in the frontend's own
-- DASH_CFG key order, so a new user (or a user whose stored order
-- predates a newly-added card) always gets something sensible.
--
-- card_order is opaque to the database: a JSON array of the frontend's
-- own DASH_CFG keys. The server does not validate membership against a
-- fixed card list (see the API's own comment) so a card added to
-- DASH_CFG later needs no matching migration here.
-- =====================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS user_dashboard_layout (
    user_id     UUID NOT NULL PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
    client_id   UUID NOT NULL,
    card_order  JSONB NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- client_id derived, never supplied -- same discipline as everywhere else.
DROP TRIGGER IF EXISTS trg_cid ON user_dashboard_layout;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON user_dashboard_layout
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_user();

ALTER TABLE user_dashboard_layout ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_dashboard_layout FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON user_dashboard_layout;
CREATE POLICY tenant_isolation ON user_dashboard_layout
    USING (client_id = current_tenant())
    WITH CHECK (client_id = current_tenant());

GRANT SELECT, INSERT, UPDATE, DELETE ON user_dashboard_layout TO cpde_app;

DROP TRIGGER IF EXISTS trg_audit ON user_dashboard_layout;
CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON user_dashboard_layout
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE user_dashboard_layout IS
    'One row per user: their own dashboard card order (a JSON array of '
    'DASH_CFG keys). Per-user, not tenant-wide -- reordering is a '
    'personal UI preference, same category as which cards are shown or '
    'hidden. No row yet means "use the current default order".';

COMMIT;
