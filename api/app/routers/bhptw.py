"""
Black Hat and PTW assessment endpoints.

Source of truth: BH_PTW_Form.frm (VBA), and the comments in
ddl/11_assessment_type.sql, which this must match exactly:

  Pre-BH      Pwin computed by the engine from the questionnaire.
  Post-BH     Analyst enters Pwin and a price aggressiveness (P1). Fee is
              COMPUTED: get_fee(contract_type) + P1 delta.
  Post-PTW    Analyst enters Pwin, margin and bid price directly. Fee is
              NOT computed -- it replaces the formula.

Neither path calls the engine. /v1/run is only ever used for the Pre-BH
questionnaire path (see the top of 13_bhptw_fee.sql for why the fee
calculation itself is not protected IP). By the time an analyst is
entering Black Hat or PTW data, a real competitive analysis has already
happened outside this system -- the engine's questionnaire-based score has
nothing further to add.

Same write discipline as write.py: tenant from the session, scope
re-checked on every id, 404 for out of scope, 409 for a closed pursuit.
"""
from __future__ import annotations

from datetime import date
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator

from ..auth import Principal, require_role
from ..db import fetch_all, fetch_one, tenant_tx
from ..fee import resolve_fee

router = APIRouter(prefix="/api", tags=["bhptw"])

SCOPED = "p.id IN (SELECT pursuit_id FROM fn_user_pursuits(%s))"


def _uuid(value: str) -> str:
    try:
        return str(UUID(value))
    except (ValueError, AttributeError, TypeError):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not found")


class BlackHatIn(BaseModel):
    scenario: str = "BASE"
    aggressiveness_option_code: str = Field(min_length=1, max_length=50)
    investment: Decimal | None = Field(default=None, ge=0)
    completed_date: date | None = None
    base_pwin: Decimal = Field(ge=0, le=1)

    @field_validator("scenario")
    @classmethod
    def _scenario(cls, v):
        if v not in ("BASE", "DEPENDENT_WON"):
            raise ValueError("scenario must be BASE or DEPENDENT_WON")
        return v


class PtwIn(BaseModel):
    scenario: str = "BASE"
    # The VBA form caps this at 30%; ddl/11_assessment_type.sql documents
    # the same cap. Enforced here, not just client-side.
    margin_rate: Decimal = Field(ge=0, le=Decimal("0.30"))
    bid_price: Decimal = Field(ge=0)
    investment: Decimal | None = Field(default=None, ge=0)
    completed_date: date | None = None
    base_pwin: Decimal = Field(ge=0, le=1)

    @field_validator("scenario")
    @classmethod
    def _scenario(cls, v):
        if v not in ("BASE", "DEPENDENT_WON"):
            raise ValueError("scenario must be BASE or DEPENDENT_WON")
        return v


def _load_pursuit(cur, pursuit_id: str, user_id, scenario: str) -> dict:
    """Scope check, closed check, and the hard questionnaire prerequisite.

    The prerequisite is deliberately NOT scenario-scoped: a QUESTIONNAIRE
    assessment for the pursuit at all is what test_integrity.py's "BH/PTW
    is preceded by a questionnaire assessment" check verifies, and what the
    VBA form checks before opening.
    """
    row = fetch_one(cur, f"""
        SELECT p.id, p.outcome, p.depends_on_pursuit_id, p.bp_start_date,
               p.contract_type_id, ct.label AS contract_type_label,
               ct.base_fee_rate
          FROM pursuit p
          LEFT JOIN contract_type ct ON ct.id = p.contract_type_id
         WHERE p.id = %s AND {SCOPED}""", (pursuit_id, user_id))
    if not row:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")
    if row["outcome"] is not None:
        raise HTTPException(status.HTTP_409_CONFLICT,
                            "pursuit is closed and cannot be edited")

    has_dep = row["depends_on_pursuit_id"] is not None
    if scenario == "DEPENDENT_WON" and not has_dep:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "this pursuit has no dependency; there is no "
                            "dependent-won scenario to record")

    has_questionnaire = fetch_one(cur, """
        SELECT 1 FROM pwin_assessment
         WHERE pursuit_id = %s AND assessment_type = 'QUESTIONNAIRE'
         LIMIT 1""", (pursuit_id,))
    if not has_questionnaire:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "Complete the Pwin questionnaire before entering Black Hat or "
            "PTW data for this pursuit.")

    return row


