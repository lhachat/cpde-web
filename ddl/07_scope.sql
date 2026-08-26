-- =====================================================================
-- 07_scope.sql -- The canonical scope predicate
--
-- Goes in ddl/.
--
-- WHY: fn_user_visible_org_nodes returns org nodes, but nothing applied it
-- to pursuits. Every query would have to re-implement the predicate, and
-- the one that forgets is a silent cross-BU leak. One function, used
-- everywhere, is the control.
--
-- TWO LAYERS, DELIBERATELY SEPARATE:
--   RLS               separates COMPANIES  (tenant isolation)
--   these functions   separate BUSINESS UNITS within a company
-- Different failure modes, different owners. Do not merge them.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Org nodes a user can see: their assigned nodes plus all descendants.
--
-- is_active semantics: deactivating a node also hides everything beneath
-- it, because the recursion cannot reach children through an inactive
-- parent. That is intended -- shutting a business unit shuts its divisions.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_user_visible_org_nodes(p_user_id UUID)
RETURNS TABLE (org_node_id UUID) AS $$
    WITH RECURSIVE assigned AS (
        SELECT o.id, o.parent_id
          FROM org_node o
          JOIN user_scope_assignment usa ON usa.org_node_id = o.id
         WHERE usa.user_id = p_user_id
           AND o.is_active
        UNION ALL
        SELECT c.id, c.parent_id
          FROM org_node c
          JOIN assigned a ON c.parent_id = a.id
         WHERE c.is_active
    )
    SELECT DISTINCT id FROM assigned;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Pursuits a user can see. THE predicate. Use this, never a hand-written
-- org_node_id filter.
--
-- Note this is NOT SECURITY DEFINER: it runs as the caller, so RLS still
-- applies underneath. A user cannot reach another tenant's org nodes even
-- if a scope assignment somehow pointed at one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_user_pursuits(p_user_id UUID)
RETURNS TABLE (pursuit_id UUID) AS $$
    SELECT p.id
      FROM pursuit p
     WHERE p.is_active
       AND p.org_node_id IN (SELECT org_node_id FROM fn_user_visible_org_nodes(p_user_id));
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION fn_user_pursuits(UUID) IS
    'Canonical scope predicate. Apply BEFORE any user-supplied filter: '
    'filtering "to specific units below me" operates within this set, it '
    'does not define it. Conflating the two is an access-control bug.';

-- ---------------------------------------------------------------------
-- Does a user hold a role at or above a node? Used for admin delegation:
-- an admin may only grant access at or below their own node, and may never
-- grant a role above their own.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_user_has_scope(p_user_id UUID, p_org_node_id UUID)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM fn_user_visible_org_nodes(p_user_id)
         WHERE org_node_id = p_org_node_id);
$$ LANGUAGE sql STABLE;

COMMIT;
