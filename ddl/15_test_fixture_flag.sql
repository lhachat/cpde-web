-- =====================================================================
-- 15_test_fixture_flag.sql -- org_node.is_test_fixture
--
-- Goes in ddl/.
--
-- WHY: the scope test suite (test_scope.py, test_api_security.py) needs
-- at least one org node that is GENUINELY empty -- no pursuits, no
-- plan_year rows, ever -- to prove "narrow scope excludes" against
-- something that can't accidentally grow real content the way BU2 and
-- DIV1 did once AERO's org structure gained real data. BUZ ("Zero-
-- Pursuit Test BU") is that fixture. It is a real, active, fully
-- functional org node -- a user actually scoped to it resolves through
-- fn_user_visible_org_nodes/fn_user_pursuits exactly like any other
-- node -- but it has no business meaning, and showing it as a choice
-- in a real admin's picker ("Zero-Pursuit Test BU") is confusing
-- clutter, not a feature.
--
-- is_test_fixture is therefore a DISPLAY-ONLY flag:
--   - User-facing PICKERS (Targets & Budgets' BU picker, the Dashboard
--     rollup selector, the pursuit form's org-unit picker) exclude any
--     node flagged here from their option lists.
--   - Scope resolution itself (fn_user_visible_org_nodes,
--     fn_user_pursuits, RLS) does NOT look at this column at all -- it
--     stays exactly as before. A user scoped to a test-fixture node
--     must keep resolving correctly, or the tests this node exists to
--     support would silently break.
--   - is_active is a separate, pre-existing concern (deactivating a
--     node cuts its whole subtree from scope entirely). A test-fixture
--     node stays fully active; it's simply never offered as a choice.
-- =====================================================================

BEGIN;

ALTER TABLE org_node
    ADD COLUMN is_test_fixture BOOLEAN NOT NULL DEFAULT FALSE;

-- Audited directly (2026-09-01): BUZ is the only purely-synthetic org
-- node in the seed data. Every other node -- including BU and the
-- BUSINESS root, both of which hold zero pursuits DIRECTLY -- is real
-- structure (BU's pursuits live in its divisions; BUSINESS is the
-- tenant root), not a test artifact.
UPDATE org_node SET is_test_fixture = TRUE WHERE code = 'BUZ';

COMMIT;

-- =====================================================================
-- VERIFY
--   SELECT code, is_test_fixture FROM org_node WHERE is_test_fixture;
--   -- expect exactly one row: BUZ
-- =====================================================================
