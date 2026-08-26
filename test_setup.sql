-- =====================================================================
-- test_setup.sql -- A restricted login role and test users
--
-- Run AFTER both tenants are loaded.
--   Get-Content test_setup.sql | docker compose exec -T db psql -U cpde -d cpde
--
-- LOCAL ONLY. The password below is a throwaway. In AWS this role's
-- credentials live in Secrets Manager with rotation, and the application
-- assumes them via IAM.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. The login role the application will actually use.
--
-- cpde_app is NOLOGIN -- it is a permission set. This is an account that
-- inherits it. It owns nothing, so RLS binds it. This is the thing that
-- has been missing: every query so far ran as the superuser `cpde`, which
-- bypasses RLS, so none of the isolation has been exercised.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cpde_api') THEN
        CREATE ROLE cpde_api LOGIN PASSWORD 'localdev_api';
    END IF;
END $$;

GRANT cpde_app TO cpde_api;

-- Belt and braces: prove it cannot bypass RLS and cannot change schema.
ALTER ROLE cpde_api NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;

COMMIT;


-- ---------------------------------------------------------------------
-- 2. Application users, for the SCOPE test (a separate concern from RLS)
--
--   RLS separates COMPANIES.
--   fn_user_visible_org_nodes separates BUSINESS UNITS within a company.
--
-- Two different failure modes. Test them separately.
-- ---------------------------------------------------------------------
BEGIN;

-- Give AERO a second business unit so there is something to be excluded
-- from. Without it, a scope test cannot fail and proves nothing.
INSERT INTO org_node (client_id, parent_id, node_type, code, name, is_license_boundary)
SELECT c.id, b.id, 'business_unit', 'BU2', 'Space Systems', TRUE
  FROM client c
  JOIN org_node b ON b.client_id = c.id AND b.node_type = 'business'
 WHERE c.code = 'AERO'
ON CONFLICT (client_id, code) DO NOTHING;

-- A division under AERO's first BU, to test downward inheritance.
INSERT INTO org_node (client_id, parent_id, node_type, code, name)
SELECT c.id, u.id, 'division', 'DIV1', 'Sensors Division'
  FROM client c
  JOIN org_node u ON u.client_id = c.id AND u.code = 'BU'
 WHERE c.code = 'AERO'
ON CONFLICT (client_id, code) DO NOTHING;

-- Users: one per tenant at the top, plus a narrowly-scoped one in AERO.
INSERT INTO app_user (client_id, email, display_name)
SELECT id, 'demo.admin@democlient.test', 'Demo Admin' FROM client WHERE code='DEMO'
ON CONFLICT (client_id, email) DO NOTHING;

INSERT INTO app_user (client_id, email, display_name)
SELECT id, 'aero.admin@demoaero.test', 'Aero Admin' FROM client WHERE code='AERO'
ON CONFLICT (client_id, email) DO NOTHING;

INSERT INTO app_user (client_id, email, display_name)
SELECT id, 'aero.bu2@demoaero.test', 'Aero BU2 Capture Manager' FROM client WHERE code='AERO'
ON CONFLICT (client_id, email) DO NOTHING;

-- Scope assignments.
INSERT INTO user_scope_assignment (user_id, org_node_id, role_id)
SELECT u.id, o.id, r.id
  FROM app_user u
  JOIN client c   ON c.id = u.client_id
  JOIN org_node o ON o.client_id = c.id AND o.node_type = 'business'
  JOIN role r     ON r.code = 'admin'
 WHERE u.email IN ('demo.admin@democlient.test','aero.admin@demoaero.test')
ON CONFLICT (user_id, org_node_id, role_id) DO NOTHING;

-- This one is scoped ONLY to BU2, which holds no pursuits. It should see
-- nothing, even though its tenant has 150.
INSERT INTO user_scope_assignment (user_id, org_node_id, role_id)
SELECT u.id, o.id, r.id
  FROM app_user u
  JOIN client c   ON c.id = u.client_id
  JOIN org_node o ON o.client_id = c.id AND o.code = 'BU2'
  JOIN role r     ON r.code = 'capture_manager'
 WHERE u.email = 'aero.bu2@demoaero.test'
ON CONFLICT (user_id, org_node_id, role_id) DO NOTHING;

COMMIT;

SELECT c.code AS client, u.email, o.code AS scope, o.node_type, r.code AS role
  FROM app_user u
  JOIN client c ON c.id = u.client_id
  LEFT JOIN user_scope_assignment s ON s.user_id = u.id
  LEFT JOIN org_node o ON o.id = s.org_node_id
  LEFT JOIN role r ON r.id = s.role_id
 ORDER BY c.code, u.email;
