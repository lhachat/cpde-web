"""
Resolving which license-boundary business unit a user's plan_year writes
and reads apply to.

WHY THIS EXISTS: a user can be scoped to more than one license-boundary
BU (AERO's admin sees both BU and BU2). Every plan_year query used to
either silently merge rows from every visible org node with no way to
tell them apart (GET /api/plan-years, bootstrap.py's embedded copy) or
refuse outright with no way to say which BU was meant (PUT). Both are
wrong in different ways -- the silent merge is worse, since it looks
like it works right up until a second BU actually has data.

One resolver, reused everywhere plan_year is read or written, so the
disambiguation logic can't drift between call sites the way the merge
bug did.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import HTTPException, status

from .db import fetch_all


def exclude_test_fixtures(nodes: list[dict]) -> list[dict]:
    """The ONE place every user-facing org-unit PICKER excludes
    test-fixture nodes (org_node.is_test_fixture, e.g. BUZ) from their
    option lists. Every picker resolver below calls this exactly once,
    on its own already-scope-correct candidate list, instead of
    repeating an "AND NOT o.is_test_fixture" clause in three separate
    SQL statements that could drift out of sync with each other.

    Deliberately NOT applied to fn_user_visible_org_nodes, fn_user_pursuits,
    or anything upstream of them -- this is a display-only exclusion. A
    user genuinely scoped to a test-fixture node must still resolve
    correctly everywhere else; only being OFFERED that node as a choice
    in a picker is what this hides."""
    return [n for n in nodes if not n.get("is_test_fixture")]


def resolve_license_boundary_nodes(cur, user_id) -> list[dict]:
    """Candidate plan-scope nodes this user can act on, within their scope
    for the current tenant: license-boundary BUs, plus the tenant's root
    org node (whole-business scope) when it's in the user's visible set.

    The root node (parent_id IS NULL) is only ever visible to a user who
    is scoped to it directly -- fn_user_visible_org_nodes expands scope
    assignments downward to descendants, never upward, so a user scoped
    to a single BU never sees the root this way. That keeps a single-BU
    user's candidate list exactly as before.

    Reuses fn_user_visible_org_nodes -- THE scope predicate -- never a
    hand-written filter.

    UNFILTERED with respect to is_test_fixture on purpose: this feeds
    BOTH the picker's display list AND actual data/write resolution
    (resolve_plan_year_node, bootstrap's plan_node_id). Narrowing it
    here would silently take a genuinely test-fixture-scoped user's
    ability to read or write their own targets, not just hide a choice
    from a dropdown. Callers building a user-facing OPTION LIST from
    this must filter through exclude_test_fixtures themselves at the
    point of display -- see bootstrap.py's target_org_nodes and
    portfolio.py's plan-years candidates."""
    return fetch_all(cur, """
        SELECT o.id, o.code, o.name, o.is_test_fixture FROM org_node o
         WHERE o.id IN (SELECT org_node_id FROM fn_user_visible_org_nodes(%s))
           AND (o.is_license_boundary OR o.parent_id IS NULL) AND o.is_active
         ORDER BY (o.parent_id IS NULL) DESC, o.code""", (user_id,))


def _candidate_payload(nodes: list[dict]) -> list[dict]:
    return [{"id": str(n["id"]), "code": n["code"], "name": n["name"]}
            for n in nodes]


def resolve_plan_year_node(cur, user_id, org_node_id: str | None):
    """The single node_id a plan_year write applies to, or raise.

    - Zero candidates: 403, nothing in scope to write to.
    - One candidate, no org_node_id given: that one, unchanged behavior
      for a single-BU user (backward compatible for demo.admin and
      anyone else not facing this ambiguity).
    - Multiple candidates, no org_node_id given: 409 with the real
      candidate list in the body -- not just a string saying "ambiguous"
      with no way to recover.
    - org_node_id given: MUST be one of this user's own candidates.
      Never trust a client-supplied id without checking it against the
      resolved set -- a malformed or out-of-scope id is 404, matching
      this file's own "404, never 403, for an id outside scope" rule.
    """
    nodes = resolve_license_boundary_nodes(cur, user_id)
    if not nodes:
        raise HTTPException(status.HTTP_403_FORBIDDEN,
                            "no business unit in scope")

    if org_node_id:
        try:
            wanted = str(UUID(org_node_id))
        except (ValueError, AttributeError, TypeError):
            raise HTTPException(status.HTTP_404_NOT_FOUND,
                                "business unit not found in your scope")
        match = next((n for n in nodes if str(n["id"]) == wanted), None)
        if not match:
            raise HTTPException(status.HTTP_404_NOT_FOUND,
                                "business unit not found in your scope")
        return match["id"]

    if len(nodes) == 1:
        return nodes[0]["id"]

    raise HTTPException(status.HTTP_409_CONFLICT, {
        "error": "ambiguous_business_unit",
        "message": "scope covers several business units; specify org_node_id",
        "candidates": _candidate_payload(nodes),
    })


"""
Dashboard scope selector -- a SEPARATE, independent concept from the
license-boundary resolver above. Targets & Budgets edits exactly one
license-boundary BU's own plan_year row at a time; the Dashboard (and
the other portfolio views sharing its scope control) just VIEWS a
rollup of everything at or beneath some node the user already has, at
whatever level of the tree they pick. Different granularity, different
rules -- deliberately not reusing resolve_plan_year_node's candidate
set, which would wrongly exclude divisions and non-root business nodes
entirely.
"""

_NODE_TYPE_DEPTH = {"business": 0, "business_unit": 1, "division": 2}


def user_assigned_nodes(cur, user_id) -> list[dict]:
    """The org nodes a user is DIRECTLY scope-assigned to -- the roots the
    Dashboard scope selector's option tree is built from. Deliberately
    NOT fn_user_visible_org_nodes' downward expansion: that answers "what
    can this user see", not "where do they sit in the tree", which is
    what determines how many selector tiers to offer."""
    return fetch_all(cur, """
        SELECT o.id, o.code, o.name, o.node_type, o.parent_id
          FROM user_scope_assignment usa
          JOIN org_node o ON o.id = usa.org_node_id
         WHERE usa.user_id = %s AND o.is_active
         ORDER BY o.code""", (user_id,))


def _dashboard_candidate_nodes(cur, user_id) -> list[dict]:
    """Every node the Dashboard's scope selection may legitimately
    resolve to: each of the user's own directly-assigned nodes, plus
    that node's full subtree, flattened and de-duplicated. UNFILTERED --
    this is the real access-control candidate set, including any
    test-fixture node the caller actually happens to be scoped to.
    dashboard_scope_options (the picker's DISPLAY list) filters this;
    resolve_dashboard_node's VALIDATION step does not, so a user
    genuinely scoped to a test-fixture node can still explicitly select
    it even though it is never offered as a choice."""
    roots = user_assigned_nodes(cur, user_id)
    if not roots:
        return []
    seen: dict[str, dict] = {}
    for root in roots:
        subtree = fetch_all(cur, """
            WITH RECURSIVE sub AS (
                SELECT id, code, name, node_type, parent_id, is_test_fixture
                  FROM org_node WHERE id = %s AND is_active
                UNION ALL
                SELECT c.id, c.code, c.name, c.node_type, c.parent_id, c.is_test_fixture
                  FROM org_node c JOIN sub s ON c.parent_id = s.id
                 WHERE c.is_active
            )
            SELECT * FROM sub""", (root["id"],))
        for n in subtree:
            seen[str(n["id"])] = n
    return sorted(seen.values(),
                 key=lambda n: (_NODE_TYPE_DEPTH.get(n["node_type"], 9), n["code"]))


def dashboard_scope_options(cur, user_id) -> list[dict]:
    """Every node the Dashboard's scope selector may OFFER: a division
    yields only itself (a division cannot have children -- see
    fn_org_node_validate); a business or business_unit node yields
    itself (labelled a "rollup") plus every descendant. Test-fixture
    nodes are excluded here (the picker's display list) via
    exclude_test_fixtures -- see _dashboard_candidate_nodes for the
    unfiltered set actual scope resolution still uses."""
    nodes = exclude_test_fixtures(_dashboard_candidate_nodes(cur, user_id))
    return [{"id": str(n["id"]), "code": n["code"], "name": n["name"],
             "kind": "leaf" if n["node_type"] == "division" else "rollup"}
            for n in nodes]


def resolve_dashboard_node(cur, user_id, org_node_id: str | None) -> str:
    """The single org node id the Dashboard's current scope selection
    anchors on, validated against this user's own UNFILTERED candidate
    set (_dashboard_candidate_nodes) -- deliberately not the picker's
    display list, so a user genuinely scoped to a test-fixture node can
    still explicitly select it even though it is never offered as a
    choice. Never trust a client-supplied id without checking it here.
    Defaults to the user's own highest (shallowest) assigned node when
    none is given, so the Dashboard shows real numbers -- the user's own
    full scope, summed -- without anyone having to touch the selector
    first."""
    roots = user_assigned_nodes(cur, user_id)
    if not roots:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "no scope assigned")
    if org_node_id:
        try:
            wanted = str(UUID(org_node_id))
        except (ValueError, AttributeError, TypeError):
            raise HTTPException(status.HTTP_404_NOT_FOUND,
                                "org node not found in your scope")
        candidates = _dashboard_candidate_nodes(cur, user_id)
        if not any(str(n["id"]) == wanted for n in candidates):
            raise HTTPException(status.HTTP_404_NOT_FOUND,
                                "org node not found in your scope")
        return wanted
    top = min(roots, key=lambda n: _NODE_TYPE_DEPTH.get(n["node_type"], 9))
    return str(top["id"])


