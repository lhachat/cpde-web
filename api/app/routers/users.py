"""
Admin user management -- create, edit and deactivate users without
hand-writing SQL.

Deliberately NOT SSO/SCIM/licensing (that remains a separate, on-hold
effort). This is the standalone, manual, admin-facing capability only:
before this existed, adding a user required a direct SQL INSERT as a
superuser, because the application role itself had no write grant on
app_user at all (21_least_privilege.sql had revoked it after confirming
nothing wrote it -- see 23_user_admin_grants.sql for the narrow
INSERT/UPDATE grant this router is the reason for).

SCOPE DISCIPLINE, server-side, never the UI:
  - Every endpoint here is require_role("admin"). The nav link is
    hidden for non-admins too, but that is cosmetic -- the gate is here.
  - A caller may only see or touch users whose own scope assignments
    fall inside the CALLER's visible org nodes (fn_user_visible_org_nodes
    / fn_user_has_scope -- the same resolution every other scoped
    feature in this app uses, not a new mechanism).
  - Every org node a caller assigns must likewise be inside their own
    visible scope, re-checked here on every write. 404, never 403, for
    an out-of-scope id -- the same convention resolve_pursuit_owner and
    resolve_pursuit_org_node already use (an out-of-scope id is
    indistinguishable from a nonexistent one to the caller).

NEVER HARD-DELETE. Deactivation is is_active = false, which
fn_lookup_login already refuses at login (08_auth.sql) -- while every
historical reference to that user (audit_log.user_id, pursuit.owner_
user_id/created_by/updated_by, pwin_assessment.calculated_by) keeps
resolving exactly as before. DELETE is not even granted to the app role.

AUDITED by the existing generic trigger on both app_user and
user_scope_assignment (trg_audit) -- no new audit mechanism, and every
write here runs inside tenant_tx(client_id, user_id) so set_actor()
attributes it to the real admin who made the change.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator

from ..auth import Principal, require_role
from ..db import fetch_all, fetch_one, tenant_tx
from ..plan_scope import exclude_test_fixtures
from ..routers_common import _uuid

router = APIRouter(prefix="/api/users", tags=["users"])


def _visible_user(cur, caller_id, user_id: str) -> dict:
    """The target user, but only if at least one of their scope
    assignments sits inside the CALLER's own visible org nodes -- 404
    otherwise, same convention as every other out-of-scope id in this
    app. A user with no assignments at all is deliberately NOT visible
    to a scoped admin: there is no org node to judge them against, so
    'in my scope' has no defined answer for them."""
    row = fetch_one(cur, """
        SELECT u.id, u.email, u.display_name, u.is_active
          FROM app_user u
         WHERE u.id = %s
           AND EXISTS (SELECT 1 FROM user_scope_assignment s
                        WHERE s.user_id = u.id
                          AND fn_user_has_scope(%s, s.org_node_id))""",
        (user_id, caller_id))
    if not row:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "user not found")
    return row


def _assignments(cur, user_id: str) -> list[dict]:
    return fetch_all(cur, """
        SELECT s.id, o.code AS org_unit_code, o.name AS org_unit_name,
               r.code AS role_code, r.name AS role_name
          FROM user_scope_assignment s
          JOIN org_node o ON o.id = s.org_node_id
          JOIN role r ON r.id = s.role_id
         WHERE s.user_id = %s
         ORDER BY o.name, r.name""", (user_id,))


def _resolve_org_nodes(cur, caller_id, codes: list[str]) -> list[dict]:
    """Every org node code the caller named, resolved to real ids --
    but only those inside the caller's OWN visible scope. Any code that
    doesn't resolve that way is a 404 naming it, never a silent skip:
    silently dropping a scope the admin asked for would hand them a
    user with less access than the screen said they'd get."""
    resolved = []
    for code in codes:
        row = fetch_one(cur, """
            SELECT o.id, o.code FROM org_node o
             WHERE o.code = %s AND fn_user_has_scope(%s, o.id)""",
            (code, caller_id))
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND,
                                f"org unit not found in your scope: {code}")
        resolved.append(row)
    return resolved


def _role_id(cur, role_code: str):
    row = fetch_one(cur, "SELECT id FROM role WHERE code = %s", (role_code,))
    if not row:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"unknown role: {role_code}")
    return row["id"]


def _replace_assignments(cur, user_id: str, role_id, nodes: list[dict],
                         granted_by) -> None:
    """Set this user's assignments to exactly (role x nodes). DELETE +
    INSERT rather than a diff: user_scope_assignment is a small, flat
    set per user, the whole thing is inside one transaction, and both
    halves fire the same audit trigger, so the change is fully
    reconstructible from audit_log either way."""
    cur.execute("DELETE FROM user_scope_assignment WHERE user_id = %s",
                (user_id,))
    for node in nodes:
        cur.execute("""
            INSERT INTO user_scope_assignment
                (user_id, org_node_id, role_id, granted_by)
            VALUES (%s, %s, %s, %s)""",
            (user_id, node["id"], role_id, granted_by))


