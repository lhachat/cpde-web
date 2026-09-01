"""
Write endpoints.

THE RULES, and they are not optional:

1. The tenant comes from the session. It is never a field in the payload.
   A write that accepts client_id from the caller is a cross-tenant
   corruption, not merely a leak.

2. Every write re-checks the scope predicate on the target id. RLS separates
   COMPANIES; it does not separate business units. A PATCH that trusts an id
   because "the UI only shows ids you can see" is the classic IDOR, and on a
   write it corrupts rather than discloses.

3. Only whitelisted fields are writable. Never build an UPDATE from arbitrary
   payload keys -- that is how outcome, client_id or org_node_id end up
   editable by accident.

4. 404, never 403, for an id outside scope. Distinguishing them tells a
   caller what exists.

5. Every write passes user_id into tenant_tx() so the audit trigger can
   attribute it.
"""
from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field, field_validator

from ..auth import Principal, current_principal, require_role
from ..db import fetch_all, fetch_one, tenant_tx
from ..plan_scope import resolve_plan_year_node
from ..recalc import recalculate_pwin

router = APIRouter(prefix="/api", tags=["write"])

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

# Whitelist. Anything not here cannot be written through this endpoint,
# regardless of what the payload contains.
PURSUIT_FIELDS = {
    "name": "name",
    "external_opportunity_id": "external_opportunity_id",
    "bid_decision": "bid_decision",
    "bidders": "bidders",
    "is_sole_source": "is_sole_source",
    "planned_total_award_value": "planned_total_award_value",
    "planned_fee_rate": "planned_fee_rate",
    "proposal_due_date": "proposal_due_date",
    "contract_award_date": "contract_award_date",
    "period_end_date": "period_end_date",
}
# Reference fields resolved from a code to an id before the UPDATE, so the
# caller never supplies a raw foreign key.
PURSUIT_REFS = {
    "market_code": ("market_id", "market", True),            # client-scoped
    "opportunity_type_code": ("opportunity_type_id", "opportunity_type", False),
    "contract_type_code": ("contract_type_id", "contract_type", False),
    "pipeline_stage_code": ("pipeline_stage_id", "pipeline_stage", False),
}

# DERIVED -- never writable through this endpoint:
#   bp_start_date       computed by the staffing engine, backward from
#                       proposal_due_date across the phase durations
#   planned_investment  = investment_pct x award value, and investment_pct
#                       comes from the TM5 answer
#   investment_pct      set by answering the questionnaire, not by typing
#   pwin / scores       engine output
#
# NOT writable here, each needing its own endpoint and its own rules:
#   outcome             closes the pursuit and freezes it; see /outcome
#   client_id           tenancy is never caller-supplied
#   org_node_id         moves a pursuit between scopes
#   depends_on_pursuit_id  changes the two-assessment requirement


class PursuitPatch(BaseModel):
    """Only these fields exist. Anything else in the payload is ignored."""
    # The value of updated_at the client last saw. If the row has moved on,
    # the write is rejected rather than silently overwriting someone else.
    # Optional so a caller can force through deliberately -- but the UI
    # always sends it.
    expected_updated_at: datetime | None = None

    name: str | None = Field(default=None, min_length=1, max_length=300)
    external_opportunity_id: str | None = Field(default=None, min_length=1,
                                                max_length=100)
    market_code: str | None = Field(default=None, max_length=50)
    opportunity_type_code: str | None = Field(default=None, max_length=50)
    contract_type_code: str | None = Field(default=None, max_length=50)
    pipeline_stage_code: str | None = Field(default=None, max_length=50)
    bid_decision: str | None = None
    # The engine's tournament solve does not support more than 6.
    bidders: int | None = Field(default=None, ge=1, le=6)
    is_sole_source: bool | None = None
    planned_total_award_value: Decimal | None = Field(default=None, ge=0)
    planned_fee_rate: Decimal | None = Field(default=None, ge=0, le=1)
    proposal_due_date: date | None = None
    contract_award_date: date | None = None
    period_end_date: date | None = None

    @field_validator("bid_decision")
    @classmethod
    def _bid(cls, v):
        if v is not None and v not in ("BID", "NO_BID", "UNDECIDED"):
            raise ValueError("bid_decision must be BID, NO_BID or UNDECIDED")
        return v


