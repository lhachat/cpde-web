-- =====================================================================
-- 05_security.sql -- Multi-tenant isolation via PostgreSQL RLS
--
-- STATUS: UNRUN. Written without a PostgreSQL instance available to test
--         against. Expect to iterate. Run against a throwaway database
--         first (docker compose down -v && up), never against anything
--         you care about.
--
-- Run order: after 01-04. Demo data loads AFTER this file.
--
-- THREE THINGS THIS FILE EXISTS TO GUARANTEE
--   1. FORCE ROW LEVEL SECURITY, and the app does not own the tables.
--      A table owner bypasses RLS by default -- the single most common
--      reason an RLS deployment turns out to be decorative.
--   2. Tenant context is set per TRANSACTION. Under a connection pooler,
--      setting it per connection leaks the previous request's tenant to
--      the next request on that connection.
--   3. Policies exist on EVERY tenant-scoped table. A missed table is a
--      silent cross-tenant read. See the coverage assertion at the end.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Denormalize client_id onto child tables
--
-- WHY: pursuit_staffing, pwin_answer and friends reach their tenant only
-- through a join. An RLS policy using EXISTS(...) works but is slow and,
-- worse, easy to write subtly wrong. A direct client_id column makes each
-- policy a single comparison and makes the coverage check below trivial.
-- The redundancy is protected by triggers in section 2.
-- ---------------------------------------------------------------------

ALTER TABLE pursuit_year_projection ADD COLUMN IF NOT EXISTS client_id UUID;
ALTER TABLE pursuit_staffing        ADD COLUMN IF NOT EXISTS client_id UUID;
ALTER TABLE pursuit_phase_duration  ADD COLUMN IF NOT EXISTS client_id UUID;
ALTER TABLE pursuit_staffing_meta   ADD COLUMN IF NOT EXISTS client_id UUID;
ALTER TABLE pwin_assessment         ADD COLUMN IF NOT EXISTS client_id UUID;
ALTER TABLE pwin_answer             ADD COLUMN IF NOT EXISTS client_id UUID;
ALTER TABLE user_scope_assignment   ADD COLUMN IF NOT EXISTS client_id UUID;

-- Backfill from the parent before making them NOT NULL.
UPDATE pursuit_year_projection c SET client_id = p.client_id
  FROM pursuit p WHERE p.id = c.pursuit_id AND c.client_id IS NULL;
UPDATE pursuit_staffing c SET client_id = p.client_id
  FROM pursuit p WHERE p.id = c.pursuit_id AND c.client_id IS NULL;
UPDATE pursuit_phase_duration c SET client_id = p.client_id
  FROM pursuit p WHERE p.id = c.pursuit_id AND c.client_id IS NULL;
UPDATE pursuit_staffing_meta c SET client_id = p.client_id
  FROM pursuit p WHERE p.id = c.pursuit_id AND c.client_id IS NULL;
UPDATE pwin_assessment c SET client_id = p.client_id
  FROM pursuit p WHERE p.id = c.pursuit_id AND c.client_id IS NULL;
UPDATE pwin_answer c SET client_id = a.client_id
  FROM pwin_assessment a WHERE a.id = c.pwin_assessment_id AND c.client_id IS NULL;
UPDATE user_scope_assignment c SET client_id = u.client_id
  FROM app_user u WHERE u.id = c.user_id AND c.client_id IS NULL;

-- plan_year reaches its tenant through org_node.
ALTER TABLE plan_year ADD COLUMN IF NOT EXISTS client_id UUID;
UPDATE plan_year c SET client_id = o.client_id
  FROM org_node o WHERE o.id = c.org_node_id AND c.client_id IS NULL;


