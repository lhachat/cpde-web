"""
Core Pre-BH questionnaire Pwin recalculation.

NEVER used by Black Hat / PTW -- ddl/11_assessment_type.sql and
BuildInputJson_/CallPwinEngine_ confirm that path is analyst-entered and
never calls the engine. This module is the Pre-BH path only: compute
tech/mgmt/pp/price/cprice from the pursuit's current questionnaire
answers (scoring.py), resolve fee the same way Black Hat does (fee.py),
build the synthetic "Avg Co N" competitors from the bidder count
(confirmed against BuildInputJson_), and call /v1/run.

Shared by the recalculate endpoint (routers/recalc.py) and write.py's
sole-source-toggle-off path, which needed this integration to exist
before it could stop just flagging staleness -- see that file's comment
on pwin_needs_recalc.
"""
from __future__ import annotations

from fastapi import HTTPException, status
from psycopg.types.json import Jsonb

from . import scoring
from .db import fetch_all, fetch_one
from .engine_client import EngineCredentialError, call_run
from .fee import resolve_fee
from .scoring import ScoringTableError, accumulate, lookup

# BASE_SCORE is read via the `scoring` module reference (scoring.BASE_SCORE),
# not `from .scoring import BASE_SCORE` -- that form binds the value at
# IMPORT time, which would freeze this module onto whatever BASE_SCORE
# happened to be (possibly still None) before the engine fetch ever
# completed. accumulate/lookup are plain functions, not frozen values --
# importing them by name is fine, since they read scoring's live module
# state at CALL time, not at import time.

# Question codes scored by scoring.py, in a fixed order for the
# accumulation list -- order doesn't affect the sum, but keeping it fixed
# makes engine_request reproducible for the same answers.
_SCORED_QUESTIONS = ("TM1A", "TM1B", "TM2", "TM3", "TM4", "TM5", "PP1", "P1")