@router.patch("/pursuits/{pursuit_id}")
async def patch_pursuit(
    pursuit_id: str,
    body: PursuitPatch,
    p: Principal = Depends(require_role("admin", "capture_manager")),
):
    pursuit_id = _uuid(pursuit_id)
    fields = body.model_dump(exclude_unset=True, exclude_none=False)
    expected = fields.pop("expected_updated_at", None)
    refs = {k: v for k, v in fields.items() if k in PURSUIT_REFS}
    if ("external_opportunity_id" in fields
            and fields["external_opportunity_id"] is not None
            and not p.has_role("admin")):
        # It is the key CRM import matches on. Changing it makes the next
        # sync create a duplicate rather than update this row.
        raise HTTPException(status.HTTP_403_FORBIDDEN,
                            "only an administrator can change the Opportunity ID")
    fields = {k: v for k, v in fields.items() if k in PURSUIT_FIELDS}
    if not fields and not refs:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "no writable fields")

    with tenant_tx(p.client_id, p.user_id) as cur:
        # Re-check scope on the id. Do NOT rely on the UI having shown it.
        exists = fetch_one(cur, f"""
            SELECT p.id, p.is_sole_source, p.bidders,
                   p.bp_start_date, p.proposal_due_date,
                   p.contract_award_date, p.period_end_date, p.outcome,
                   p.updated_at, u.email AS updated_by_email
              FROM pursuit p
              LEFT JOIN app_user u ON u.id = p.updated_by
             WHERE p.id = %s AND {SCOPED}""",
            (pursuit_id, p.user_id))
        if not exists:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")

        # LOST-UPDATE GUARD. Without this, two people editing the same
        # pursuit means whoever saves second silently erases the first --
        # no error, no warning. This is the whole reason a lock is not
        # needed: the conflict is caught at the write, not prevented by
        # blocking someone out of their own work.
        if expected is not None and exists["updated_at"] is not None:
            if abs((exists["updated_at"] - expected).total_seconds()) > 0.001:
                raise HTTPException(
                    status.HTTP_409_CONFLICT,
                    {"error": "modified",
                     "message": "This pursuit was changed by someone else "
                                "since you opened it.",
                     "changed_by": exists["updated_by_email"],
                     "changed_at": exists["updated_at"].isoformat()})

        # A closed pursuit is history. Editing it would silently rewrite the
        # record the accuracy claims are measured against.
        if exists["outcome"] is not None:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                "pursuit is closed and cannot be edited")

        merged = {**{k: exists[k] for k in
                     ("is_sole_source", "bidders", "bp_start_date",
                      "proposal_due_date", "contract_award_date",
                      "period_end_date")},
                  **fields}

        if merged["is_sole_source"] and (merged["bidders"] or 1) != 1:
            raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                "a sole source pursuit has exactly one bidder")

        seq = [merged["bp_start_date"], merged["proposal_due_date"],
               merged["contract_award_date"], merged["period_end_date"]]
        present = [d for d in seq if d is not None]
        if present != sorted(present):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "dates must run B&P start -> proposal due -> award -> period end")

        # Resolve codes to ids. Market is client-scoped, so a code from
        # another tenant simply does not resolve -- it cannot be smuggled in.
        # Resolve codes to ids. Market is client-scoped, so a code from
        # another tenant simply does not resolve -- it cannot be smuggled in.
        # NOTE: build the column list LOCALLY. Mutating the module-level
        # whitelist per request would race across concurrent requests and
        # could let one caller's column set leak into another's UPDATE.
        columns = {k: PURSUIT_FIELDS[k] for k in fields}
        for key, val in refs.items():
            col, table, scoped = PURSUIT_REFS[key]
            if val is None:
                fields[col] = None
                columns[col] = col
                continue
            sql = (f"SELECT id FROM {table} WHERE code = %s AND is_active"
                   + (" AND client_id = current_tenant()" if scoped else ""))
            found = fetch_one(cur, sql, (val,))
            if not found:
                raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                    f"unknown {key}: {val!r}")
            fields[col] = found["id"]
            columns[col] = col

        sets = ", ".join(f"{columns[k]} = %s" for k in fields)
        # NOTE: column names come from the whitelist, never from the payload.
        # Values are always parameters -- no interpolation of user data.
        params = list(fields.values()) + [p.user_id, pursuit_id, p.user_id]
        row = fetch_one(cur, f"""
            UPDATE pursuit p SET {sets}, updated_at = now(), updated_by = %s
             WHERE p.id = %s AND {SCOPED}
         RETURNING p.id, p.external_opportunity_id, p.name, p.bid_decision,
                   p.bidders, p.is_sole_source, p.planned_total_award_value,
                   p.planned_fee_rate, p.planned_investment,
                   p.bp_start_date, p.proposal_due_date,
                   p.contract_award_date, p.period_end_date,
                   p.updated_at""", tuple(params))
        row["updated_by_email"] = p.email

        # ------------------------------------------------------------
        # Sole source Pwin: a REAL, persisted assessment, not a display
        # trick. Previously this was only overridden in the browser
        # (effectivePwin()), so the stored value never changed and
        # anything reading Pwin directly from the database -- a report,
        # an export, a future integration -- never saw 95%.
        # ------------------------------------------------------------
        sole_changed = "is_sole_source" in fields
        pwin_needs_recalc = False

        if sole_changed and row["is_sole_source"]:
            # Turned ON: 95% is a business rule, not a computed value --
            # no engine call needed, this can be written directly. Update
            # the CURRENT BASE assessment if one exists; otherwise this
            # pursuit has never been assessed at all, and sole source alone
            # is enough to establish one.
            cur.execute("""
                UPDATE pwin_assessment
                   SET pwin = 0.95, is_sole_source_pwin = TRUE,
                       calculated_at = now(), calculated_by = %s
                 WHERE pursuit_id = %s AND scenario = 'BASE' AND is_current""",
                (p.user_id, pursuit_id))
            if cur.rowcount == 0:
                qv = fetch_one(cur, "SELECT id FROM questionnaire_version "
                                    "WHERE code='pwin' AND is_active")
                cur.execute("""
                    INSERT INTO pwin_assessment
                        (pursuit_id, questionnaire_version_id, scenario,
                         assessment_type, engine_version, pwin,
                         is_sole_source_pwin, calculated_by, is_current)
                    VALUES (%s,%s,'BASE','QUESTIONNAIRE','sole-source-rule',
                            0.95, TRUE, %s, TRUE)""",
                    (pursuit_id, qv["id"] if qv else None, p.user_id))
            row["pwin"] = 0.95

        elif sole_changed and not row["is_sole_source"]:
            # Turned OFF: this pursuit is competitive again. Try the real
            # recalculation now that the engine integration exists
            # (recalc.py) -- fall back to the stale-95%-flag only if that
            # attempt itself fails (no questionnaire answers yet, fee
            # config incomplete, engine unreachable, solver failure). The
            # PATCH itself (the sole_source field change) still succeeds
            # either way -- a failed recalculation is not a reason to
            # reject an otherwise-valid edit.
            stale = fetch_one(cur, """
                SELECT pwin FROM pwin_assessment
                 WHERE pursuit_id = %s AND scenario = 'BASE' AND is_current
                   AND is_sole_source_pwin""", (pursuit_id,))
            if stale:
                try:
                    recalced = await recalculate_pwin(cur, pursuit_id, p.user_id)
                    row["pwin"] = recalced["pwin"]
                except HTTPException as exc:
                    pwin_needs_recalc = True
                    row["pwin"] = stale["pwin"]   # still 0.95 until recalculated
                    row["pwin_recalc_error"] = (
                        exc.detail if isinstance(exc.detail, str)
                        else str(exc.detail))

        row["pwin_needs_recalc"] = pwin_needs_recalc

    return row