-- ---------------------------------------------------------------------
-- 2. Keep the denormalized column honest
--
-- A denormalized key that can drift is worse than no key at all, because
-- the policy would silently read the wrong tenant. These triggers derive
-- it on write; the application never sets it.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_inherit_client_from_pursuit() RETURNS TRIGGER AS $$
BEGIN
    SELECT client_id INTO NEW.client_id FROM pursuit WHERE id = NEW.pursuit_id;
    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'cannot resolve client_id from pursuit %', NEW.pursuit_id;
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_inherit_client_from_assessment() RETURNS TRIGGER AS $$
BEGIN
    SELECT client_id INTO NEW.client_id FROM pwin_assessment WHERE id = NEW.pwin_assessment_id;
    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'cannot resolve client_id from assessment %', NEW.pwin_assessment_id;
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_inherit_client_from_org() RETURNS TRIGGER AS $$
BEGIN
    SELECT client_id INTO NEW.client_id FROM org_node WHERE id = NEW.org_node_id;
    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'cannot resolve client_id from org_node %', NEW.org_node_id;
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_inherit_client_from_user() RETURNS TRIGGER AS $$
BEGIN
    SELECT client_id INTO NEW.client_id FROM app_user WHERE id = NEW.user_id;
    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'cannot resolve client_id from app_user %', NEW.user_id;
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_cid ON pursuit_year_projection;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON pursuit_year_projection
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_pursuit();
DROP TRIGGER IF EXISTS trg_cid ON pursuit_staffing;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON pursuit_staffing
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_pursuit();
DROP TRIGGER IF EXISTS trg_cid ON pursuit_phase_duration;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON pursuit_phase_duration
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_pursuit();
DROP TRIGGER IF EXISTS trg_cid ON pursuit_staffing_meta;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON pursuit_staffing_meta
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_pursuit();
DROP TRIGGER IF EXISTS trg_cid ON pwin_assessment;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON pwin_assessment
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_pursuit();
DROP TRIGGER IF EXISTS trg_cid ON pwin_answer;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON pwin_answer
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_assessment();
DROP TRIGGER IF EXISTS trg_cid ON plan_year;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON plan_year
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_org();
DROP TRIGGER IF EXISTS trg_cid ON user_scope_assignment;
CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON user_scope_assignment
    FOR EACH ROW EXECUTE FUNCTION fn_inherit_client_from_user();

ALTER TABLE pursuit_year_projection ALTER COLUMN client_id SET NOT NULL;
ALTER TABLE pursuit_staffing        ALTER COLUMN client_id SET NOT NULL;
ALTER TABLE pursuit_phase_duration  ALTER COLUMN client_id SET NOT NULL;
ALTER TABLE pwin_assessment         ALTER COLUMN client_id SET NOT NULL;
ALTER TABLE pwin_answer             ALTER COLUMN client_id SET NOT NULL;
ALTER TABLE plan_year               ALTER COLUMN client_id SET NOT NULL;
ALTER TABLE user_scope_assignment   ALTER COLUMN client_id SET NOT NULL;
-- pursuit_staffing_meta left nullable: it may legitimately have no rows yet.

CREATE INDEX IF NOT EXISTS ix_pyp_cid   ON pursuit_year_projection(client_id);
CREATE INDEX IF NOT EXISTS ix_stf_cid   ON pursuit_staffing(client_id);
CREATE INDEX IF NOT EXISTS ix_ppd_cid   ON pursuit_phase_duration(client_id);
CREATE INDEX IF NOT EXISTS ix_pwa_cid   ON pwin_assessment(client_id);
CREATE INDEX IF NOT EXISTS ix_pwan_cid  ON pwin_answer(client_id);
CREATE INDEX IF NOT EXISTS ix_py_cid    ON plan_year(client_id);
CREATE INDEX IF NOT EXISTS ix_usa_cid   ON user_scope_assignment(client_id);


-- ---------------------------------------------------------------------
-- 3. Roles
--
-- app_role owns NOTHING. It is granted DML only. Because it is not the
-- table owner it cannot bypass RLS -- and FORCE below closes the gap even
-- for the owner.
-- ---------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cpde_app') THEN
        CREATE ROLE cpde_app NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cpde_migrate') THEN
        CREATE ROLE cpde_migrate NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO cpde_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO cpde_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO cpde_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cpde_app;

-- The application must NOT be able to change policies or schema.
REVOKE CREATE ON SCHEMA public FROM cpde_app;

COMMENT ON ROLE cpde_app IS
    'Application runtime role. Owns nothing, cannot bypass RLS, cannot DDL. '
    'The API server connects as a login role that inherits this.';