def dashboard_scope_node_ids(cur, node_id: str) -> list[str]:
    """node_id plus every one of its own descendants -- the population a
    rollup sums or filters over. Safe to call with any node_id already
    validated by resolve_dashboard_node: once a node is confirmed to
    belong to the caller's own assigned subtree, every descendant of it
    is too (a descendant's descendant is still a descendant of the
    original assigned node), so no further scope check is needed here."""
    rows = fetch_all(cur, """
        WITH RECURSIVE sub AS (
            SELECT id FROM org_node WHERE id = %s AND is_active
            UNION ALL
            SELECT c.id FROM org_node c JOIN sub s ON c.parent_id = s.id
             WHERE c.is_active
        )
        SELECT id FROM sub""", (node_id,))
    return [str(r["id"]) for r in rows]


"""
Pursuit org-unit reassignment -- a THIRD independent concept from the
two above. A pursuit is a single, concrete piece of work; it belongs at
exactly one node, and that node must be as SPECIFIC as the tree allows
-- never a BU that already has real divisions beneath it, since a
pursuit sitting there would be invisible to anyone scoped to the whole
BU's rollup view but ambiguous about which division actually owns it.
Checked directly against the schema (not assumed): pursuit.org_node_id
has only a plain FK to org_node(id), no CHECK or trigger restricting it
to a leaf node -- nothing in the database itself forbids placing a
pursuit directly on a BU that has divisions. This "leaf only" rule is
therefore an APPLICATION-level choice enforced by the picker's option
list and this resolver, not a structural guarantee -- worth knowing if
a future direct-SQL import ever needs to reason about what's possible
versus what this endpoint allows.
"""


