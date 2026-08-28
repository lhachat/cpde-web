-- =====================================================================
-- 08_auth.sql -- Login lookup, and only login lookup
--
-- Goes in ddl/.
--
-- THE PROBLEM: app_user is under RLS, so the application role cannot read
-- it without tenant context. But at login we do not yet know the tenant --
-- that is what we are trying to establish. Ordering is unavoidable here.
--
-- THE ANSWER: one narrow SECURITY DEFINER function that resolves a login by
-- exact email and returns only what a session needs. It is not a general
-- RLS bypass:
--   - exact email match only, no LIKE, no wildcards, no listing
--   - returns at most one row
--   - inactive users and inactive clients resolve to nothing
--   - no pursuit, financial or assessment data is reachable through it
--   - EXECUTE granted only to the application role
--
-- Every other query in the system goes through set_tenant() and RLS. This
-- is the single exception, and it exists because authentication has to
-- happen before authorization.
-- =====================================================================

BEGIN;

CREATE OR REPLACE FUNCTION fn_lookup_login(p_email TEXT)
RETURNS TABLE (
    user_id      UUID,
    client_id    UUID,
    client_code  TEXT,
    email        TEXT,
    display_name TEXT,
    roles        TEXT[]
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
STABLE
AS $$
    SELECT u.id,
           u.client_id,
           c.code,
           u.email,
           u.display_name,
           COALESCE(array_agg(DISTINCT r.code) FILTER (WHERE r.code IS NOT NULL),
                    ARRAY[]::text[])
      FROM app_user u
      JOIN client c ON c.id = u.client_id
      LEFT JOIN user_scope_assignment s ON s.user_id = u.id
      LEFT JOIN role r ON r.id = s.role_id
     WHERE lower(u.email) = lower(p_email)
       AND u.is_active
       AND c.is_active
     GROUP BY u.id, u.client_id, c.code, u.email, u.display_name;
$$;

REVOKE ALL ON FUNCTION fn_lookup_login(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_lookup_login(TEXT) TO cpde_app;

COMMENT ON FUNCTION fn_lookup_login(TEXT) IS
    'The ONLY SECURITY DEFINER function in the system. Exists because '
    'authentication must precede tenant resolution. Exact email match, one '
    'row, session fields only. Do not extend it -- add new queries behind '
    'set_tenant() instead.';

COMMIT;

-- =====================================================================
-- Verify the blast radius is what it claims to be:
--
--   SELECT * FROM fn_lookup_login('nobody@nowhere.test');   -- 0 rows
--   SELECT * FROM fn_lookup_login('aero.admin@demoaero.test');
--
-- And confirm nothing else in the schema is SECURITY DEFINER:
--
--   SELECT p.proname
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.prosecdef;
--   -- expect exactly one row: fn_lookup_login
-- =====================================================================