class BidDecision(BaseModel):
    bid: bool


@router.patch("/pursuits/{pursuit_id}/bid")
async def set_bid(
    pursuit_id: str,
    body: BidDecision,
    p: Principal = Depends(require_role("admin", "capture_manager")),
):
    """The bid toggle. Separate from the general PATCH because it is the one
    write a capture manager makes constantly, and it deserves its own audit
    signature rather than being buried in a field diff."""
    pursuit_id = _uuid(pursuit_id)
    decision = "BID" if body.bid else "NO_BID"
    with tenant_tx(p.client_id, p.user_id) as cur:
        row = fetch_one(cur, f"""
            UPDATE pursuit p
               SET bid_decision = %s, updated_at = now(), updated_by = %s
             WHERE p.id = %s AND {SCOPED}
               -- A won or lost pursuit was, by definition, bid. Allowing a
               -- bid change here would let history contradict itself.
               AND p.outcome IS NULL
               -- No-op guard: without it, re-sending the same decision
               -- stamps updated_at and writes an audit row whose only
               -- content is the timestamp change. Noise in an audit trail
               -- is not harmless -- it hides the real entries.
               AND p.bid_decision IS DISTINCT FROM %s
         RETURNING p.id, p.external_opportunity_id, p.bid_decision""",
            (decision, p.user_id, pursuit_id, p.user_id, decision))
        if row:
            return row
        # Nothing updated: either out of scope / closed, or already set.
        cur_row = fetch_one(cur, f"""
            SELECT p.id, p.external_opportunity_id, p.bid_decision, p.outcome
              FROM pursuit p WHERE p.id = %s AND {SCOPED}""",
            (pursuit_id, p.user_id))
        if not cur_row:
            raise HTTPException(status.HTTP_404_NOT_FOUND,
                                "pursuit not found")
        if cur_row["outcome"] is not None:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                "pursuit is closed")
        cur_row.pop("outcome")
        return cur_row          # already at the requested value