def _active_org_tree(cur) -> dict[str, dict]:
    """Every active org node for the current tenant, by id -- NOT scope-
    restricted to the caller. RLS still enforces tenant isolation (the
    tenant_isolation policy on org_node), so this cannot cross tenants;
    it is used only to build a display label (an ancestor chain of
    NAMES), never to decide what a caller may see or touch. A user
    scoped to a single division already implicitly knows which BU they
    report into -- showing that BU's name in their own picker label is
    not a scope leak, unlike pursuit or business data would be."""
    rows = fetch_all(cur, """
        SELECT id, code, name, node_type, parent_id, is_license_boundary,
               is_test_fixture
          FROM org_node WHERE is_active""")
    return {str(r["id"]): r for r in rows}


def _label_path(tree: dict[str, dict], node: dict) -> list[str]:
    """Names from the nearest license-boundary ancestor (inclusive) down
    to `node` itself -- "Advanced Systems | Sensors" for a division,
    "Space Systems" alone for a license-boundary BU with nothing below
    it. Walks parent_id generically, however deep the real tree goes,
    rather than assuming exactly two levels."""
    chain = [node]
    cur_node = node
    while cur_node["parent_id"] and not cur_node["is_license_boundary"]:
        parent = tree.get(str(cur_node["parent_id"]))
        if parent is None:
            break
        chain.append(parent)
        cur_node = parent
    chain.reverse()
    return [n["name"] for n in chain]