class UserIn(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    display_name: str = Field(min_length=1, max_length=200)
    role_code: str = Field(min_length=1, max_length=50)
    org_unit_codes: list[str] = Field(min_length=1)

    @field_validator("email")
    @classmethod
    def _email(cls, v):
        v = v.strip().lower()
        if "@" not in v or v.startswith("@") or v.endswith("@"):
            raise ValueError("a real email address is required")
        return v

    @field_validator("display_name")
    @classmethod
    def _name(cls, v):
        if not v.strip():
            raise ValueError("display name cannot be blank")
        return v.strip()


class UserPatch(BaseModel):
    display_name: str | None = Field(default=None, max_length=200)
    role_code: str | None = None
    org_unit_codes: list[str] | None = None
    is_active: bool | None = None

    @field_validator("display_name")
    @classmethod
    def _name(cls, v):
        if v is not None and not v.strip():
            raise ValueError("display name cannot be blank")
        return v.strip() if v is not None else None


@router.get("")
async def list_users(p: Principal = Depends(require_role("admin"))):
    """Every user inside the caller's own visible scope, plus the option
    lists the create/edit form needs -- one call, same "one payload"
    shape bootstrap.py already uses, rather than three round trips."""
    with tenant_tx(p.client_id) as cur:
        users = fetch_all(cur, """
            SELECT DISTINCT u.id, u.email, u.display_name, u.is_active,
                   u.created_at
              FROM app_user u
              JOIN user_scope_assignment s ON s.user_id = u.id
             WHERE fn_user_has_scope(%s, s.org_node_id)
             ORDER BY u.display_name""", (p.user_id,))
        for u in users:
            u["id"] = str(u["id"])
            u["assignments"] = _assignments(cur, u["id"])

        nodes = fetch_all(cur, """
            SELECT o.id, o.code, o.name, o.is_test_fixture
              FROM org_node o
             WHERE o.is_active AND fn_user_has_scope(%s, o.id)
             ORDER BY o.name""", (p.user_id,))
        roles = fetch_all(cur,
                          "SELECT code, name, description FROM role ORDER BY id")

    return {
        "users": users,
        # Same picker discipline as every other org-unit picker in this
        # app -- test-fixture nodes are never offered as an option.
        "org_units": [{"code": n["code"], "name": n["name"]}
                      for n in exclude_test_fixtures(nodes)],
        "roles": roles,
    }


@router.post("")
async def create_user(body: UserIn,
                      p: Principal = Depends(require_role("admin"))):
    with tenant_tx(p.client_id, p.user_id) as cur:
        role_id = _role_id(cur, body.role_code)
        nodes = _resolve_org_nodes(cur, p.user_id, body.org_unit_codes)

        # Checked before the INSERT so the caller gets a real message
        # rather than a raw unique-violation 500. RLS scopes this read
        # to their own tenant, which is exactly the uniqueness scope
        # uq_app_user_email enforces (client_id, email).
        if fetch_one(cur, "SELECT 1 FROM app_user WHERE lower(email) = %s",
                     (body.email,)):
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"a user with the email {body.email} already exists")

        created = fetch_one(cur, """
            INSERT INTO app_user (client_id, email, display_name, is_active)
            VALUES (%s, %s, %s, TRUE)
         RETURNING id, email, display_name, is_active, created_at""",
            (p.client_id, body.email, body.display_name))
        _replace_assignments(cur, created["id"], role_id, nodes, p.user_id)
        created["id"] = str(created["id"])
        created["assignments"] = _assignments(cur, created["id"])
    return created


@router.patch("/{user_id}")
async def update_user(user_id: str, body: UserPatch,
                      p: Principal = Depends(require_role("admin"))):
    user_id = _uuid(user_id)
    with tenant_tx(p.client_id, p.user_id) as cur:
        existing = _visible_user(cur, p.user_id, user_id)

        # Deactivating yourself would lock the last admin out of the
        # very screen that could undo it -- refused here rather than
        # discovered afterwards.
        if body.is_active is False and str(existing["id"]) == str(p.user_id):
            raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                "you cannot deactivate your own account")

        fields, params = [], []
        if body.display_name is not None:
            fields.append("display_name = %s")
            params.append(body.display_name)
        if body.is_active is not None:
            fields.append("is_active = %s")
            params.append(body.is_active)
        if fields:
            fields.append("updated_at = now()")
            cur.execute(f"UPDATE app_user SET {', '.join(fields)} WHERE id = %s",
                        tuple(params) + (user_id,))

        # Role and scope are one setting in the UI (a role is granted AT
        # an org node), so they are replaced together or not at all --
        # changing one without the other has no meaning in
        # user_scope_assignment's own (user, node, role) shape.
        if body.role_code is not None or body.org_unit_codes is not None:
            current = _assignments(cur, user_id)
            role_code = body.role_code or (current[0]["role_code"]
                                           if current else None)
            codes = (body.org_unit_codes
                     if body.org_unit_codes is not None
                     else [a["org_unit_code"] for a in current])
            if not role_code or not codes:
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST,
                    "a role and at least one org unit are both required")
            role_id = _role_id(cur, role_code)
            nodes = _resolve_org_nodes(cur, p.user_id, codes)
            _replace_assignments(cur, user_id, role_id, nodes, p.user_id)

        updated = fetch_one(cur, """
            SELECT id, email, display_name, is_active, created_at
              FROM app_user WHERE id = %s""", (user_id,))
        updated["id"] = str(updated["id"])
        updated["assignments"] = _assignments(cur, user_id)
    return updated
