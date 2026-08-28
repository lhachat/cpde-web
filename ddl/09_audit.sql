-- =====================================================================
-- 09_audit.sql -- Audit trail, enforced by the database
--
-- Goes in ddl/. Apply before the first write endpoint ships.
--
-- WHY A TRIGGER AND NOT APPLICATION CODE: a trigger cannot be bypassed by
-- a script, a psql session, a forgotten code path, or a future endpoint
-- someone writes in a hurry. Application-level auditing records what the
-- application remembered to record. That distinction is exactly what an
-- assessor asks about.
--
-- The application supplies WHO via a transaction-local setting, the same
-- mechanism as tenant context. If it is not set the row still gets written
-- with a null actor -- an unattributed change is recorded, never dropped.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Who is acting. Set alongside set_tenant(), per transaction.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_actor(p_user_id UUID) RETURNS VOID AS $$
BEGIN
    PERFORM set_config('app.user_id', COALESCE(p_user_id::text, ''), true);
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION current_actor() RETURNS UUID AS $$
DECLARE v TEXT;
BEGIN
    v := current_setting('app.user_id', true);
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    RETURN v::uuid;
EXCEPTION WHEN others THEN RETURN NULL;
END; $$ LANGUAGE plpgsql STABLE;


-- ---------------------------------------------------------------------
-- The trigger. Records only what CHANGED on an update, so the log stays
-- readable and does not balloon with unchanged columns.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit() RETURNS TRIGGER AS $$
DECLARE
    changed  JSONB := '{}'::jsonb;
    old_j    JSONB;
    new_j    JSONB;
    k        TEXT;
    rec_id   UUID;
    cid      UUID;
BEGIN
    IF TG_OP = 'INSERT' THEN
        new_j := to_jsonb(NEW);
        changed := jsonb_build_object('new', new_j);
        rec_id := (new_j ->> 'id')::uuid;
        cid := NULLIF(new_j ->> 'client_id', '')::uuid;

    ELSIF TG_OP = 'UPDATE' THEN
        old_j := to_jsonb(OLD);
        new_j := to_jsonb(NEW);
        FOR k IN SELECT jsonb_object_keys(new_j) LOOP
            IF (old_j -> k) IS DISTINCT FROM (new_j -> k) THEN
                changed := changed || jsonb_build_object(
                    k, jsonb_build_object('from', old_j -> k, 'to', new_j -> k));
            END IF;
        END LOOP;
        -- Nothing actually changed: do not write a row.
        IF changed = '{}'::jsonb THEN
            RETURN NEW;
        END IF;
        rec_id := (new_j ->> 'id')::uuid;
        cid := NULLIF(new_j ->> 'client_id', '')::uuid;

    ELSE  -- DELETE
        old_j := to_jsonb(OLD);
        changed := jsonb_build_object('deleted', old_j);
        rec_id := (old_j ->> 'id')::uuid;
        cid := NULLIF(old_j ->> 'client_id', '')::uuid;
    END IF;

    INSERT INTO audit_log (client_id, user_id, action, table_name,
                           record_id, changed_fields)
    VALUES (COALESCE(cid, current_tenant()), current_actor(), TG_OP,
            TG_TABLE_NAME, rec_id, changed);

    RETURN COALESCE(NEW, OLD);
END; $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- SECURITY DEFINER NOTE: the trigger must be able to INSERT into audit_log
-- regardless of the caller's RLS context, or an audit row could be blocked
-- by the very policy it is recording a change to. Its blast radius is one
-- INSERT into one table with values it computes itself -- it takes no
-- caller-supplied arguments. This is the second and last SECURITY DEFINER
-- function in the schema; test_integrity.py asserts the full list.

REVOKE ALL ON FUNCTION fn_audit() FROM PUBLIC;


-- ---------------------------------------------------------------------
-- Attach to every table whose changes matter.
-- ---------------------------------------------------------------------
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'pursuit', 'pwin_assessment', 'pwin_answer', 'plan_year',
        'market', 'org_node', 'app_user', 'user_scope_assignment',
        'pursuit_year_projection', 'pursuit_staffing', 'client']
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_audit ON %I', t);
        EXECUTE format(
            'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()', t);
    END LOOP;
END $$;


-- ---------------------------------------------------------------------
-- The application may INSERT audit rows (via the trigger) and read its own
-- tenant's history. It must NOT be able to update or delete them.
-- ---------------------------------------------------------------------
REVOKE UPDATE, DELETE ON audit_log FROM cpde_app;

COMMENT ON TABLE audit_log IS
    'Written by fn_audit() trigger, not by application code. The app role '
    'has no UPDATE or DELETE. In production these rows should also ship to '
    'a separate account the application cannot write to -- an audit log an '
    'attacker can erase is not an audit log.';

COMMIT;

-- =====================================================================
-- HOW THE APPLICATION USES THIS
--
--   BEGIN;
--   SELECT set_tenant('<client_id>');
--   SELECT set_actor('<user_id>');      -- new: required for attribution
--   UPDATE pursuit SET ... WHERE ...;
--   COMMIT;
--
-- Verify after a write:
--   SELECT occurred_at, action, table_name, user_id, changed_fields
--     FROM audit_log ORDER BY occurred_at DESC LIMIT 5;
-- =====================================================================