class PlanYearIn(BaseModel):
    escalation_rate: Decimal | None = Field(default=None, ge=0, le=1)
    revenue_target: Decimal | None = Field(default=None, ge=0)
    fee_target: Decimal | None = Field(default=None, ge=0)
    budgeted_bp: Decimal | None = Field(default=None, ge=0)
    budgeted_investment: Decimal | None = Field(default=None, ge=0)
    current_contract_revenue: Decimal | None = Field(default=None, ge=0)
    current_contract_fee: Decimal | None = Field(default=None, ge=0)


@router.put("/plan-years/{calendar_year}")
async def put_plan_year(
    calendar_year: int,
    body: PlanYearIn,
    org_node_id: str | None = Query(default=None,
        description="Required when the caller's scope covers more than "
                    "one license-boundary business unit -- see the 409 "
                    "response's candidates list."),
    p: Principal = Depends(require_role("admin", "executive")),
):
    """Targets are a planning act, not day-to-day editing -- admin or
    executive only. A capture manager should not be able to move the bar
    their own pipeline is measured against."""
    if not 2000 <= calendar_year <= 2100:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "implausible year")
    fields = body.model_dump(exclude_unset=True)
    if not fields:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "no fields supplied")

    with tenant_tx(p.client_id, p.user_id) as cur:
        node_id = resolve_plan_year_node(cur, p.user_id, org_node_id)

        cols = ", ".join(fields)
        ph = ", ".join(["%s"] * len(fields))
        upd = ", ".join(f"{k} = EXCLUDED.{k}" for k in fields)
        row = fetch_one(cur, f"""
            INSERT INTO plan_year (org_node_id, calendar_year, {cols})
            VALUES (%s, %s, {ph})
            ON CONFLICT (org_node_id, calendar_year) DO UPDATE SET {upd}
         RETURNING calendar_year, escalation_rate, revenue_target, fee_target,
                   budgeted_bp, budgeted_investment,
                   current_contract_revenue, current_contract_fee""",
            (node_id, calendar_year, *fields.values()))
    return row


class OutcomeIn(BaseModel):
    outcome: str | None = None          # WON | LOST | CANCELLED | null to reopen
    outcome_date: date | None = None
    # A won or lost pursuit was, by definition, bid. If the pursuit is
    # currently marked no-bid the caller must say explicitly that the bid
    # decision should change too -- we do not rewrite it behind their back.
    also_set_bid: bool = False

    @field_validator("outcome")
    @classmethod
    def _oc(cls, v):
        if v is not None and v not in ("WON", "LOST", "CANCELLED"):
            raise ValueError("outcome must be WON, LOST, CANCELLED or null")
        return v


