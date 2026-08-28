"""
Authentication and request-scoped identity.

LOCAL DEVELOPMENT USES A STUB. The stub is written to obey the same rule as
production: the tenant is resolved server-side from a session cookie and is
NEVER read from a header, query parameter or request body. If a dev shortcut
had allowed `?client_id=...`, that pattern would survive into production and
undo RLS entirely.

Production replaces resolve_session() with an OIDC/SAML flow against the
client's IdP. Nothing else in this file changes.
"""
from __future__ import annotations

import os
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import Cookie, Depends, HTTPException, status

from .db import unscoped_tx

SESSION_COOKIE = "cpde_session"
SESSION_TTL = timedelta(hours=8)
DEV_LOGIN_ENABLED = os.environ.get("CPDE_DEV_LOGIN", "1") == "1"


@dataclass(frozen=True)
class Principal:
    """Who is making this request. Immutable by design."""
    user_id: UUID
    client_id: UUID
    client_code: str
    email: str
    display_name: str
    roles: tuple[str, ...]

    def has_role(self, *codes: str) -> bool:
        return any(c in self.roles for c in codes)


# In-memory session store. Redis or a signed cookie in production; the
# interface is what matters, not the storage.
_sessions: dict[str, tuple[Principal, datetime]] = {}


def create_session(p: Principal) -> str:
    token = secrets.token_urlsafe(32)
    _sessions[token] = (p, datetime.now(timezone.utc) + SESSION_TTL)
    return token


def destroy_session(token: str | None) -> None:
    if token:
        _sessions.pop(token, None)


def resolve_session(token: str | None) -> Principal | None:
    if not token:
        return None
    entry = _sessions.get(token)
    if not entry:
        return None
    principal, expires = entry
    if expires < datetime.now(timezone.utc):
        _sessions.pop(token, None)
        return None
    return principal


def lookup_user(email: str) -> Principal | None:
    """Resolve a user WITHOUT tenant context -- this runs before we know the
    tenant, which is the one place that ordering is unavoidable.

    app_user is under RLS, so the application role cannot read it unscoped.
    We therefore read it as a targeted query through a SECURITY DEFINER
    function created for exactly this purpose (see 08_auth.sql). That
    function returns only the columns needed to establish a session, and
    only for an exact email match -- it is not a general bypass.
    """
    with unscoped_tx() as cur:
        cur.execute("SELECT * FROM fn_lookup_login(%s)", (email.lower(),))
        row = cur.fetchone()
    if not row:
        return None
    return Principal(
        user_id=row["user_id"],
        client_id=row["client_id"],
        client_code=row["client_code"],
        email=row["email"],
        display_name=row["display_name"],
        roles=tuple(row["roles"] or ()),
    )


async def current_principal(
    cpde_session: str | None = Cookie(default=None, alias=SESSION_COOKIE),
) -> Principal:
    """The only supported way to learn who is calling.

    Note what is NOT a parameter here: no client_id, no tenant header, no
    impersonation flag. There is deliberately no way for a caller to
    influence which tenant they are.
    """
    principal = resolve_session(cpde_session)
    if principal is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "not authenticated")
    return principal


def require_role(*codes: str):
    """Dependency factory for endpoints that need a particular role."""
    async def _check(p: Principal = Depends(current_principal)) -> Principal:
        if not p.has_role(*codes):
            raise HTTPException(status.HTTP_403_FORBIDDEN,
                                f"requires one of: {', '.join(codes)}")
        return p
    return _check
