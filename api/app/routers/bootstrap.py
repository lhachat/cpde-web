"""
Bootstrap: the whole portfolio in one call.

WHY ONE BIG PAYLOAD: the views were built against a single in-memory object
and do their own filtering, sorting and aggregation client-side. Serving that
same shape from the API means the UI changes its data SOURCE without changing
its LOGIC -- far less risk than rewriting eight views at once.

This is a deliberate POC trade, not an architecture. At 150 pursuits the
payload is a few hundred KB and loads in one round trip. At a few thousand it
would need paging and server-side aggregation, and the views would have to be
reworked to match. Revisit before a client with a large pipeline.

Every query still runs under tenant context and the scope predicate.
"""
from __future__ import annotations

from collections import defaultdict

from fastapi import APIRouter, Depends

from ..auth import Principal, current_principal
from ..db import fetch_all, fetch_one, tenant_tx
from .staffing import (_pursuit_filter, apply_cutoff, client_escalation_rates,
                       compute_phase_dates, monthly_contributions)

router = APIRouter(prefix="/api", tags=["bootstrap"])

SCOPED = "p.id IN (SELECT pursuit_id FROM fn_user_pursuits(%s))"


@router.get("/bootstrap")
async def bootstrap(p: Principal = Depends(current_principal)):
    with tenant_tx(p.client_id) as cur:
        client = fetch_one(cur, "SELECT code, name FROM client LIMIT 1")

        plan = fetch_all(cur, """
            SELECT y.calendar_year AS year, y.escalation_rate AS esc,
                   y.revenue_target AS rev_target, y.fee_target,
                   y.budgeted_bp AS bp_budget,
                   y.budgeted_investment AS inv_budget,
                   y.current_contract_revenue AS other_rev,
                   y.current_contract_fee AS other_fee
              FROM plan_year y
             WHERE y.org_node_id IN (SELECT org_node_id
                                       FROM fn_user_visible_org_nodes(%s))
             ORDER BY y.calendar_year""", (p.user_id,))

        pursuits = fetch_all(cur, f"""
            SELECT p.id, p.external_opportunity_id AS opp_id, p.name,
                   m.code AS market, ot.label AS type, ot.type_group,
                   ct.label AS contract, ps.label AS stage,
                   p.is_sole_source AS sole, p.bidders,
                   p.bid_decision, p.outcome, p.outcome_date,
                   p.planned_total_award_value AS value,
                   p.planned_fee_rate AS fee,
                   p.investment_pct AS invpct,
                   p.planned_investment AS inv,
                   p.bp_start_date AS bp_start, p.proposal_due_date AS due,
                   p.contract_award_date AS award, p.period_end_date AS "end",
                   p.cancel_date, p.black_hat_ptw_complete,
                   a.pwin, a.base_pwin, a.blended_pwin, a.assessment_type,
                   d.external_opportunity_id AS dep_opp_id,
                   d.name AS dep_name,
                   p.updated_at, ub.email AS updated_by_email,
                   ub.display_name AS updated_by_name
              FROM pursuit p
              LEFT JOIN app_user ub ON ub.id = p.updated_by
              LEFT JOIN market m ON m.id = p.market_id
              LEFT JOIN opportunity_type ot ON ot.id = p.opportunity_type_id
              LEFT JOIN contract_type ct ON ct.id = p.contract_type_id
              LEFT JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
              LEFT JOIN pwin_assessment a ON a.pursuit_id = p.id
                    AND a.scenario = 'BASE' AND a.is_current
              LEFT JOIN pursuit d ON d.id = p.depends_on_pursuit_id
             WHERE {SCOPED} AND p.is_active
             ORDER BY p.planned_total_award_value DESC NULLS LAST""",
            (p.user_id,))

        years = fetch_all(cur, f"""
            SELECT yp.pursuit_id, yp.year_offset AS y, yp.calendar_year,
                   yp.probabilistic_revenue AS rev, yp.probabilistic_fee AS fee,
                   yp.bp_required AS bp, yp.planned_investment AS inv
              FROM pursuit_year_projection yp
              JOIN pursuit p ON p.id = yp.pursuit_id
             WHERE {SCOPED}
             ORDER BY yp.pursuit_id, yp.year_offset""", (p.user_id,))

        # Questionnaire answers must stay visible even after a Black Hat or
        # PTW submission takes over as the pursuit's current assessment --
        # is_current now tracks where PWIN comes from, not where the
        # questionnaire answers live. So this reads the latest QUESTIONNAIRE
        # row specifically, not "the current row", which may by now be a
        # BLACK_HAT or PTW row with no pwin_answer children at all.
        answers = fetch_all(cur, f"""
            SELECT a.pursuit_id, q.code AS q, o.label_text AS answer
              FROM pwin_assessment a
              JOIN pursuit p ON p.id = a.pursuit_id
              JOIN pwin_answer w ON w.pwin_assessment_id = a.id
              JOIN question q ON q.id = w.question_id
              LEFT JOIN question_option o ON o.id = w.question_option_id
             WHERE {SCOPED} AND a.scenario = 'BASE'
               AND a.assessment_type = 'QUESTIONNAIRE'
               AND a.id = (SELECT id FROM pwin_assessment a2
                            WHERE a2.pursuit_id = a.pursuit_id
                              AND a2.scenario = 'BASE'
                              AND a2.assessment_type = 'QUESTIONNAIRE'
                            ORDER BY a2.calculated_at DESC LIMIT 1)""",
            (p.user_id,))

        staff_rows = fetch_all(cur, f"""
            SELECT p.id AS pursuit_id, p.proposal_due_date, p.cancel_date,
                   ph.code AS phase, lc.code AS category,
                   lc.label AS category_label, lc.display_order, lc.is_static,
                   s.fte, d.weeks
              FROM pursuit_staffing s
              JOIN pursuit p ON p.id = s.pursuit_id
              JOIN phase ph ON ph.id = s.phase_id
              JOIN labor_category lc ON lc.id = s.labor_category_id
              LEFT JOIN pursuit_phase_duration d
                     ON d.pursuit_id = s.pursuit_id AND d.phase_id = s.phase_id
             WHERE {SCOPED} AND {_pursuit_filter(False)}
               AND s.fte > 0 AND p.proposal_due_date IS NOT NULL""",
            (p.user_id,))
        escalation_rates = client_escalation_rates(cur)

    # --- attach year projections, and derive total B&P per pursuit ---
    by_pursuit: dict = defaultdict(list)
    for r in years:
        by_pursuit[r["pursuit_id"]].append(r)

    ans_by_pursuit: dict = defaultdict(dict)
    # The views key answers by the workbook's column labels.
    Q_LABEL = {"TM1A": "TM 1a", "TM1B": "TM 1b", "TM2": "TM 2", "TM3": "TM 3",
               "TM4": "TM 4", "TM5": "TM 5", "PP1": "PP 1", "P1": "P 1",
               "P2": "P 2"}
    for r in answers:
        label = Q_LABEL.get(r["q"])
        if label and r["answer"]:
            ans_by_pursuit[r["pursuit_id"]][label] = r["answer"]

    plan_start = plan[0]["year"] if plan else None
    out = []
    for r in pursuits:
        # Keep BOTH identifiers. `id` is the surrogate the API addresses
        # rows by; `uid`/`opp_id` is what the user sees and what the views
        # key on. Popping the UUID here previously left the frontend unable
        # to build a write URL at all.
        pid = r["id"]
        r["id"] = str(pid)
        yrs = sorted(by_pursuit.get(pid, []), key=lambda x: x["y"])
        # planned_bp_required is not stored on pursuit -- it is the sum of the
        # per-year requirement. Derived here rather than duplicated in schema.
        r["bp"] = float(sum(y["bp"] or 0 for y in yrs))
        r["prob"] = float((r["value"] or 0) * (r["pwin"] or 0))
        r["uid"] = r["opp_id"]
        r["dep"] = r.pop("dep_opp_id")
        r["dep_name"] = r.pop("dep_name")
        r["bid"] = "Bid" if r.pop("bid_decision") == "BID" else "No Bid"
        oc = r.pop("outcome")
        r["outcome"] = {"WON": "Won", "LOST": "Lost",
                        "CANCELLED": "Canceled"}.get(oc) if oc else None
        od = r.pop("outcome_date")
        r["outcome_year"] = (od.year if od else
                             (r["award"].year if r["award"] else None))
        r["award_y"] = r["award"].year if r["award"] else None
        r["end_y"] = r["end"].year if r["end"] else None
        # DENSE five-year array, always offsets 1..5 in order.
        # The migration skips all-zero years, so a pursuit may have only three
        # stored rows. The views index years[0..4] positionally, so a sparse
        # array reads undefined and throws. Pad here rather than making every
        # call site defensive.
        have = {y["y"]: y for y in yrs}
        r["years"] = []
        for off in range(1, 6):
            y = have.get(off)
            cal = (y["calendar_year"] if y and y["calendar_year"]
                   else ((plan_start + off - 1) if plan_start else None))
            r["years"].append({
                "y": off, "cal": cal,
                "rev": float(y["rev"] or 0) if y else 0.0,
                "fee": float(y["fee"] or 0) if y else 0.0,
                "bp": float(y["bp"] or 0) if y else 0.0,
                "inv": float(y["inv"] or 0) if y else 0.0})
        r["answers"] = ans_by_pursuit.get(pid, {})
        out.append(r)

    # --- monthly staffing curve, same phasing as /api/staffing/demand ---
    per: dict = defaultdict(lambda: {"due": None, "cancel": None, "weeks": {},
                                     "fte": defaultdict(dict)})
    cat_labels: dict[str, str] = {}
    cat_order: dict[str, int] = {}
    cat_static: dict[str, bool] = {}
    for r in staff_rows:
        rec = per[r["pursuit_id"]]
        rec["due"] = r["proposal_due_date"]
        rec["cancel"] = r["cancel_date"]
        rec["weeks"][r["phase"]] = float(r["weeks"] or 0)
        rec["fte"][r["category"]][r["phase"]] = float(r["fte"])
        cat_labels[r["category"]] = r["category_label"]
        cat_order[r["category"]] = r["display_order"]
        cat_static[r["category"]] = r["is_static"]

    monthly: dict = defaultdict(lambda: defaultdict(float))
    for rec in per.values():
        if not rec["due"]:
            continue
        dates = apply_cutoff(compute_phase_dates(rec["due"], rec["weeks"]),
                             rec["cancel"])
        for cat, by_phase in rec["fte"].items():
            contributions = monthly_contributions(
                by_phase, dates, is_static=cat_static.get(cat, False),
                client_rates=escalation_rates)
            for month, fte in contributions.items():
                monthly[month][cat] += fte

    months = sorted(monthly)
    cats = sorted(cat_labels, key=lambda c: cat_order.get(c, 999))
    staffing = {
        "months": months,
        "cats": [cat_labels[c] for c in cats],
        "demand": {cat_labels[c]: [round(monthly[m].get(c, 0.0), 2)
                                   for m in months] for c in cats},
        "total": [round(sum(monthly[m].values()), 2) for m in months],
    }

    return {
        "client": client,
        "user": {"email": p.email, "display_name": p.display_name,
                 "roles": list(p.roles)},
        "planning_year": plan_start,
        "targets": plan,
        "pursuits": out,
        "staffing": staffing,
    }
