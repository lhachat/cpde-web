"""
Portfolio read endpoints.

TWO RULES, both enforced here rather than left to each query:

1. Every query runs inside tenant_tx(p.client_id) -- tenant from session.
2. Every pursuit query filters through fn_user_pursuits(user_id) -- the
   canonical scope predicate. Never a hand-written org_node_id filter.

A user-supplied filter (market, phase, year) narrows WITHIN that set. It
never defines it. Conflating the two is how a scope bug gets written.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status

from ..auth import Principal, current_principal
from ..db import fetch_all, fetch_one, tenant_tx
from ..plan_scope import exclude_test_fixtures, resolve_license_boundary_nodes

router = APIRouter(prefix="/api", tags=["portfolio"])

# Applied to every pursuit query. One definition, reused.
SCOPED = "p.id IN (SELECT pursuit_id FROM fn_user_pursuits(%s))"



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


@router.get("/me")
async def me(p: Principal = Depends(current_principal)):
    return {
        "email": p.email,
        "display_name": p.display_name,
        "client_code": p.client_code,
        "roles": list(p.roles),
    }


@router.get("/plan-years")
async def plan_years(
    p: Principal = Depends(current_principal),
    org_node_id: str | None = Query(default=None,
        description="Required when the caller's scope covers more than "
                    "one license-boundary business unit -- see the "
                    "ambiguous response's candidates list."),
):
    """Previously this queried every visible org node at once with no
    way to tell rows from different business units apart -- silently
    correct only by coincidence, for as long as at most one BU actually
    had data. Same disambiguation as PUT /plan-years/{year}, but a read
    degrades gracefully (ambiguous: true, empty years) instead of
    raising, since a caller can reasonably want to know the candidates
    before ever choosing one."""
    with tenant_tx(p.client_id) as cur:
        # UNFILTERED -- the real access-control candidate set, used for
        # validation and single-candidate resolution below. The
        # "candidates" list actually shown to the caller in the
        # ambiguous branch filters through exclude_test_fixtures at that
        # exact point, so a genuinely test-fixture-scoped user's own
        # access is never affected by what a picker chooses to display.
        nodes = resolve_license_boundary_nodes(cur, p.user_id)
        if not nodes:
            return {"ambiguous": False, "org_node_id": None, "years": []}

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
            node_id = match["id"]
        elif len(nodes) == 1:
            node_id = nodes[0]["id"]
        else:
            return {
                "ambiguous": True,
                "candidates": [{"id": str(n["id"]), "code": n["code"],
                               "name": n["name"]}
                              for n in exclude_test_fixtures(nodes)],
                "years": [],
            }

        years = fetch_all(cur, """
            SELECT y.calendar_year, y.escalation_rate, y.revenue_target,
                   y.fee_target, y.budgeted_bp, y.budgeted_investment,
                   y.current_contract_revenue, y.current_contract_fee
              FROM plan_year y
             WHERE y.org_node_id = %s
             ORDER BY y.calendar_year""", (node_id,))
        return {"ambiguous": False, "org_node_id": str(node_id), "years": years}


@router.get("/markets")
async def markets(p: Principal = Depends(current_principal)):
    with tenant_tx(p.client_id) as cur:
        return fetch_all(cur, """
            SELECT id, code, name FROM market
             WHERE is_active ORDER BY display_order, code""")


@router.get("/reference")
async def reference(p: Principal = Depends(current_principal)):
    """Everything the edit form needs to populate a dropdown.

    Codes, not ids. The client never sees or sends a foreign key -- it sends
    a code and the API resolves it. That keeps ids out of the payload and
    makes a smuggled key from another tenant impossible rather than merely
    rejected.
    """
    with tenant_tx(p.client_id) as cur:
        markets = fetch_all(cur, """
            SELECT code, name FROM market
             WHERE is_active ORDER BY display_order, code""")
        opp_types = fetch_all(cur, """
            SELECT code, label, type_group FROM opportunity_type
             WHERE is_active ORDER BY display_order""")
        contracts = fetch_all(cur, """
            SELECT code, label FROM contract_type
             WHERE is_active ORDER BY display_order""")
        stages = fetch_all(cur, """
            SELECT code, label, sequence_no FROM pipeline_stage
             WHERE is_active ORDER BY sequence_no""")
        # Codes for the Black Hat form's price-aggressiveness dropdown.
        # Labels are already duplicated client-side elsewhere in this app
        # (QOPT['P 1']) -- codes are not, and the form needs the code to
        # submit, not the label.
        p1_options = fetch_all(cur, """
            SELECT o.code, o.label_text AS label
              FROM question_option o
              JOIN question q ON q.id = o.question_id
             WHERE q.code = 'P1' AND o.is_active
             ORDER BY o.display_order""")
    return {
        "markets": markets,
        "opportunity_types": opp_types,
        "contract_types": contracts,
        "pipeline_stages": stages,
        "p1_options": p1_options,
        "outcomes": [{"code": "WON", "label": "Won"},
                     {"code": "LOST", "label": "Lost"},
                     {"code": "CANCELLED", "label": "Cancelled"}],
        "bid_decisions": [{"code": "BID", "label": "Bid"},
                          {"code": "NO_BID", "label": "No bid"},
                          {"code": "UNDECIDED", "label": "Undecided"}],
    }


@router.get("/pursuits")
async def pursuits(
    p: Principal = Depends(current_principal),
    market: str | None = Query(default=None),
    stage: str | None = Query(default=None),
    outcome: str | None = Query(default=None),
    due_year: int | None = Query(default=None, ge=1900, le=2200),
    q: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
):
    """User filters narrow within the scoped set; they never widen it."""
    where = [SCOPED, "p.is_active"]
    params: list = [p.user_id]

    if market:
        where.append("m.code = %s")
        params.append(market)
    if stage:
        where.append("ps.code = %s")
        params.append(stage)
    if outcome == "OPEN":
        where.append("p.outcome IS NULL")
    elif outcome:
        where.append("p.outcome = %s")
        params.append(outcome)
    if due_year:
        where.append("EXTRACT(YEAR FROM p.proposal_due_date) = %s")
        params.append(due_year)
    if q:
        where.append("(p.name ILIKE %s OR p.external_opportunity_id ILIKE %s)")
        params += [f"%{q}%", f"%{q}%"]

    clause = " AND ".join(where)

    with tenant_tx(p.client_id) as cur:
        total = fetch_one(cur, f"""
            SELECT count(*) AS n, COALESCE(sum(p.planned_total_award_value),0) AS value,
                   COALESCE(sum(p.planned_total_award_value * a.pwin),0) AS prob
              FROM pursuit p
              LEFT JOIN market m ON m.id = p.market_id
              LEFT JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
              LEFT JOIN pwin_assessment a ON a.pursuit_id = p.id
                    AND a.scenario = 'BASE' AND a.is_current
             WHERE {clause}""", tuple(params))

        rows = fetch_all(cur, f"""
            SELECT p.id, p.external_opportunity_id, p.name,
                   m.code AS market, ct.label AS contract_type,
                   ot.label AS opportunity_type, ps.label AS stage,
                   p.is_sole_source, p.bidders, p.bid_decision, p.outcome,
                   p.planned_total_award_value, p.planned_fee_rate,
                   p.investment_pct, p.planned_investment,
                   p.bp_start_date, p.proposal_due_date,
                   p.contract_award_date, p.period_end_date,
                   a.pwin, a.base_pwin, a.blended_pwin,
                   d.external_opportunity_id AS depends_on_opp_id,
                   d.name AS depends_on_name
              FROM pursuit p
              LEFT JOIN market m ON m.id = p.market_id
              LEFT JOIN contract_type ct ON ct.id = p.contract_type_id
              LEFT JOIN opportunity_type ot ON ot.id = p.opportunity_type_id
              LEFT JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
              LEFT JOIN pwin_assessment a ON a.pursuit_id = p.id
                    AND a.scenario = 'BASE' AND a.is_current
              LEFT JOIN pursuit d ON d.id = p.depends_on_pursuit_id
             WHERE {clause}
             ORDER BY p.planned_total_award_value DESC NULLS LAST
             LIMIT %s OFFSET %s""", tuple(params) + (limit, offset))

    return {"total": total["n"], "total_value": total["value"],
            "total_probabilistic": total["prob"],
            "limit": limit, "offset": offset, "items": rows}


@router.get("/pursuits/{pursuit_id}")
async def pursuit_detail(pursuit_id: str,
                         p: Principal = Depends(current_principal)):
    """The scope predicate applies here too.

    RLS alone would let a user read a pursuit in a business unit they are not
    assigned to, because RLS separates COMPANIES, not business units. An
    endpoint that looks up by id without the scope filter is the classic
    IDOR, and it is invisible in the UI because no link points at it.
    """
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id) as cur:
        row = fetch_one(cur, f"""
            SELECT p.id, p.external_opportunity_id, p.name,
                   m.code AS market, ct.label AS contract_type,
                   ot.label AS opportunity_type, ot.type_group,
                   ps.label AS stage, p.is_sole_source, p.bidders,
                   p.bid_decision, p.outcome, p.outcome_date,
                   p.planned_total_award_value, p.planned_fee_rate,
                   p.investment_pct, p.planned_investment,
                   p.min_bp, p.max_bp,
                   p.bp_start_date, p.proposal_due_date,
                   p.contract_award_date, p.period_end_date,
                   a.pwin, a.base_pwin, a.blended_pwin,
                   d.external_opportunity_id AS depends_on_opp_id,
                   d.name AS depends_on_name,
                   p.updated_at, ub.email AS updated_by_email,
                   ub.display_name AS updated_by_name,
                   p.created_at, cb.email AS created_by_email
              FROM pursuit p
              LEFT JOIN market m ON m.id = p.market_id
              LEFT JOIN contract_type ct ON ct.id = p.contract_type_id
              LEFT JOIN opportunity_type ot ON ot.id = p.opportunity_type_id
              LEFT JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
              LEFT JOIN pwin_assessment a ON a.pursuit_id = p.id
                    AND a.scenario = 'BASE' AND a.is_current
              LEFT JOIN pursuit d ON d.id = p.depends_on_pursuit_id
              LEFT JOIN app_user ub ON ub.id = p.updated_by
              LEFT JOIN app_user cb ON cb.id = p.created_by
             WHERE p.id = %s AND {SCOPED}""", (pursuit_id, p.user_id))
        if not row:
            # Same 404 whether it does not exist or is out of scope.
            # Distinguishing them tells an attacker what exists.
            raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")

        row["years"] = fetch_all(cur, """
            SELECT year_offset, calendar_year, billable_contract_days,
                   probabilistic_revenue, probabilistic_fee, bp_days,
                   bp_required, planned_investment
              FROM pursuit_year_projection
             WHERE pursuit_id = %s ORDER BY year_offset""", (pursuit_id,))

        # The latest QUESTIONNAIRE row specifically, not "the current row" --
        # a later Black Hat/PTW submission moves is_current onto a row with
        # no pwin_answer children, but the questionnaire answers are still
        # real history and must stay readable. See bootstrap.py for the
        # same fix.
        row["answers"] = fetch_all(cur, """
            SELECT q.code, q.section, q.display_order, q.prompt_text,
                   o.code AS answer_code, o.label_text AS answer_label,
                   ans.numeric_value
              FROM pwin_assessment a
              JOIN pwin_answer ans ON ans.pwin_assessment_id = a.id
              JOIN question q ON q.id = ans.question_id
              LEFT JOIN question_option o ON o.id = ans.question_option_id
             WHERE a.pursuit_id = %s AND a.scenario = 'BASE'
               AND a.assessment_type = 'QUESTIONNAIRE'
               AND a.id = (SELECT id FROM pwin_assessment a2
                            WHERE a2.pursuit_id = a.pursuit_id
                              AND a2.scenario = 'BASE'
                              AND a2.assessment_type = 'QUESTIONNAIRE'
                            ORDER BY a2.calculated_at DESC LIMIT 1)
             ORDER BY q.display_order""", (pursuit_id,))
    return row


@router.get("/dashboard")
async def dashboard(p: Principal = Depends(current_principal)):
    """Portfolio rollup.

    Inclusion rule, matching the workbook: count everything marked Bid,
    exclude only cancelled and no-bid. Won work is secured revenue and is
    the largest part of the near years.
    """
    with tenant_tx(p.client_id) as cur:
        by_year = fetch_all(cur, f"""
            SELECT yp.calendar_year AS year,
                   sum(yp.probabilistic_revenue) AS revenue,
                   sum(yp.probabilistic_fee)     AS fee,
                   sum(yp.bp_required)           AS bp,
                   sum(yp.planned_investment)    AS investment
              FROM pursuit_year_projection yp
              JOIN pursuit p ON p.id = yp.pursuit_id
             WHERE {SCOPED}
               AND p.bid_decision = 'BID'
               AND (p.outcome IS NULL OR p.outcome <> 'CANCELLED')
               AND yp.calendar_year IS NOT NULL
             GROUP BY yp.calendar_year ORDER BY yp.calendar_year""",
            (p.user_id,))

        by_market = fetch_all(cur, f"""
            SELECT m.code AS market, count(*) AS pursuits,
                   sum(p.planned_total_award_value) AS value,
                   avg(a.pwin) AS avg_pwin
              FROM pursuit p
              JOIN market m ON m.id = p.market_id
              LEFT JOIN pwin_assessment a ON a.pursuit_id = p.id
                    AND a.scenario = 'BASE' AND a.is_current
             WHERE {SCOPED} AND p.outcome IS NULL
             GROUP BY m.code ORDER BY value DESC NULLS LAST""", (p.user_id,))

        outcomes = fetch_all(cur, f"""
            SELECT EXTRACT(YEAR FROM COALESCE(p.outcome_date,
                                              p.contract_award_date))::int AS year,
                   p.outcome, count(*) AS n,
                   sum(p.planned_total_award_value) AS value
              FROM pursuit p
             WHERE {SCOPED} AND p.outcome IS NOT NULL
             GROUP BY 1, 2 ORDER BY 1, 2""", (p.user_id,))

    return {"by_year": by_year, "by_market": by_market, "outcomes": outcomes}