def apply_dependency_blend(cur, pursuit_id: str, predecessor_id: str) -> None:
    """Recomputes and persists blended_pwin on this pursuit's CURRENT BASE
    row, per the real production spreadsheet's own formula:

        blended = base + (dep_won_pwin - base) * dep_factor

    Confirmed exactly (to reported precision) against migrate_workbook.py's
    own migrated historical data for real AERO/DEMO dependent pursuits --
    e.g. pursuit 1073 (predecessor still open): base=0.199000,
    dep_won=0.134575, dep_factor=predecessor's own live Pwin=0.119825 =>
    blended=0.191280, matching the migrated blended_pwin exactly.

    dep_factor:
      - predecessor decided WON:  1.0 -- confirmed live: pursuit 61's
        migrated blended_pwin equals its own DEPENDENT_WON pwin exactly.
      - predecessor decided LOST: 0.0 -- confirmed live: pursuit 53's
        migrated blended_pwin equals its own base_pwin exactly.
      - predecessor still open: the predecessor's own current BASE Pwin,
        as a live probability estimate (the source formula's XLOOKUP into
        the predecessor's own "Pwin" column -- itself already blended if
        the predecessor has its own dependency; no real chained case
        exists in AERO/DEMO today to re-verify that recursive step
        against, but it follows directly from reading the same column
        this function itself writes).

    No real CANCELLED/NO_BID predecessor has a real dependent in AERO/DEMO
    today (confirmed live), and the source spreadsheet formula has no
    branch for this case -- raises rather than inventing one. If this is
    ever hit for real, it needs an actual decision, not a silent guess.

    Recorded on the BASE row only (blended_pwin's own column comment).
    pwin is set to the SAME blended value there, matching the original
    tool's own convention (migrate_workbook.py: "the Pwin on the main
    sheet is the BLENDED result and Base Pwin is the standalone value") --
    every existing single-number consumer (Dashboard rollups, the
    Pursuits list PWIN column, portfolio summaries) already reads `pwin`
    directly and needs no separate change to pick this up. base_pwin is
    left untouched as the standalone engine/analyst-entered value.

    Called after EITHER scenario's assessment is persisted (BASE or
    DEPENDENT_WON) for a pursuit with a dependency -- both recalc.py's
    own persist path and bhptw.py's Black Hat/PTW submit paths -- since
    either one can change an input this formula reads.
    """
    base_row = fetch_one(cur, """
        SELECT id, base_pwin FROM pwin_assessment
         WHERE pursuit_id = %s AND scenario = 'BASE' AND is_current""",
        (pursuit_id,))
    if not base_row or base_row["base_pwin"] is None:
        return  # nothing to blend yet -- no BASE assessment exists

    base = float(base_row["base_pwin"])

    dep_won_row = fetch_one(cur, """
        SELECT pwin FROM pwin_assessment
         WHERE pursuit_id = %s AND scenario = 'DEPENDENT_WON' AND is_current""",
        (pursuit_id,))
    dep_win = (float(dep_won_row["pwin"])
               if dep_won_row and dep_won_row["pwin"] is not None else base)

    pred = fetch_one(cur, "SELECT outcome FROM pursuit WHERE id = %s",
                     (predecessor_id,))
    outcome = pred["outcome"] if pred else None

    if outcome == "WON":
        dep_factor = 1.0
    elif outcome == "LOST":
        dep_factor = 0.0
    elif outcome in ("CANCELLED", "NO_BID"):
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "This pursuit's depended-on predecessor is "
            f"{outcome} -- the real spreadsheet formula this blend is "
            "based on has no defined behavior for a cancelled/no-bid "
            "predecessor (never occurred in the migrated production data "
            "either), so this needs a real decision rather than an "
            "invented rule. Pwin for this pursuit was not updated.")
    else:
        pred_row = fetch_one(cur, """
            SELECT pwin FROM pwin_assessment
             WHERE pursuit_id = %s AND scenario = 'BASE' AND is_current""",
            (predecessor_id,))
        dep_factor = (float(pred_row["pwin"])
                      if pred_row and pred_row["pwin"] is not None else 0.0)

    blended = base + (dep_win - base) * dep_factor

    cur.execute("""
        UPDATE pwin_assessment SET pwin = %s, blended_pwin = %s
         WHERE id = %s""", (blended, blended, base_row["id"]))


