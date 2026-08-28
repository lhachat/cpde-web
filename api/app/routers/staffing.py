"""
Staffing capacity.

RAW DEMAND, NEVER PWIN-WEIGHTED. Staffing is committed at bid decision --
the B&P cost is incurred whether the pursuit is won or lost. Weighting FTE
by Pwin understates real capacity need and gives a resource manager exactly
the wrong answer. This is a stated business rule, not an implementation
choice; do not "improve" it by weighting.

Only pursuits with bid_decision = 'BID' consume capacity.

CLOSED PURSUITS ARE INCLUDED BY DEFAULT. Won and lost pursuits still
consumed real capture effort, and keeping them makes retrospective analysis
possible -- were the staffing predictions right? Pass open_only=true for a
forward-looking capacity view.

Demand routinely exceeds budget. That is the finding, not a fault: the
pipeline as listed is not affordable, which is the same story B&P tells at
3x budget. Do not silently cap or scale it.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date, timedelta

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status

from ..auth import Principal, current_principal
from ..db import fetch_all, fetch_one, tenant_tx

router = APIRouter(prefix="/api/staffing", tags=["staffing"])

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

# Phases stack BACKWARD from proposal_due_date, in this order.
# Source: cda_engine/models/staffing/staffing_phaser.py _BACKWARD_PHASES.
# Note this is NOT forward from bp_start_date -- an earlier version of this
# file assumed that and produced a curve shifted by the whole capture window.
BACKWARD_PHASES = ("FINAL", "PREPROP", "SOL", "STRAT")
EN_PHASE = "EN"


def _month_window(year: int, month: int) -> tuple[date, date]:
    """[month_start, next_month_start) -- exclusive end, as the engine does."""
    start = date(year, month, 1)
    end = date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)
    return start, end


def compute_phase_dates(proposal_due: date,
                        weeks: dict[str, float]) -> dict[str, tuple[date, date]]:
    """Phase intervals, exclusive-end, matching StaffingPhaser.compute_phase_dates.

    FinalProposal, PreProposal, Solutioning and Strategy stack backward from
    the proposal due date. ENResponse runs forward from it. Each phase spans
    round(weeks * 7) calendar days.
    """
    out: dict[str, tuple[date, date]] = {}
    cursor = proposal_due
    for phase in BACKWARD_PHASES:
        end = cursor
        start = end - timedelta(days=round(float(weeks.get(phase) or 0) * 7))
        out[phase] = (start, end)
        cursor = start
    en_days = round(float(weeks.get(EN_PHASE) or 0) * 7)
    out[EN_PHASE] = (proposal_due, proposal_due + timedelta(days=en_days))
    return out


def apply_cutoff(phase_dates: dict[str, tuple[date, date]],
                 cancel_date: date | None) -> dict[str, tuple[date, date]]:
    """Truncate at a cancellation date; collapse a phase that ends before it starts."""
    if cancel_date is None:
        return dict(phase_dates)
    out = {}
    for phase, (start, end) in phase_dates.items():
        eff = min(end, cancel_date)
        out[phase] = (start, start) if eff <= start else (start, eff)
    return out


def monthly_contributions(fte_by_phase: dict[str, float],
                          phase_dates: dict[str, tuple[date, date]],
                          ) -> dict[str, float]:
    """Pro-rate FTE across calendar months by exact day overlap.

        contribution = phase_fte * overlap_days / phase_total_days

    A collapsed phase (zero days) contributes nothing.

    NOT IMPLEMENTED HERE: escalation. The engine divides variable-category
    FTE by a cumulative escalation factor, on the basis that the same B&P
    budget buys fewer hours as labour costs rise. Static categories are
    exempt. Replicating that needs labor_category.is_static and the
    escalation table, neither of which is in this schema yet -- so these
    figures are UN-ESCALATED and will read slightly low in later years.
    """
    out: dict[str, float] = defaultdict(float)
    for phase, fte in fte_by_phase.items():
        if not fte:
            continue
        span = phase_dates.get(phase)
        if not span:
            continue
        p_start, p_end = span
        total_days = (p_end - p_start).days
        if total_days <= 0:
            continue
        y, m = p_start.year, p_start.month
        while date(y, m, 1) < p_end:
            m_start, m_end = _month_window(y, m)
            overlap = (min(p_end, m_end) - max(p_start, m_start)).days
            if overlap > 0:
                out[f"{y}-{m:02d}"] += fte * overlap / total_days
            m += 1
            if m == 13:
                y, m = y + 1, 1
    return out

def _pursuit_filter(open_only: bool) -> str:
    """Cancelled work never counts. Closed work counts unless excluded."""
    base = ("p.bid_decision = 'BID' "
            "AND (p.outcome IS NULL OR p.outcome <> 'CANCELLED')")
    return base + (" AND p.outcome IS NULL" if open_only else "")


@router.get("/summary")
async def summary(p: Principal = Depends(current_principal),
                  open_only: bool = Query(default=False)):
    """Totals by labor category, and the total effort in FTE-months."""
    with tenant_tx(p.client_id) as cur:
        by_cat = fetch_all(cur, f"""
            SELECT lc.code, lc.label, lc.category_group,
                   sum(s.fte) AS total_fte,
                   count(DISTINCT s.pursuit_id) AS pursuits
              FROM pursuit_staffing s
              JOIN pursuit p ON p.id = s.pursuit_id
              JOIN labor_category lc ON lc.id = s.labor_category_id
             WHERE {SCOPED} AND {_pursuit_filter(open_only)}
               AND s.fte > 0
             GROUP BY lc.code, lc.label, lc.category_group, lc.display_order
             ORDER BY lc.display_order""", (p.user_id,))

        by_phase = fetch_all(cur, f"""
            SELECT ph.code, ph.label, ph.sequence_no,
                   sum(s.fte) AS total_fte,
                   avg(d.weeks) AS avg_weeks
              FROM pursuit_staffing s
              JOIN pursuit p ON p.id = s.pursuit_id
              JOIN phase ph ON ph.id = s.phase_id
              LEFT JOIN pursuit_phase_duration d
                     ON d.pursuit_id = s.pursuit_id AND d.phase_id = s.phase_id
             WHERE {SCOPED} AND {_pursuit_filter(open_only)}
             GROUP BY ph.code, ph.label, ph.sequence_no
             ORDER BY ph.sequence_no""", (p.user_id,))

    return {"by_category": by_cat, "by_phase": by_phase,
            "open_only": open_only,
            "note": "Raw demand. Not Pwin-weighted -- staffing is committed "
                    "at bid decision and costs the same won or lost."}


@router.get("/demand")
async def demand(
    p: Principal = Depends(current_principal),
    start: str | None = Query(default=None, description="YYYY-MM inclusive"),
    end: str | None = Query(default=None, description="YYYY-MM inclusive"),
    open_only: bool = Query(default=False,
        description="Exclude won/lost pursuits. Default false so historical "
                    "effort stays visible for retrospective analysis."),
):
    """FTE demand by month and labor category, plus the peak.

    The peak is the number that matters. Average demand is not a staffing
    plan -- you have to cover the month the work actually lands in.
    """
    with tenant_tx(p.client_id) as cur:
        rows = fetch_all(cur, f"""
            SELECT p.id AS pursuit_id, p.proposal_due_date, p.cancel_date,
                   ph.code AS phase, ph.sequence_no,
                   lc.code AS category, lc.label AS category_label,
                   lc.display_order, s.fte, d.weeks
              FROM pursuit_staffing s
              JOIN pursuit p ON p.id = s.pursuit_id
              JOIN phase ph ON ph.id = s.phase_id
              JOIN labor_category lc ON lc.id = s.labor_category_id
              LEFT JOIN pursuit_phase_duration d
                     ON d.pursuit_id = s.pursuit_id AND d.phase_id = s.phase_id
             WHERE {SCOPED} AND {_pursuit_filter(open_only)}
               AND s.fte > 0 AND p.proposal_due_date IS NOT NULL
             ORDER BY p.id, ph.sequence_no, lc.display_order""", (p.user_id,))

    # Regroup per pursuit: phase durations plus FTE per category per phase.
    per_pursuit: dict = defaultdict(lambda: {"due": None, "cancel": None,
                                             "weeks": {},
                                             "fte": defaultdict(dict)})
    cat_labels: dict[str, str] = {}
    cat_order: dict[str, int] = {}
    for r in rows:
        rec = per_pursuit[r["pursuit_id"]]
        rec["due"] = r["proposal_due_date"]
        rec["cancel"] = r["cancel_date"]
        rec["weeks"][r["phase"]] = float(r["weeks"] or 0)
        rec["fte"][r["category"]][r["phase"]] = float(r["fte"])
        cat_labels[r["category"]] = r["category_label"]
        cat_order[r["category"]] = r["display_order"]

    monthly: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    skipped = 0
    for rec in per_pursuit.values():
        if not rec["due"]:
            skipped += 1      # cannot phase without the anchor date
            continue
        dates = apply_cutoff(compute_phase_dates(rec["due"], rec["weeks"]),
                             rec["cancel"])
        for cat, by_phase in rec["fte"].items():
            for month, fte in monthly_contributions(by_phase, dates).items():
                monthly[month][cat] += fte

    months = sorted(monthly)
    if start:
        months = [m for m in months if m >= start]
    if end:
        months = [m for m in months if m <= end]
    if not months:
        return {"months": [], "categories": [], "demand": {}, "total": [],
                "peak": None}

    cats = sorted(cat_labels, key=lambda c: cat_order.get(c, 999))
    demand_map = {c: [round(monthly[m].get(c, 0.0), 2) for m in months] for c in cats}
    totals = [round(sum(monthly[m].values()), 2) for m in months]
    peak_i = totals.index(max(totals))

    return {
        "months": months,
        "categories": [{"code": c, "label": cat_labels[c]} for c in cats],
        "demand": demand_map,
        "total": totals,
        "peak": {"month": months[peak_i], "fte": totals[peak_i]},
        "pursuits_counted": len(per_pursuit),
        "open_only": open_only,
        "average_fte": round(sum(totals) / len(totals), 2) if totals else 0,
        "note": "Raw FTE for pursuits marked Bid. Not Pwin-weighted.",
        "unphased_pursuits": skipped,
        "phasing": "Phases stack backward from proposal_due_date "
                   "(Final -> PreProp -> Solutioning -> Strategy); EN runs "
                   "forward. Pro-rated by calendar-day overlap. Matches "
                   "staffing_phaser.py. ESCALATION NOT APPLIED -- needs "
                   "labor_category.is_static and the escalation table.",
    }


@router.get("/pursuits")
async def by_pursuit(
    p: Principal = Depends(current_principal),
    open_only: bool = Query(default=False),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
):
    """Per-pursuit staffing totals, heaviest first."""
    with tenant_tx(p.client_id) as cur:
        return fetch_all(cur, f"""
            SELECT p.id, p.external_opportunity_id, p.name,
                   m.code AS market, p.outcome,
                   p.bp_start_date, p.proposal_due_date,
                   sum(s.fte) AS total_fte,
                   count(*) FILTER (WHERE s.fte > 0) AS staffed_cells,
                   sum(d.weeks) AS total_weeks
              FROM pursuit p
              JOIN pursuit_staffing s ON s.pursuit_id = p.id
              LEFT JOIN market m ON m.id = p.market_id
              LEFT JOIN pursuit_phase_duration d
                     ON d.pursuit_id = p.id AND d.phase_id = s.phase_id
             WHERE {SCOPED} AND {_pursuit_filter(open_only)}
             GROUP BY p.id, p.external_opportunity_id, p.name, m.code,
                      p.outcome, p.bp_start_date, p.proposal_due_date
             HAVING sum(s.fte) > 0
             ORDER BY sum(s.fte) DESC
             LIMIT %s OFFSET %s""", (p.user_id, limit, offset))


@router.get("/pursuit/{pursuit_id}")
async def pursuit_staffing(pursuit_id: str,
                           p: Principal = Depends(current_principal)):
    """The FTE grid for one pursuit: categories down, phases across."""
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id) as cur:
        head = fetch_one(cur, f"""
            SELECT p.id, p.external_opportunity_id, p.name, p.bp_start_date
              FROM pursuit p WHERE p.id = %s AND {SCOPED}""",
            (pursuit_id, p.user_id))
        if not head:
            # Same 404 for absent and out-of-scope.
            raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")

        head["phases"] = fetch_all(cur, """
            SELECT ph.code, ph.label, ph.sequence_no, d.weeks
              FROM phase ph
              LEFT JOIN pursuit_phase_duration d
                     ON d.phase_id = ph.id AND d.pursuit_id = %s
             WHERE ph.is_active ORDER BY ph.sequence_no""", (pursuit_id,))

        head["grid"] = fetch_all(cur, """
            SELECT lc.code AS category, lc.label, lc.category_group,
                   ph.code AS phase, s.fte
              FROM pursuit_staffing s
              JOIN labor_category lc ON lc.id = s.labor_category_id
              JOIN phase ph ON ph.id = s.phase_id
             WHERE s.pursuit_id = %s
             ORDER BY lc.display_order, ph.sequence_no""", (pursuit_id,))

        head["meta"] = fetch_one(cur, """
            SELECT effective_bp_pct, calculated_bp, planned_bp_required,
                   engine_version
              FROM pursuit_staffing_meta WHERE pursuit_id = %s""", (pursuit_id,))
    return head
