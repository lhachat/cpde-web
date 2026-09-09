"""
POST /api/pursuits/{id}/recalculate -- the Pre-BH questionnaire path.
POST /api/pursuits/{id}/recalculate/preview -- the sandbox's what-if
    version: scores hypothetical, unsaved answers and never writes to
    the database.

See ../recalc.py for the actual computation. This router only does the
scope/closed/sole-source checks every write endpoint in this app does
(see write.py's own header) before handing off.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, field_validator

from ..auth import Principal, current_principal, require_role
from ..db import fetch_one, tenant_tx
from ..recalc import recalculate_pwin
from ..routers_common import SCOPED, _uuid
from ..scoring import ScoringTableError
from .. import scoring

router = APIRouter(prefix="/api", tags=["recalculate"])


class RecalculateIn(BaseModel):
    # Optional: an empty body (no Content-Type / no JSON at all) must
    # keep working exactly as before -- this endpoint had no body until
    # now, and every existing caller (the UI's own dCalc button, up to
    # this round) sends none. FastAPI already treats a missing/absent
    # body as "use the model's defaults" for an all-optional model.
    scenario: str = "BASE"

    @field_validator("scenario")
    @classmethod
    def _scenario(cls, v):
        if v not in ("BASE", "DEPENDENT_WON"):
            raise ValueError("scenario must be BASE or DEPENDENT_WON")
        return v


@router.post("/pursuits/{pursuit_id}/recalculate")
async def recalculate(
    pursuit_id: str,
    body: RecalculateIn = RecalculateIn(),
    p: Principal = Depends(require_role("admin", "capture_manager")),
):
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id, p.user_id) as cur:
        pu = fetch_one(cur, f"""
            SELECT p.id, p.outcome, p.is_sole_source
              FROM pursuit p WHERE p.id = %s AND {SCOPED}""",
            (pursuit_id, p.user_id))
        if not pu:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")
        if pu["outcome"] is not None:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                "pursuit is closed and cannot be edited")
        if pu["is_sole_source"]:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "sole source pursuits use the 95% business rule, not the "
                "engine -- see the Sole source field on this pursuit")
        # The Pre-BH stage guard AND the "no dependency, no DEPENDENT_WON
        # scenario" guard both live in recalculate_pwin() itself (not
        # here) so write.py's sole-source-toggle-off path gets the former
        # too.

        row = await recalculate_pwin(cur, pursuit_id, p.user_id,
                                     scenario=body.scenario)
    return row


class RecalcPreviewIn(BaseModel):
    # question code -> answer label text, e.g. {"TM1A": "On contract today"}
    answers: dict[str, str]

    @field_validator("answers")
    @classmethod
    def _known_codes(cls, v):
        try:
            scored_codes = scoring.scored_question_codes()
        except ScoringTableError as exc:
            raise ValueError(str(exc))
        unknown = set(v) - set(scored_codes)
        if unknown:
            raise ValueError(f"unscored question code(s): {sorted(unknown)}")
        return v


@router.post("/pursuits/{pursuit_id}/recalculate/preview")
async def recalculate_preview(
    pursuit_id: str,
    body: RecalcPreviewIn,
    p: Principal = Depends(current_principal),
):
    """The sandbox's what-if Recalculate Pwin. Read-only -- no role
    restriction beyond being an authenticated, in-scope user, matching
    pursuit_history's own reasoning (this exposes nothing a viewer of the
    pursuit couldn't already see, and writes nothing)."""
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id) as cur:
        pu = fetch_one(cur, f"""
            SELECT p.id FROM pursuit p WHERE p.id = %s AND {SCOPED}""",
            (pursuit_id, p.user_id))
        if not pu:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")
        result = await recalculate_pwin(
            cur, pursuit_id, p.user_id,
            answers_override=body.answers, persist=False)
    return result
