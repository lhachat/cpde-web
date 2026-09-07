-- =====================================================================
-- 18_pursuit_owner.sql -- Owner/POC field on pursuit
--
-- Goes in ddl/.
--
-- WHY: backlog item 3g. A pursuit needs a named point of contact,
-- distinct from created_by/updated_by (audit trail, who touched the
-- row last) -- this is a business assignment, who OWNS the pursuit,
-- set deliberately and changed rarely. Nullable: not every pursuit has
-- an assigned owner yet, and clearing it is a legitimate edit, not an
-- error (unlike org_node_id, which is NOT NULL and cannot be cleared).
--
-- No explicit ON DELETE clause, matching created_by/updated_by/
-- calculated_by's own pattern exactly (ddl/01_schema.sql) -- app_user
-- rows are soft-deleted (is_active), never hard-deleted, so the default
-- NO ACTION behavior is never actually exercised in practice; kept
-- consistent with the existing FK-to-app_user columns rather than
-- introducing a fourth ON DELETE policy for the same target table.
-- =====================================================================

BEGIN;

ALTER TABLE pursuit
    ADD COLUMN IF NOT EXISTS owner_user_id UUID REFERENCES app_user(id);

COMMENT ON COLUMN pursuit.owner_user_id IS
    'Owner/POC -- the person who owns this pursuit, a business '
    'assignment distinct from created_by/updated_by (audit trail).  '
    'Nullable and independently clearable. Write-scoped so the '
    'assigned user must be within the PURSUIT''s OWN org node''s '
    'visible scope (fn_user_has_scope), not the caller''s -- see '
    'plan_scope.py''s resolve_pursuit_owner().';

COMMIT;

-- =====================================================================
-- VERIFY
--   \d pursuit
--   -- expect owner_user_id UUID, nullable, FK to app_user(id)
-- =====================================================================