def _recompute_complete(cur, pursuit_id: str, has_dep: bool) -> bool:
    """black_hat_ptw_complete is TRUE only once every scenario the pursuit
    actually needs has a current BLACK_HAT or PTW assessment -- not on
    every individual submit. A dependent pursuit needs both BASE and
    DEPENDENT_WON (test_integrity.py's "dependent pursuits have BOTH
    assessments" check)."""
    needed = {"BASE", "DEPENDENT_WON"} if has_dep else {"BASE"}
    rows = fetch_all(cur, """
        SELECT scenario FROM pwin_assessment
         WHERE pursuit_id = %s AND is_current
           AND assessment_type IN ('BLACK_HAT','PTW')""", (pursuit_id,))
    done = {r["scenario"] for r in rows}
    complete = needed <= done
    cur.execute("""
        UPDATE pursuit SET black_hat_ptw_complete = %s WHERE id = %s""",
        (complete, pursuit_id))
    return complete


def _check_completed_date(completed_date: date | None, bp_start_date):
    # Matches test_integrity.py's "a completed BH/PTW is dated on or after
    # B&P start" -- reject at the source instead of letting bad data land
    # and only be caught by the nightly check.
    if completed_date and bp_start_date and completed_date < bp_start_date:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"completed date ({completed_date}) cannot be before "
            f"B&P start ({bp_start_date})")


@router.post("/pursuits/{pursuit_id}/blackhat")
async def submit_black_hat(
    pursuit_id: str,
    body: BlackHatIn,
    p: Principal = Depends(require_role("admin", "capture_manager")),
):
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id, p.user_id) as cur:
        pu = _load_pursuit(cur, pursuit_id, p.user_id, body.scenario)
        _check_completed_date(body.completed_date, pu["bp_start_date"])
        has_dep = pu["depends_on_pursuit_id"] is not None

        opt = fetch_one(cur, """
            SELECT o.id, o.price_delta FROM question_option o
              JOIN question q ON q.id = o.question_id
             WHERE q.code = 'P1' AND o.code = %s AND o.is_active""",
            (body.aggressiveness_option_code,))
        if not opt:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"unknown price aggressiveness option: "
                f"{body.aggressiveness_option_code!r}")
        fee = resolve_fee(cur, pu["contract_type_id"], opt["id"])
        if fee < 0 or fee > 1:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "computed fee is out of range; check the fee configuration")

        # Append-only: insert a new row, flip the previous current row for
        # this scenario off. Never UPDATE a pwin value in place.
        cur.execute("""
            UPDATE pwin_assessment SET is_current = FALSE
             WHERE pursuit_id = %s AND scenario = %s AND is_current""",
            (pursuit_id, body.scenario))
        # No dependency blend is computed here (that math lives in the
        # engine's /v1/run, which BH/PTW never calls) -- pwin only equals
        # base_pwin outright when there is nothing to blend against.
        pwin_val = body.base_pwin if not has_dep else None
        row = fetch_one(cur, """
            INSERT INTO pwin_assessment
                (pursuit_id, scenario, assessment_type, engine_version,
                 calculated_by, base_pwin, pwin, investment,
                 completed_date, aggressiveness_option_id, is_current)
            VALUES (%s,%s,'BLACK_HAT','analyst-entered',%s,%s,%s,%s,%s,%s,TRUE)
         RETURNING id, scenario, assessment_type, pwin, base_pwin,
                   completed_date""",
            (pursuit_id, body.scenario, p.user_id, body.base_pwin,
             pwin_val, body.investment, body.completed_date, opt["id"]))

        cur.execute("""
            UPDATE pursuit
               SET planned_fee_rate = %s, updated_at = now(), updated_by = %s
             WHERE id = %s""", (fee, p.user_id, pursuit_id))

        row["fee"] = fee
        row["black_hat_ptw_complete"] = _recompute_complete(cur, pursuit_id, has_dep)
        row["pwin_needs_recalc"] = has_dep
    return row