-- ---------------------------------------------------------------------
-- 4. Tenant context -- set PER TRANSACTION
--
-- The application calls set_tenant() immediately after BEGIN, with a value
-- derived from the authenticated session. NEVER from a request parameter.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_tenant(p_client_id UUID) RETURNS VOID AS $$
BEGIN
    -- SET LOCAL: reverts at COMMIT/ROLLBACK, so a pooled connection cannot
    -- carry this tenant into the next request.
    PERFORM set_config('app.client_id', p_client_id::text, true);
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION current_tenant() RETURNS UUID AS $$
DECLARE v TEXT;
BEGIN
    v := current_setting('app.client_id', true);
    IF v IS NULL OR v = '' THEN
        -- Fail CLOSED. No context means no rows, never all rows.
        RETURN '00000000-0000-0000-0000-000000000000'::uuid;
    END IF;
    RETURN v::uuid;
EXCEPTION WHEN others THEN
    RETURN '00000000-0000-0000-0000-000000000000'::uuid;
END; $$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION current_tenant() IS
    'Returns the all-zero UUID when no tenant context is set, so a query '
    'without context matches nothing. Fails closed by construction.';


-- ---------------------------------------------------------------------
-- 5. Enable RLS on every tenant-scoped table
-- ---------------------------------------------------------------------

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'client','org_node','app_user','user_scope_assignment','market',
        'pursuit','pursuit_year_projection','pursuit_staffing',
        'pursuit_phase_duration','pursuit_staffing_meta',
        'pwin_assessment','pwin_answer','plan_year','audit_log']
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', t);
        IF t = 'client' THEN
            EXECUTE format($f$CREATE POLICY tenant_isolation ON %I
                USING (id = current_tenant())
                WITH CHECK (id = current_tenant())$f$, t);
        ELSE
            EXECUTE format($f$CREATE POLICY tenant_isolation ON %I
                USING (client_id = current_tenant())
                WITH CHECK (client_id = current_tenant())$f$, t);
        END IF;
    END LOOP;
END $$;

-- NOTE on audit_log: client_id is nullable there (a failed login has no
-- tenant yet). Those rows are invisible to the app role by design --
-- they are for CDA operations review, read out of band.


-- ---------------------------------------------------------------------
-- 6. Coverage assertion
--
-- Fails the migration if a tenant-scoped table was added later without a
-- policy. This is the control that survives future development.
-- ---------------------------------------------------------------------

DO $$
DECLARE missing TEXT;
BEGIN
    SELECT string_agg(c.relname, ', ') INTO missing
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
       AND EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = c.oid AND a.attname = 'client_id'
                      AND NOT a.attisdropped)
       AND NOT c.relrowsecurity;
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'Tables with client_id but no RLS: %', missing;
    END IF;
END $$;

COMMIT;

-- =====================================================================
-- HOW THE APPLICATION MUST USE THIS
--
--   BEGIN;
--   SELECT set_tenant('<client_id from the auth token>');
--   ... queries ...
--   COMMIT;
--
-- The client_id comes from the authenticated session or the resolved API
-- key. NEVER from a request body, query string or header the caller
-- controls.
--
-- Scope filtering (business unit / division) is a SEPARATE concern layered
-- on top -- fn_user_visible_org_nodes(). RLS separates COMPANIES; the scope
-- predicate separates BUSINESS UNITS within a company. Do not merge them
-- into one policy: they have different failure modes and different owners.
--
-- ---------------------------------------------------------------------
-- OPEN QUESTIONS -- I could not verify these without a running instance
--
-- Q1. Reference tables (role, phase, labor_category, contract_type,
--     opportunity_type, pipeline_stage, questionnaire_*) have no client_id
--     and are deliberately global. Confirm no client will ever need a
--     private labor category or a custom question. If they will, those
--     tables need client_id and a policy.
--
-- Q2. current_tenant() returning the zero UUID means a context-less query
--     returns no rows rather than erroring. Silent-empty can look like a
--     bug rather than a security event. Consider RAISE EXCEPTION instead
--     once the application reliably sets context.
--
-- Q3. audit_log under FORCE RLS: verify the app can still INSERT rows for
--     its own tenant, and that CDA operations can read across tenants via
--     a separate role that BYPASSRLS. Not yet defined here.
--
-- Q4. Performance: policies add a predicate to every query. With 150
--     pursuits it is irrelevant. Re-check with realistic volume.
-- =====================================================================