@router.post("/pursuits/{pursuit_id}/outcome")
async def set_outcome(
    pursuit_id: str,
    body: OutcomeIn,
    p: Principal = Depends(require_role("admin", "capture_manager")),
):
    """Close a pursuit, or reopen it.

    Deliberately its own endpoint rather than a field on PATCH. Setting an
    outcome freezes the record -- every other edit starts returning 409 --
    and the record is what the accuracy figures are measured against. That
    is a decision, not a field change, and it should not be reachable by
    tabbing through a form.
    """
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id, p.user_id) as cur:
        row = fetch_one(cur, f"""
            SELECT p.id, p.external_opportunity_id, p.name, p.outcome,
                   p.bid_decision, p.contract_award_date
              FROM pursuit p WHERE p.id = %s AND {SCOPED}""",
            (pursuit_id, p.user_id))
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")

        # WON or LOST requires the pursuit to have been bid. CANCELLED does
        # not -- a solicitation can be cancelled before anyone decided.
        if body.outcome in ("WON", "LOST") and row["bid_decision"] != "BID":
            if not body.also_set_bid:
                raise HTTPException(status.HTTP_409_CONFLICT, {
                    "error": "bid_required",
                    "message": (f"This pursuit is marked "
                                f"{'no bid' if row['bid_decision']=='NO_BID' else 'undecided'}. "
                                f"You cannot record it as "
                                f"{body.outcome.lower()} without also marking "
                                f"it Bid."),
                    "current_bid_decision": row["bid_decision"],
                    "resolution": "resend with also_set_bid=true, or choose "
                                  "a different outcome"})

        set_bid = (body.outcome in ("WON", "LOST") and body.also_set_bid)
        outcome_date = body.outcome_date or row["contract_award_date"]

        updated = fetch_one(cur, f"""
            UPDATE pursuit p
               SET outcome = %s,
                   outcome_date = %s,
                   bid_decision = CASE WHEN %s THEN 'BID' ELSE p.bid_decision END,
                   updated_at = now(), updated_by = %s
             WHERE p.id = %s AND {SCOPED}
         RETURNING p.id, p.external_opportunity_id, p.name, p.outcome,
                   p.outcome_date, p.bid_decision, p.updated_at""",
            (body.outcome,
             outcome_date if body.outcome else None,
             set_bid, p.user_id, pursuit_id, p.user_id))
        updated["reopened"] = body.outcome is None
    return updated


@router.get("/pursuits/{pursuit_id}/history")
async def pursuit_history(pursuit_id: str,
                          p: Principal = Depends(current_principal),
                          limit: int = 50):
    """Change history for one pursuit.

    Deliberately NOT admin-only, unlike the portfolio-wide audit log. Anyone
    who can see a pursuit should be able to see who last touched it and what
    they changed -- that is accountability, not surveillance. The
    portfolio-wide view is the one that becomes a map of who does what, and
    that stays restricted.
    """
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id) as cur:
        seen = fetch_one(cur, f"""
            SELECT p.id FROM pursuit p WHERE p.id = %s AND {SCOPED}""",
            (pursuit_id, p.user_id))
        if not seen:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")
        rows = fetch_all(cur, """
            SELECT a.occurred_at, a.action, a.table_name, a.changed_fields,
                   u.email AS actor, u.display_name AS actor_name
              FROM audit_log a
              LEFT JOIN app_user u ON u.id = a.user_id
             WHERE a.record_id = %s
             ORDER BY a.occurred_at DESC LIMIT %s""",
            (pursuit_id, min(limit, 200)))
        return _resolve_fk_labels(cur, rows)


# Foreign key columns the audit trigger records as raw ids, and where to
# find something a person can read. The trigger stores the column value --
# it has no idea market_id points at a name -- so resolution happens here.
FK_LOOKUP = {
    "market_id": ("market", "code"),
    "opportunity_type_id": ("opportunity_type", "label"),
    "contract_type_id": ("contract_type", "label"),
    "pipeline_stage_id": ("pipeline_stage", "label"),
    "org_node_id": ("org_node", "name"),
    "depends_on_pursuit_id": ("pursuit", "external_opportunity_id"),
    "updated_by": ("app_user", "display_name"),
    "created_by": ("app_user", "display_name"),
}


def _resolve_fk_labels(cur, rows):
    """Replace raw ids in audit diffs with readable values.

    A history entry reading '9fe630ce-... -> 217b9d24-...' is worse than no
    entry: it is visibly a change but tells the reader nothing. Resolved to
    the CURRENT label -- if a market was later renamed the history shows the
    new name, which is a deliberate trade for readability over archaeology.
    An id that no longer resolves is left as-is rather than dropped.
    """
    wanted: dict[str, set] = {}
    for r in rows:
        for col, diff in (r.get("changed_fields") or {}).items():
            if col not in FK_LOOKUP or not isinstance(diff, dict):
                continue
            for side in ("from", "to"):
                v = diff.get(side)
                if v:
                    wanted.setdefault(col, set()).add(str(v))

    labels: dict[str, dict[str, str]] = {}
    for col, ids in wanted.items():
        table, label_col = FK_LOOKUP[col]
        # id is UUID on most of these tables but SMALLSERIAL on the lookup
        # tables (contract_type, opportunity_type, pipeline_stage). Casting
        # the COLUMN to text, rather than the parameter to a uuid array,
        # works for both without needing to know which type this table uses.
        found = fetch_all(
            cur, f"SELECT id::text AS id, {label_col} AS label "
                 f"FROM {table} WHERE id::text = ANY(%s)", (list(ids),))
        labels[col] = {f["id"]: f["label"] for f in found}

    for r in rows:
        cf = r.get("changed_fields") or {}
        for col, diff in list(cf.items()):
            if col not in labels or not isinstance(diff, dict):
                continue
            for side in ("from", "to"):
                v = diff.get(side)
                if v and str(v) in labels[col]:
                    diff[side] = labels[col][str(v)]
    return rows


