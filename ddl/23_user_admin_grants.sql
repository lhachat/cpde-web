-- =====================================================================
-- 23_user_admin_grants.sql -- grant back the narrow app_user writes the
-- admin user-management feature actually needs.
--
-- Goes in ddl/.
--
-- 21_least_privilege.sql revoked INSERT/UPDATE/DELETE on app_user after
-- confirming no endpoint wrote it, and said explicitly: "If a future
-- endpoint genuinely needs to write one of these, grant it back
-- explicitly at that point -- don't just widen this file's scope."
-- This is that point: routers/users.py (admin-only) creates users and
-- edits their display name / active flag.
--
-- INSERT and UPDATE only -- deliberately NOT DELETE. A user is
-- deactivated (is_active = false), never hard-deleted: audit_log,
-- pursuit.owner_user_id/created_by/updated_by and
-- pwin_assessment.calculated_by all reference app_user.id, and
-- fn_lookup_login already refuses an inactive user, so deactivation is
-- both the safe and the sufficient mechanism. Keeping DELETE revoked
-- means a coding mistake in that router cannot destroy the historical
-- record even if it tried.
--
-- user_scope_assignment already carries full DML from 05_security.sql
-- (it was never in 21's revoke list -- confirmed live before writing
-- this file, not assumed), so no grant is needed for it here.
-- =====================================================================

BEGIN;

GRANT INSERT, UPDATE ON app_user TO cpde_app;

COMMIT;
