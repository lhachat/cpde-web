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


def resolve_license_boundary_nodes(cur, user_id) -> list[dict]:
    """Candidate license-boundary BUs this user can act on, within their
    scope for the current tenant. Reuses fn_user_visible_org_nodes --
    THE scope predicate -- never a hand-written filter."""
    return fetch_all(cur, """
        SELECT o.id, o.code, o.name FROM org_node o
         WHERE o.id IN (SELECT org_node_id FROM fn_user_visible_org_nodes(%s))
           AND o.is_license_boundary AND o.is_active
         ORDER BY o.code""", (user_id,))


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