async def recalculate_pwin(cur, pursuit_id: str, user_id,
                           answers_override: dict[str, str] | None = None,
                           persist: bool = True,
                           scenario: str = "BASE") -> dict:
    """Runs inside an already-open tenant_tx. Raises HTTPException on any
    failure -- missing answers, missing fee config, engine unreachable,
    solver failure -- and never writes a partial or invented Pwin.

    answers_override: question code ('TM1A', ..., 'P1') -> answer label
    text. Used by the sandbox's what-if preview, where the analyst has
    edited answers that were never saved -- when supplied, these are
    scored INSTEAD OF the pursuit's real stored answers. Pairs with
    persist=False, which skips the pwin_assessment write entirely: a
    hypothetical scenario must never land in the database.

    scenario: 'BASE' or 'DEPENDENT_WON' -- which stored answer set (and,
    when persisting, which pwin_assessment row) this recalculation reads
    from and writes to. Previously hardcoded to 'BASE' throughout --
    Black Hat/PTW (routers/bhptw.py) has long supported both scenarios
    independently; this was the one remaining place that didn't, which
    meant Recalculate could never reflect a DEPENDENT_WON answer at all,
    regardless of what the UI was showing. is_current is tracked
    per-scenario already (pwin_assessment's own uq_pwin_current
    constraint is on (pursuit_id, scenario)), so parameterizing this
    doesn't change BASE's own behavior at all when scenario='BASE'.

    Returns the pwin_assessment row (persist=True) or a bare
    {pwin, fee, solver_message} dict (persist=False).
    """
    pu = fetch_one(cur, """
        SELECT p.id, p.bidders, p.contract_type_id, p.depends_on_pursuit_id,
               ct.code AS contract_type_code,
               m.code AS market_code,
               ot.type_group, ps.code AS stage_code,
               c.code, c.engine_client_code, c.engine_base_url,
               c.engine_secret_ref
          FROM pursuit p
          LEFT JOIN contract_type ct ON ct.id = p.contract_type_id
          LEFT JOIN market m ON m.id = p.market_id
          LEFT JOIN opportunity_type ot ON ot.id = p.opportunity_type_id
          LEFT JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
          JOIN client c ON c.id = p.client_id
         WHERE p.id = %s""", (pursuit_id,))
    if not pu:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "pursuit not found")
    if scenario == "DEPENDENT_WON" and not pu["depends_on_pursuit_id"]:
        # Same check bhptw.py's _load_pursuit already makes for Black
        # Hat/PTW -- a pursuit with no dependency has no DEPENDENT_WON
        # scenario to recalculate.
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "this pursuit has no dependency; there is no "
                            "dependent-won scenario to recalculate")
    if persist and pu["stage_code"] and pu["stage_code"] != "PRE_BH":
        # Recalculating here would flip is_current back onto a new
        # QUESTIONNAIRE row, silently regressing a Black Hat/PTW pursuit's
        # higher-precision analyst-entered assessment -- exactly what
        # assessment_type exists to distinguish (ddl/11_assessment_type.sql,
        # test_integrity.py's "assessment type matches the pursuit's
        # phase"). Checked here, not just in the router, so write.py's
        # sole-source-toggle-off path gets the same protection. Skipped
        # entirely for a preview: it never writes anything, so there is
        # nothing to regress. Scenario-agnostic on purpose -- the pursuit's
        # PHASE is what determines whether the questionnaire still drives
        # its Pwin, regardless of which scenario's answers this call reads.
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "This pursuit is past Pre-BH -- its Pwin comes from the "
            "Black Hat or PTW analysis, not the questionnaire.")

    if answers_override is not None:
        by_code = {code: {"label_text": lbl, "option_id": None}
                   for code, lbl in answers_override.items() if lbl}
    else:
        # Latest QUESTIONNAIRE assessment's answers for THIS scenario --
        # same "survives a later BH/PTW submission" query used by
        # bootstrap.py/portfolio.py, now scenario-parameterized rather
        # than hardcoded to BASE. numeric_value/boolean_value included
        # alongside option_id/label_text -- not every answer is an
        # option (INVEST_PCT is numeric_value; see the INSERT loop
        # below, which now carries all three shapes forward instead of
        # assuming every question is option-based).
        answers = fetch_all(cur, """
            SELECT q.id AS question_id, q.code, o.id AS option_id,
                   o.label_text, w.numeric_value, w.boolean_value
              FROM pwin_assessment a
              JOIN pwin_answer w ON w.pwin_assessment_id = a.id
              JOIN question q ON q.id = w.question_id
              LEFT JOIN question_option o ON o.id = w.question_option_id
             WHERE a.pursuit_id = %s AND a.scenario = %s
               AND a.assessment_type = 'QUESTIONNAIRE'
               AND a.id = (SELECT id FROM pwin_assessment a2
                            WHERE a2.pursuit_id = a.pursuit_id
                              AND a2.scenario = a.scenario
                              AND a2.assessment_type = 'QUESTIONNAIRE'
                            ORDER BY a2.calculated_at DESC LIMIT 1)""",
            (pursuit_id, scenario))
        by_code = {r["code"]: r for r in answers}
    if not by_code:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "No questionnaire answers found for this pursuit -- complete "
            "the Pwin questionnaire before recalculating.")

    def label(code: str) -> str:
        row = by_code.get(code)
        return row["label_text"] if row else ""

    p1_row = by_code.get("P1")
    p1_label = p1_row["label_text"] if p1_row else None
    p1_option_id = p1_row.get("option_id") if p1_row else None
    if not p1_option_id and p1_label:
        # answers_override never carries an option_id -- resolve it from
        # the label text, same table the questionnaire's own answers
        # already validate against.
        opt = fetch_one(cur, """
            SELECT o.id FROM question_option o
              JOIN question q ON q.id = o.question_id
             WHERE q.code = 'P1' AND o.label_text = %s AND o.is_active""",
            (p1_label,))
        p1_option_id = opt["id"] if opt else None
    if not p1_option_id:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "This pursuit has no P1 (price aggressiveness) answer -- "
            "complete the Pwin questionnaire before recalculating.")

    try:
        deltas = [lookup("tm5", label("TM5"), pu["type_group"] or "")
                 if code == "TM5" else lookup(code, label(code))
                 for code in _SCORED_QUESTIONS]
        total = accumulate(deltas)
        tech = scoring.BASE_SCORE + total["tech"]
        mgmt = scoring.BASE_SCORE + total["mgmt"]
        pp = scoring.BASE_SCORE + total["pp"]
    except ScoringTableError as exc:
        # The scoring table itself couldn't be loaded from the engine --
        # this can't even be attempted, distinct from /v1/run failing
        # below. Keep the message specific rather than folding it into
        # either of the generic engine-failure messages further down.
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc))
    price_delta = total["client_price"]
    cprice_delta = total["comp_price"]
    client_bid_price = 100.0 * (1.0 + price_delta)

    fee = resolve_fee(cur, pu["contract_type_id"], p1_option_id)

    # Derived from the pursuit's own stored P2 answer -- the SAME
    # by_code/label() lookup every other scored question already reads
    # from, not a second path to the same answer. Previously a hardcoded
    # "Best Value" literal here, unconditionally, for every pursuit
    # regardless of its real P2 -- confirmed live: 39 real LPTA pursuits
    # (AERO+DEMO) had their Pwin computed via the engine's Best Value
    # path (solve_dap(), tech/mgmt/pp fully counted) instead of its
    # separate, deliberately different, verified LPTA path
    # (dap_solver.solve_all_daps: dap = bid_price, price alone --
    # test_lpta_dap_equals_bid_price in cda-engine's own suite). Wrong
    # since recalculation was first built (v0.2.0, 2026-08-28) until
    # this fix.
    eval_type = "LPTA" if label("P2") == "LPTA" else "Best Value"

    # Synthetic competitor construction (the fixed 85/85/85 "Avg Co N"
    # rule, confirmed against BuildInputJson_) now happens ENGINE-SIDE:
    # sending bidders alone reproduces the exact same rule, confirmed
    # byte-identical by the engine team (engine v0.29+) and re-verified
    # live this round -- see recalc.py's own migration notes. Not real
    # competitor identity or scores either way (ddl/01_schema.sql
    # NOTE-3); this is still the same synthetic construction, just no
    # longer duplicated locally.
    bidder_count = max(int(pu["bidders"] or 1), 1)

    payload = {
        "uid": str(pu["id"]),
        "tech": tech, "mgmt": mgmt, "pp": pp,
        "client_bid_price": client_bid_price,
        "price_delta": price_delta, "cprice_delta": cprice_delta,
        "fee": float(fee),
        "contract_type": pu["contract_type_code"],
        "p1_answer": p1_label,
        "eval_type": eval_type,
        "market": pu["market_code"],
        "bidders": bidder_count,
    }

    try:
        result = await call_run(pu, payload)
    except EngineCredentialError as exc:
        # A credential/SSM/IAM problem, NOT an engine-side failure --
        # keep the message specific ("could not resolve engine
        # credentials...") rather than folding it into the generic
        # "could not reach the engine" below, which would send someone
        # debugging a real credential expiry down a network/DNS rabbit
        # hole instead.
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc))
    except Exception as exc:
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY,
            f"Could not reach the Pwin engine: {exc}")

    # HTTP 200 with solver_succeeded=false is the engine's own failure
    # convention (confirmed in runtime/api.py) -- treat it as a hard
    # failure, never write a row, never touch the displayed Pwin.
    if not result.get("solver_succeeded"):
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY,
            result.get("solver_message") or
            "the engine could not solve this pursuit")

    pwin = result["pwin"]

    if not persist:
        return {"pwin": pwin, "fee": fee,
                "solver_message": result.get("solver_message", "")}

    cur.execute("""
        UPDATE pwin_assessment SET is_current = FALSE
         WHERE pursuit_id = %s AND scenario = %s AND is_current""",
        (pursuit_id, scenario))
    qv = fetch_one(cur, """
        SELECT id FROM questionnaire_version
         WHERE code = 'pwin' AND is_active""")
    row = fetch_one(cur, """
        INSERT INTO pwin_assessment
            (pursuit_id, questionnaire_version_id, scenario,
             assessment_type, engine_version, calculated_by,
             pwin, base_pwin, score_tech, score_mgmt, score_past_perf,
             price_position, competitor_price_position,
             engine_request, engine_response, is_current)
        VALUES (%s,%s,%s,'QUESTIONNAIRE',%s,%s,
                %s,%s,%s,%s,%s,
                %s,%s,
                %s,%s,TRUE)
     RETURNING id, scenario, pwin, base_pwin, calculated_at""",
        (pursuit_id, qv["id"] if qv else None, scenario,
         "engine:/v1/run", user_id,
         pwin, pwin, tech, mgmt, pp,
         price_delta, cprice_delta,
         Jsonb(payload), Jsonb(result)))

    # pwin_assessment is meant to be a self-contained, immutable snapshot
    # ("Accuracy validation depends on knowing which engine version and
    # questionnaire version produced a given number" -- its own table
    # comment). Without its own pwin_answer rows, this new row has no
    # answers of its own -- the next recalculation (or bootstrap.py's
    # "latest QUESTIONNAIRE" query) would find it and come up empty,
    # because both intentionally stopped falling back to an older row the
    # moment a newer QUESTIONNAIRE row exists.
    #
    # Carries forward EVERY previously-stored answer, not just the 8
    # scored questions (_SCORED_QUESTIONS is what SCORING reads --
    # never was the definition of "every real answer this pursuit has").
    # P2 (Best Value/LPTA) and INVEST_PCT are real, meaningful answers a
    # user set that are not scored via lookup() directly, and were
    # silently dropping off the CURRENT row on every recalculation --
    # confirmed live, twice, on real pursuits, before this fix. Handles
    # all three answer shapes pwin_answer supports (question_option_id /
    # numeric_value / boolean_value), not just the option-based one
    # every _SCORED_QUESTIONS entry happens to be.
    for code, ans_row in by_code.items():
        if not ans_row or not ans_row.get("question_id"):
            continue
        option_id = ans_row.get("option_id")
        numeric_value = ans_row.get("numeric_value")
        boolean_value = ans_row.get("boolean_value")
        if option_id is None and numeric_value is None and boolean_value is None:
            continue
        cur.execute("""
            INSERT INTO pwin_answer
                (pwin_assessment_id, question_id, question_option_id,
                 numeric_value, boolean_value)
            VALUES (%s,%s,%s,%s,%s)""",
            (row["id"], ans_row["question_id"], option_id,
             numeric_value, boolean_value))

    if pu["depends_on_pursuit_id"]:
        apply_dependency_blend(cur, pursuit_id, pu["depends_on_pursuit_id"])
        if scenario == "BASE":
            # The just-inserted row IS the one blend was applied to --
            # reflect the blended pwin in the return value too, not just
            # the DB, so the caller's own toast/UI isn't showing the
            # stale unblended figure for the one case where this
            # response IS the BASE row.
            refreshed = fetch_one(cur, """
                SELECT pwin, blended_pwin FROM pwin_assessment WHERE id = %s""",
                (row["id"],))
            row["pwin"] = refreshed["pwin"]
            row["blended_pwin"] = refreshed["blended_pwin"]

    row["fee"] = fee
    row["solver_message"] = result.get("solver_message", "")
    return row
