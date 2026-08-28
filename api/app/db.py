"""
Database access. One rule governs this file:

    TENANT CONTEXT COMES FROM THE SESSION, NEVER FROM THE REQUEST.

RLS in Postgres cannot protect against being told the wrong tenant. If any
code path lets a caller influence which client_id reaches set_tenant(), the
41 database assertions become worthless. Every query goes through
tenant_tx(), which takes its client_id from the authenticated session only.
"""
from __future__ import annotations

import contextlib
import os
from typing import Any, Iterator
from uuid import UUID

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

# The application connects as cpde_api: owns nothing, cannot bypass RLS,
# cannot DDL. Never as the superuser.
DSN = os.environ.get(
    "CPDE_DSN", "postgresql://cpde_api:localdev_api@localhost:5433/cpde")

_pool: ConnectionPool | None = None


def pool() -> ConnectionPool:
    global _pool
    if _pool is None:
        _pool = ConnectionPool(DSN, min_size=1, max_size=10, open=True,
                               kwargs={"row_factory": dict_row})
    return _pool


def close_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


class TenantContextError(RuntimeError):
    """Raised when a query is attempted without a resolved tenant."""


@contextlib.contextmanager
def tenant_tx(client_id: UUID | str,
              user_id: UUID | str | None = None) -> Iterator[psycopg.Cursor]:
    """Open a transaction with tenant context set.

    set_tenant() uses SET LOCAL, so the context dies at COMMIT. That is what
    makes a pooled connection safe: the next request on this connection
    starts with no tenant and therefore sees nothing.

    Pass user_id on any transaction that WRITES. The audit trigger reads it
    to attribute the change; without it the row is still written, but with a
    null actor. Reads do not need it.

    Do not add a variant of this that takes the tenant from anywhere other
    than the session. That is the whole control.
    """
    if not client_id:
        raise TenantContextError("no tenant resolved for this request")
    with pool().connection() as conn:
        with conn.transaction():
            cur = conn.cursor()
            cur.execute("SELECT set_tenant(%s)", (str(client_id),))
            if user_id is not None:
                cur.execute("SELECT set_actor(%s)", (str(user_id),))
            yield cur


@contextlib.contextmanager
def unscoped_tx() -> Iterator[psycopg.Cursor]:
    """A transaction with NO tenant context.

    Deliberately returns nothing from tenant-scoped tables -- current_tenant()
    yields the all-zero UUID and every policy fails to match. Only useful for
    global reference tables (phases, labor categories, questionnaire) and for
    resolving a login, which reads app_user through a SECURITY DEFINER path.
    """
    with pool().connection() as conn:
        with conn.transaction():
            yield conn.cursor()


def fetch_all(cur: psycopg.Cursor, sql: str, params: tuple = ()) -> list[dict[str, Any]]:
    cur.execute(sql, params)
    return cur.fetchall()


def fetch_one(cur: psycopg.Cursor, sql: str, params: tuple = ()) -> dict[str, Any] | None:
    cur.execute(sql, params)
    return cur.fetchone()
