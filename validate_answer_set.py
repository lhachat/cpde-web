#!/usr/bin/env python3
"""
validate_answer_set.py -- batch cross-system Pwin/staffing validation.

Loops over an externally-supplied answer set (the same shape exported
by export_answers.py: externalId/name/amount/clientCode/answers with
the 13 questionnaire fields) and computes a FRESH result for each
pursuit via this codebase's own real, production translation logic --
NOT a direct call to the shared engine. Point: catch translation bugs
in THIS codebase (an answer mapped to the wrong scoring key, a wrong
field fed into the payload, etc.) -- the same class of bug already
found and fixed this session -- not re-verify the engine's own math,
which Excel and the Salesforce plugin are doing independently in
parallel against the SAME answer set.

WHY recalculate_pwin() DIRECTLY, not a re-derived copy of its math:
that function (api/app/recalc.py) IS the real backend code path this
app's own Recalculate button and Sandbox preview call -- building a
second, parallel implementation here to score the same answers would
be exactly the kind of drift risk this project has spent real effort
eliminating elsewhere (see CHANGELOG.md's "Within-repo duplication
consolidated"). Called here with persist=False (the same mode the
Sandbox's own what-if preview uses) -- never writes to the database.

A REAL LIMITATION, not silently worked around: recalculate_pwin()'s
answers_override only overrides the 9 scored/context QUESTION answers
(TM1A..P1, P2) -- pursuit-level context (contract type, market, bidder
count, pursuit type) is read from the matching pursuit's OWN stored row
in cpde-web's database, not from the input file. For THIS run that is
true by construction (this exact answer set was exported FROM that
same database one round ago) -- but a future answer set representing a
hypothetical or downstream-edited scenario could genuinely diverge.
This script does not silently trust one side: for every pursuit it
diffs the input file's pursuitType/contractType/bidderCount/market
against the pursuit's current stored values and flags a mismatch
explicitly in that pursuit's own result rather than silently scoring
against stale context.

STAFFING: this codebase has no function that computes a staffing
result FROM Pwin questionnaire answers -- staffing (pursuit_staffing /
pursuit_staffing_meta) is driven by phase dates and labor-category FTE
curves, entirely independent of the TM/PP/P questionnaire (confirmed
by reading staffing.py: compute_phase_dates/monthly_contributions take
schedule and labor data, never a Pwin answer). So "staffing" here means
the pursuit's real, currently-stored staffing grid -- the exact query
routers/staffing.py's own GET /api/staffing/pursuit/{id} uses -- not a
number derived from this answer set, which would not correspond to
anything the real app actually computes. Reported alongside Pwin per
pursuit so downstream reviewers have both, but this asymmetry is
surfaced explicitly, not glossed over.

Usage (run INSIDE the cpde-api container -- needs app.* modules, a real
DB connection, and a live AWS session for the actual engine call):

    docker exec cpde-api python /tmp/validate_answer_set.py \\
        --input /tmp/aero_validation_dataset.json \\
        --output /tmp/validation_results.json

Re-runnable against any future answer set in the same shape -- nothing
here is specific to this round's 150 AERO pursuits.
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import json
import sys

from app import scoring
from app.db import fetch_all, fetch_one, tenant_tx, unscoped_tx
from app.recalc import recalculate_pwin

# JSON answers-object key -> DB question code. evalType IS a real
# question code (P2) as far as recalculate_pwin()'s answers_override is
# concerned -- confirmed by reading recalc.py: label("P2") is exactly
# how it derives eval_type internally.
ANSWER_KEY_TO_CODE = {
    "tm1a": "TM1A", "tm1b": "TM1B", "tm2": "TM2", "tm3": "TM3",
    "tm4": "TM4", "tm5": "TM5", "pp1": "PP1", "p1": "P1",
    "evalType": "P2",
}


def load_records(path: str) -> list[dict]:
    if path.lower().endswith(".json"):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    with open(path, encoding="utf-8", newline="") as f:
        rows = []
        for row in csv.DictReader(f):
            answers = json.loads(row["Pwin_Answers_JSON__c"])
            rows.append({
                "externalId": row.get("ExternalId__c") or row.get("externalId"),
                "name": row.get("Name") or row.get("name"),
                "amount": float(row["Amount"]) if row.get("Amount") else None,
                "clientCode": row.get("ClientCode__c") or row.get("clientCode"),
                "answers": answers,
            })
        return rows


def find_pursuit(cur, client_code: str, external_id: str) -> dict | None:
    return fetch_one(cur, """
        SELECT p.id, p.bidders, ct.label AS contract_type, m.name AS market,
               ot.label AS pursuit_type
          FROM pursuit p
          JOIN client c ON c.id = p.client_id
          JOIN contract_type ct ON ct.id = p.contract_type_id
          JOIN market m ON m.id = p.market_id
          JOIN opportunity_type ot ON ot.id = p.opportunity_type_id
         WHERE c.code = %s AND p.external_opportunity_id = %s""",
        (client_code, external_id))


def context_mismatches(pursuit: dict, answers: dict) -> list[str]:
    """Every pursuit-level field recalculate_pwin() reads from the DB
    row (never from answers_override) that disagrees with what this
    input file actually says -- see this module's own docstring for
    why that gap matters and is flagged rather than silently ignored."""
    checks = [
        ("pursuitType", pursuit["pursuit_type"], answers.get("pursuitType")),
        ("contractType", pursuit["contract_type"], answers.get("contractType")),
        ("bidderCount", pursuit["bidders"], answers.get("bidderCount")),
        ("market", pursuit["market"], answers.get("market")),
    ]
    return [f"{field}: DB has {db_val!r}, input file has {file_val!r}"
           for field, db_val, file_val in checks if db_val != file_val]


async def validate_one(cur, client_code: str, external_id: str,
                       answers: dict) -> dict:
    pursuit = find_pursuit(cur, client_code, external_id)
    if not pursuit:
        return {"externalId": external_id, "clientCode": client_code,
               "status": "not_found",
               "error": f"no {client_code} pursuit with external_opportunity_id "
                        f"{external_id!r} exists in cpde-web"}

    mismatches = context_mismatches(pursuit, answers)

    override = {ANSWER_KEY_TO_CODE[k]: v for k, v in answers.items()
               if k in ANSWER_KEY_TO_CODE and v}

    try:
        result = await recalculate_pwin(
            cur, str(pursuit["id"]), None,
            answers_override=override, persist=False, scenario="BASE")
    except Exception as exc:  # noqa: BLE001 -- surfaced in the output, not raised
        return {"externalId": external_id, "clientCode": client_code,
               "status": "pwin_error",
               "error": str(getattr(exc, "detail", exc)),
               "context_mismatches": mismatches}

    staffing = fetch_all(cur, """
        SELECT lc.code AS category, ph.code AS phase, s.fte
          FROM pursuit_staffing s
          JOIN labor_category lc ON lc.id = s.labor_category_id
          JOIN phase ph ON ph.id = s.phase_id
         WHERE s.pursuit_id = %s
         ORDER BY lc.display_order, ph.sequence_no""", (pursuit["id"],))

    return {
        "externalId": external_id,
        "clientCode": client_code,
        "status": "ok",
        "pwin": result["pwin"],
        "fee": result.get("fee"),
        "solver_message": result.get("solver_message", ""),
        "context_mismatches": mismatches,
        "staffing_note": "pursuit's real, currently-stored FTE grid -- "
                        "NOT derived from these questionnaire answers; "
                        "see this script's own docstring for why",
        "staffing": staffing,
    }


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True,
                    help="aero_validation_dataset.json or .csv")
    ap.add_argument("--output", required=True)
    ap.add_argument("--client-id", required=True,
                    help="cpde-web client uuid to run under tenant_tx as "
                         "(the pursuits' own client -- e.g. AERO's id)")
    args = ap.parse_args()

    records = load_records(args.input)
    print(f"Loaded {len(records)} records from {args.input}")

    # This script is a standalone process, separate from the running
    # API -- scoring.py's in-process cache (loaded once at API startup)
    # starts empty here, so recalculate_pwin()'s own scoring.lookup()
    # calls would fail with ScoringTableError until a real fetch has
    # happened in THIS process too. Same one-time refresh main.py's own
    # startup hook does, against whichever active client authenticates
    # it -- GET /v1/scoring-tables is identical for every caller
    # (scoring.py's own _any_active_client comment).
    with unscoped_tx() as cur:
        client_row = fetch_one(cur, """
            SELECT * FROM fn_list_active_clients()
             WHERE id = %s""", (args.client_id,))
    if client_row is None:
        print(f"No active client with id {args.client_id}")
        return 1
    await scoring.refresh(client_row)
    print(f"Scoring tables loaded (base_score={scoring.BASE_SCORE})")

    results = []
    with tenant_tx(args.client_id) as cur:
        for rec in records:
            res = await validate_one(cur, rec["clientCode"], rec["externalId"],
                                     rec["answers"])
            results.append(res)
            tag = res["status"]
            print(f"  {rec['clientCode']} {rec['externalId']}: {tag}"
                 + (f" pwin={res['pwin']}" if tag == "ok" else f" -- {res.get('error')}"))
            if res.get("context_mismatches"):
                for m in res["context_mismatches"]:
                    print(f"      MISMATCH: {m}")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, default=str)

    ok = sum(1 for r in results if r["status"] == "ok")
    print(f"\n{ok}/{len(results)} pursuits computed successfully.")
    print(f"Results written to {args.output}")
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