@router.post("/pursuits/{pursuit_id}/ptw")
async def submit_ptw(
    pursuit_id: str,
    body: PtwIn,
    p: Principal = Depends(require_role("admin", "capture_manager")),
):
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id, p.user_id) as cur:
        pu = _load_pursuit(cur, pursuit_id, p.user_id, body.scenario)
        _check_completed_date(body.completed_date, pu["bp_start_date"])
        has_dep = pu["depends_on_pursuit_id"] is not None

        cur.execute("""
            UPDATE pwin_assessment SET is_current = FALSE
             WHERE pursuit_id = %s AND scenario = %s AND is_current""",
            (pursuit_id, body.scenario))
        pwin_val = body.base_pwin if not has_dep else None
        row = fetch_one(cur, """
            INSERT INTO pwin_assessment
                (pursuit_id, scenario, assessment_type, engine_version,
                 calculated_by, base_pwin, pwin, investment,
                 completed_date, margin_rate, bid_price, is_current)
            VALUES (%s,%s,'PTW','analyst-entered',%s,%s,%s,%s,%s,%s,%s,TRUE)
         RETURNING id, scenario, assessment_type, pwin, base_pwin,
                   completed_date""",
            (pursuit_id, body.scenario, p.user_id, body.base_pwin,
             pwin_val, body.investment, body.completed_date,
             body.margin_rate, body.bid_price))

        # PTW is a direct override of the fee formula -- no engine call,
        # no fee-config lookup, unlike Black Hat.
        cur.execute("""
            UPDATE pursuit
               SET planned_fee_rate = %s, updated_at = now(), updated_by = %s
             WHERE id = %s""", (body.margin_rate, p.user_id, pursuit_id))

        row["margin_rate"] = body.margin_rate
        row["bid_price"] = body.bid_price
        row["black_hat_ptw_complete"] = _recompute_complete(cur, pursuit_id, has_dep)
        row["pwin_needs_recalc"] = has_dep
    return row


@router.get("/pursuits/{pursuit_id}/bhptw")
async def get_bhptw(
    pursuit_id: str,
    p: Principal = Depends(require_role("admin", "capture_manager")),
):
    """Current BH/PTW state, for prefilling the form when it is reopened."""
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id, p.user_id) as cur:
        pu = fetch_one(cur, f"""
            SELECT p.id, p.depends_on_pursuit_id, d.name AS depends_on_name,
                   d.external_opportunity_id AS depends_on_opp_id
              FROM pursuit p
              LEFT JOIN pursuit d ON d.id = p.depends_on_pursuit_id
             WHERE p.id = %s AND {SCOPED}""", (pursuit_id, p.user_id))
        if not pu:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")

        has_questionnaire = bool(fetch_one(cur, """
            SELECT 1 FROM pwin_assessment
             WHERE pursuit_id = %s AND assessment_type = 'QUESTIONNAIRE'
             LIMIT 1""", (pursuit_id,)))

        rows = fetch_all(cur, """
            SELECT a.scenario, a.assessment_type, a.base_pwin, a.pwin,
                   a.investment, a.completed_date, a.margin_rate,
                   a.bid_price, o.code AS aggressiveness_option_code
              FROM pwin_assessment a
              LEFT JOIN question_option o ON o.id = a.aggressiveness_option_id
             WHERE a.pursuit_id = %s AND a.is_current
               AND a.assessment_type IN ('BLACK_HAT','PTW')""",
            (pursuit_id,))
        by_scenario = {r.pop("scenario"): r for r in rows}

    return {
        "has_questionnaire": has_questionnaire,
        "has_dependency": pu["depends_on_pursuit_id"] is not None,
        "depends_on_name": pu["depends_on_name"],
        "depends_on_opp_id": pu["depends_on_opp_id"],
        "scenarios": {
            "BASE": by_scenario.get("BASE"),
            "DEPENDENT_WON": by_scenario.get("DEPENDENT_WON"),
        },
    }
