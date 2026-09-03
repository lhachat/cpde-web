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


async def recalculate_pwin(cur, pursuit_id: str, user_id,
                           answers_override: dict[str, str] | None = None,
                           persist: bool = True) -> dict:
    """Runs inside an already-open tenant_tx. Raises HTTPException on any
    failure -- missing answers, missing fee config, engine unreachable,
    solver failure -- and never writes a partial or invented Pwin.

    answers_override: question code ('TM1A', ..., 'P1') -> answer label
    text. Used by the sandbox's what-if preview, where the analyst has
    edited answers that were never saved -- when supplied, these are
    scored INSTEAD OF the pursuit's real stored answers. Pairs with
    persist=False, which skips the pwin_assessment write entirely: a
    hypothetical scenario must never land in the database.

    Returns the pwin_assessment row (persist=True) or a bare
    {pwin, fee, solver_message} dict (persist=False).
    """
    pu = fetch_one(cur, """
        SELECT p.id, p.bidders, p.contract_type_id,
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
    if persist and pu["stage_code"] and pu["stage_code"] != "PRE_BH":
        # Recalculating here would flip is_current back onto a new
        # QUESTIONNAIRE row, silently regressing a Black Hat/PTW pursuit's
        # higher-precision analyst-entered assessment -- exactly what
        # assessment_type exists to distinguish (ddl/11_assessment_type.sql,
        # test_integrity.py's "assessment type matches the pursuit's
        # phase"). Checked here, not just in the router, so write.py's
        # sole-source-toggle-off path gets the same protection. Skipped
        # entirely for a preview: it never writes anything, so there is
        # nothing to regress.
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "This pursuit is past Pre-BH -- its Pwin comes from the "
            "Black Hat or PTW analysis, not the questionnaire.")

    if answers_override is not None:
        by_code = {code: {"label_text": lbl, "option_id": None}
                   for code, lbl in answers_override.items() if lbl}
    else:
        # Latest QUESTIONNAIRE assessment's answers -- same "survives a
        # later BH/PTW submission" query used by bootstrap.py/portfolio.py.
        answers = fetch_all(cur, """
            SELECT q.id AS question_id, q.code, o.id AS option_id,
                   o.label_text
              FROM pwin_assessment a
              JOIN pwin_answer w ON w.pwin_assessment_id = a.id
              JOIN question q ON q.id = w.question_id
              LEFT JOIN question_option o ON o.id = w.question_option_id
             WHERE a.pursuit_id = %s AND a.scenario = 'BASE'
               AND a.assessment_type = 'QUESTIONNAIRE'
               AND a.id = (SELECT id FROM pwin_assessment a2
                            WHERE a2.pursuit_id = a.pursuit_id
                              AND a2.scenario = 'BASE'
                              AND a2.assessment_type = 'QUESTIONNAIRE'
                            ORDER BY a2.calculated_at DESC LIMIT 1)""",
            (pursuit_id,))
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
        "eval_type": "Best Value",
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
         WHERE pursuit_id = %s AND scenario = 'BASE' AND is_current""",
        (pursuit_id,))
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
        VALUES (%s,%s,'BASE','QUESTIONNAIRE',%s,%s,
                %s,%s,%s,%s,%s,
                %s,%s,
                %s,%s,TRUE)
     RETURNING id, pwin, base_pwin, calculated_at""",
        (pursuit_id, qv["id"] if qv else None, "engine:/v1/run", user_id,
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
    for code in _SCORED_QUESTIONS:
        ans_row = by_code.get(code)
        if not ans_row or not ans_row.get("question_id") or not ans_row.get("option_id"):
            continue
        cur.execute("""
            INSERT INTO pwin_answer
                (pwin_assessment_id, question_id, question_option_id)
            VALUES (%s,%s,%s)""",
            (row["id"], ans_row["question_id"], ans_row["option_id"]))

    row["fee"] = fee
    row["solver_message"] = result.get("solver_message", "")
    return row