# ---------------------------------------------------------------------
# Presence. Advisory: it informs, it never blocks.
# ---------------------------------------------------------------------
PRESENCE_TTL_SECONDS = 120


@router.post("/pursuits/{pursuit_id}/presence")
async def heartbeat(pursuit_id: str,
                    p: Principal = Depends(current_principal)):
    """Register or refresh presence, and report who else is here."""
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id, p.user_id) as cur:
        seen = fetch_one(cur, f"""
            SELECT p.id FROM pursuit p WHERE p.id = %s AND {SCOPED}""",
            (pursuit_id, p.user_id))
        if not seen:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")

        # Sweep expired rows opportunistically -- no scheduler required.
        cur.execute("DELETE FROM pursuit_presence WHERE last_seen < now() - "
                    "make_interval(secs => %s)", (PRESENCE_TTL_SECONDS * 4,))

        cur.execute("""
            INSERT INTO pursuit_presence (pursuit_id, user_id, client_id)
            VALUES (%s, %s, %s)
            ON CONFLICT (pursuit_id, user_id)
            DO UPDATE SET last_seen = now()""",
            (pursuit_id, p.user_id, p.client_id))

        others = fetch_all(cur, """
            SELECT u.email, u.display_name, pr.opened_at, pr.last_seen
              FROM pursuit_presence pr JOIN app_user u ON u.id = pr.user_id
             WHERE pr.pursuit_id = %s AND pr.user_id <> %s
               AND pr.last_seen > now() - make_interval(secs => %s)
             ORDER BY pr.opened_at""",
            (pursuit_id, p.user_id, PRESENCE_TTL_SECONDS))
    return {"others": others, "ttl_seconds": PRESENCE_TTL_SECONDS}


@router.delete("/pursuits/{pursuit_id}/presence")
async def leave(pursuit_id: str, p: Principal = Depends(current_principal)):
    pursuit_id = _uuid(pursuit_id)
    with tenant_tx(p.client_id, p.user_id) as cur:
        cur.execute("DELETE FROM pursuit_presence "
                    "WHERE pursuit_id = %s AND user_id = %s",
                    (pursuit_id, p.user_id))
    return {"ok": True}


@router.get("/changes")
async def changes(since: datetime,
                  p: Principal = Depends(current_principal)):
    """What changed since a timestamp.

    Polled by the UI so it can offer a refresh rather than yanking data out
    from under someone mid-edit. Pipeline data changes a few times a day --
    a 60-second poll is proportionate; a websocket is not.
    """
    with tenant_tx(p.client_id) as cur:
        rows = fetch_all(cur, f"""
            SELECT DISTINCT p.id, p.external_opportunity_id, p.name
              FROM pursuit p
             WHERE {SCOPED} AND p.updated_at > %s""", (p.user_id, since))
        latest = fetch_one(cur, f"""
            SELECT max(p.updated_at) AS latest FROM pursuit p
             WHERE {SCOPED}""", (p.user_id,))
    return {"count": len(rows), "pursuits": rows,
            "latest": latest["latest"] if latest else None}


@router.get("/audit")
async def audit(
    p: Principal = Depends(require_role("admin")),
    table: str | None = None,
    record_id: str | None = None,
    limit: int = 100,
):
    """Recent changes within this tenant. Admin only -- an audit trail that
    everyone can read is a map of who touched what."""
    where = ["1=1"]
    params: list = []
    if table:
        where.append("a.table_name = %s")
        params.append(table)
    if record_id:
        where.append("a.record_id = %s")
        params.append(record_id)
    clause = " AND ".join(where)
    with tenant_tx(p.client_id) as cur:
        return fetch_all(cur, f"""
            SELECT a.occurred_at, a.action, a.table_name, a.record_id,
                   a.changed_fields, u.email AS actor
              FROM audit_log a
              LEFT JOIN app_user u ON u.id = a.user_id
             WHERE {clause}
             ORDER BY a.occurred_at DESC
             LIMIT %s""", tuple(params) + (min(limit, 500),))