def _assignable_candidate_nodes(cur, user_id) -> list[dict]:
    """Every org node a pursuit could legitimately be assigned to within
    the caller's own visible scope: every division, plus every
    business_unit that has NO division of its own (a BU with real
    divisions beneath it is excluded -- see this module's docstring
    above). The root business node is never assignable; a pursuit
    belongs to an operating unit, not the abstract whole business.
    UNFILTERED with respect to is_test_fixture -- this is the real
    access-control candidate set resolve_pursuit_org_node validates
    against; assignable_pursuit_org_nodes (the picker's DISPLAY list)
    filters it.

    Built entirely from fn_user_visible_org_nodes's own answer -- a
    user's visible set is always the full downward closure of whatever
    they are assigned to, so a division's parent BU having further
    divisions is always correctly knowable from what THIS caller can
    see, with no separate unscoped query needed for the filtering
    itself (only for the display label, see _active_org_tree)."""
    visible_ids = {str(r["org_node_id"]) for r in fetch_all(
        cur, "SELECT org_node_id FROM fn_user_visible_org_nodes(%s)", (user_id,))}
    tree = _active_org_tree(cur)
    visible = [n for n in tree.values() if str(n["id"]) in visible_ids]
    has_division_child = {str(n["parent_id"]) for n in visible
                          if n["node_type"] == "division" and n["parent_id"]}
    return [n for n in visible
           if n["node_type"] == "division"
           or (n["node_type"] == "business_unit"
               and str(n["id"]) not in has_division_child)]


def assignable_pursuit_org_nodes(cur, user_id) -> list[dict]:
    """Every org node the pursuit form's picker should OFFER -- the
    unfiltered candidate set (_assignable_candidate_nodes) with
    test-fixture nodes excluded via exclude_test_fixtures."""
    tree = _active_org_tree(cur)
    assignable = exclude_test_fixtures(_assignable_candidate_nodes(cur, user_id))
    options = [{"id": str(n["id"]), "code": n["code"], "name": n["name"],
               "path": _label_path(tree, n)} for n in assignable]
    options.sort(key=lambda o: " | ".join(o["path"]))
    return options


def resolve_pursuit_org_node(cur, user_id, org_unit_code: str) -> str:
    """The org_node_id a pursuit reassignment applies to, or 404 --
    never trust a caller-supplied code without checking it against this
    user's own UNFILTERED assignable set (_assignable_candidate_nodes),
    not the picker's display list -- a user genuinely in scope for a
    test-fixture node could otherwise never move a pursuit there even
    though it is still, structurally, theirs to use. Same "404, never
    403, for something outside scope" convention write.py already
    follows everywhere else."""
    candidates = _assignable_candidate_nodes(cur, user_id)
    match = next((n for n in candidates if n["code"] == org_unit_code), None)
    if not match:
        raise HTTPException(status.HTTP_404_NOT_FOUND,
                            "org unit not found in your scope")
    return str(match["id"])
