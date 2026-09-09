"""
Small helpers shared across router modules -- extracted here (security/
quality audit, 2026-09-09) after being found hand-duplicated
independently in bhptw.py, bootstrap.py, portfolio.py, recalc.py,
staffing.py and write.py. Confirmed byte-identical in every file before
consolidating, not assumed -- this is exactly the class of drift risk
this project has already spent real effort eliminating ACROSS repos
(scoring, fee, the questionnaire spec); found living WITHIN this one
instead. Same level as plan_scope.py (also router-shared, also NOT
inside the routers/ package) for consistency.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import HTTPException, status


def _uuid(value: str) -> str:
    """Reject a malformed id with 404 rather than letting Postgres raise.

    A bad path parameter is a client error. Returning 500 also tells a
    prober that the id reached the database, which is more than they need
    to know -- so this matches the not-found response exactly.
    """
    try:
        return str(UUID(value))
    except (ValueError, AttributeError, TypeError):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not found")


# Every write/read endpoint that scopes a pursuit to the caller's own
# visible set uses this exact predicate -- fn_user_pursuits() is the
# single source of truth for "which pursuits can THIS user see", so an
# endpoint filtering any other way would silently diverge from it.
SCOPED = "p.id IN (SELECT pursuit_id FROM fn_user_pursuits(%s))"
