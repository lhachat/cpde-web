-- =====================================================================
-- 21_least_privilege.sql -- narrow cpde_app's blanket DML grant.
--
-- Goes in ddl/.
--
-- 05_security.sql grants SELECT/INSERT/UPDATE/DELETE on every table
-- (present and future, via ALTER DEFAULT PRIVILEGES) to cpde_app --
-- deliberately, so a new table needs no separate grant statement to
-- work with the application. That default is right for tables the app
-- actually writes; it is too broad for global reference tables (no
-- RLS at all) and for client/app_user, which the application only
-- ever READS directly (client/user provisioning, same as every other
-- reference table here, happens outside the running app).
--
-- Confirmed via a full grep of api/app for INSERT INTO/UPDATE/DELETE
-- FROM against each of these table names before writing this file --
-- zero real endpoints write any of them. If a future endpoint
-- genuinely needs to write one of these, grant it back explicitly at
-- that point -- don't just widen this file's scope.
-- =====================================================================

BEGIN;

REVOKE INSERT, UPDATE, DELETE ON
    contract_type,
    labor_category,
    opportunity_type,
    phase,
    pipeline_stage,
    question,
    question_dependency,
    question_option,
    question_prompt_variant,
    questionnaire_version,
    role,
    client,
    app_user
FROM cpde_app;

COMMIT;
