-- =====================================================================
-- 20_dashboard_card_settings.sql -- per-user dashboard card show/hide
-- and chart-type settings (DASH_CFG's `on`/`type`).
--
-- Goes in ddl/.
--
-- Same table as card order (19_dashboard_layout.sql), not a second
-- persistence mechanism: one user preference row, now two facets of it.
-- card_order is a JSON array (a sequence); this is naturally a JSON
-- OBJECT keyed by card id (a per-card lookup), so a sibling column
-- fits better than folding both shapes into one blob.
--
-- Same "opaque to the database" philosophy as card_order: the server
-- does not validate keys against a fixed card list, so a card added to
-- (or removed from) DASH_CFG later needs no matching migration here.
-- Absent row, or a settings blob missing a card DASH_CFG has added
-- since, both mean "use that card's current default" -- see the merge
-- in the frontend's own rebuildDerived().
-- =====================================================================

BEGIN;

ALTER TABLE user_dashboard_layout
    ADD COLUMN IF NOT EXISTS card_settings JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN user_dashboard_layout.card_settings IS
    'Per-card show/hide and chart-type settings (DASH_CFG''s on/type), '
    'keyed by the same opaque card id card_order uses. Missing a key '
    'means "use that card''s current default", same as an absent row '
    'entirely.';

COMMIT;
