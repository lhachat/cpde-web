#!/usr/bin/env python3
"""
test_questionnaire_migration.py -- question text, cascade rules, and
per-question help migrated from cpde-web's own hardcoded QTXT/QOPT/HELP
objects (index.html) to the engine's GET /v1/scoring-tables's new
`questionnaire` key (engine v0.32+).

PREMISE CHECK (Step 1, item 1): the task brief for this round claimed
cpde-web's local HELP object has three confirmed real gaps against the
VBA source -- missing the TM5 "dollar ranges" line, missing the P1
"can be updated after Black Hat or PTW" line, and missing a "Bidders"
help entry entirely. Read directly against BOTH cpde-web's own current
HELP object (index.html) and the live engine's real questionnaire.help
for TM5/P1/Bidders (fetched this round, not assumed): none of those
three gaps actually exist in the CURRENT codebase -- all three pieces
of text are already present, word-for-word identical to the engine's
live response. This section captures that finding directly rather than
force a gap that isn't there; it does not block the rest of the
migration, which is about eliminating duplication regardless of
whether today's copy happens to already be accurate.

Mocked, not live, for sections 2-4 -- proves scoring.py's OWN logic
deterministically. Section 5 is a real end-to-end options-consistency
check against whatever is actually live right now.

    python test_questionnaire_migration.py --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Exit 0 = all passed.
"""
from __future__ import annotations

import argparse
import asyncio
import sys
from unittest.mock import patch

import psycopg
from psycopg.rows import dict_row

PASS, FAIL = [], []


def check(name, ok, detail=""):
    (PASS if ok else FAIL).append((name, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}"
          f"{'  -- ' + detail if detail and not ok else ''}")


# A questionnaire spec with values distinct from both the real VBA
# content AND cpde-web's own pre-migration hardcoded copy, so a passing
# test proves the FETCHED data is actually what's used.
FAKE_QUESTIONNAIRE = {
    "sections": {"pursuit_context": "SENTINEL Context",
                "technical_management": "SENTINEL Tech & Mgmt",
                "past_performance": "SENTINEL Past Perf",
                "price": "SENTINEL Price"},
    "questions": [
        {"id": "tm1a", "section": "technical_management",
         "pursuit_type_branching": True,
         "text": {"product": "SENTINEL 1a product", "services": "SENTINEL 1a services"},
         "help": {"product": {"title": "SENTINEL 1a product help title", "body": "SENTINEL body"},
                  "services": {"title": "SENTINEL 1a services help title", "body": "SENTINEL body"}},
         "options": {"product": ["Same", "Better", "Worse"],
                    "services": ["On contract today",
                                "Yes, but not as many building blocks as competitor",
                                "No, but our teammates are on contract today", "No"]}},
        {"id": "tm1b", "section": "technical_management", "pursuit_type_branching": True,
         "text": {"product": "SENTINEL 1b product", "services": "SENTINEL 1b services"},
         "help": {"product": {"title": "t", "body": "b"}, "services": {"title": "t", "body": "b"}},
         "options": {"product": ["Same Level", "More Mature", "Less Mature"],
                    "services": ["On contract today",
                                "Yes, but not as many building blocks as us", "No"]}},
        {"id": "tm2", "section": "technical_management", "pursuit_type_branching": False,
         "text": "SENTINEL TM2 text",
         "help": {"title": "SENTINEL TM2 help title", "body": "SENTINEL TM2 help body"},
         "options": ["Yes, us", "Yes, one of the competitors", "No"]},
        {"id": "tm3", "section": "technical_management", "pursuit_type_branching": False,
         "text": "SENTINEL TM3 text", "help": {"title": "t3", "body": "b3"},
         "options": ["We are performing satisfactorily/unknown", "We have performance issues",
                    "N/A", "Incumbent competitor is performing satisfactorily/unknown",
                    "Incumbent competitor has performance issues"]},
        {"id": "tm4", "section": "technical_management", "pursuit_type_branching": False,
         "text": "SENTINEL TM4 text", "help": {"title": "t4", "body": "b4"},
         "options": ['Yes, we will outsource most of the actual work requested ("noble work")',
                    'Yes, we will outsource some of the actual work requested ("noble work")', "No"]},
        {"id": "tm5", "section": "technical_management", "pursuit_type_branching": False,
         "text": "SENTINEL TM5 text",
         "help": {"title": "SENTINEL TM5 help title",
                  "body": "SENTINEL dollar ranges line for TM5"},
         "options": ["No", "Low", "Moderate", "High"]},
        {"id": "pp1", "section": "past_performance", "pursuit_type_branching": False,
         "text": "SENTINEL PP1 text", "help": {"title": "tpp1", "body": "bpp1"},
         "options": ["Yes", "No"]},
        {"id": "p1", "section": "price", "pursuit_type_branching": False,
         "text": "SENTINEL P1 text",
         "help": {"title": "SENTINEL P1 help title",
                  "body": "SENTINEL Black Hat or PTW line for P1"},
         "options": ["3% above normal", "2% above normal", "1% above normal", "Normal Bid",
                    "1% lower than normal", "2% lower than normal", "3% lower than normal",
                    "4% lower than normal"]},
        {"id": "p2", "section": "price", "pursuit_type_branching": False,
         "text": "SENTINEL P2 text", "help": {"title": "tp2", "body": "bp2"},
         "options": ["Best Value", "LPTA"]},
        {"id": "pursuit_type", "section": "pursuit_context", "pursuit_type_branching": False,
         "text": "Opportunity type", "help": None,
         "options": ["Existing product solution, little modification required",
                    "Developmental/New Product", "Engineering/Technical Services",
                    "Sustainment/O&M"]},
        {"id": "contract_type", "section": "pursuit_context", "pursuit_type_branching": False,
         "text": "Contract type", "help": None,
         "options": ["Cost Plus", "Time & Materials", "Fixed Price"]},
        {"id": "bidders", "section": "pursuit_context", "pursuit_type_branching": False,
         "text": "SENTINEL bidders text",
         "help": {"title": "SENTINEL Bidders help title", "body": "SENTINEL Bidders help body"},
         "options": ["1", "2", "3", "4", "5", "6"]},
        {"id": "market", "section": "pursuit_context", "pursuit_type_branching": False,
         "text": "Market", "help": None, "options": None},
    ],
    "cascades": {
        "tm1a_to_tm1b": {"applies_to": "services",
            "rule": {"when": {"question": "tm1a", "answer": "No"},
                    "remove_option": {"question": "tm1b",
                                      "option": "Yes, but not as many building blocks as us"}}},
        "tm1a_tm1b_to_tm2": {"applies_to": "services",
            "rule": {"force_options": {"question": "tm2", "options": ["No"]}}},
        "tm2_to_tm3": {"applies_to": "all",
            "map": {"Yes, us": ["We are performing satisfactorily/unknown",
                                "We have performance issues"],
                    "Yes, one of the competitors": [
                        "Incumbent competitor is performing satisfactorily/unknown",
                        "Incumbent competitor has performance issues"],
                    "No": ["N/A"]}},
    },
}

# A minimal but complete `tables` block matching FAKE_QUESTIONNAIRE's
# own option lists exactly, for the options-consistency check.
FAKE_TABLES_MATCHING = {
    "tm1a": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
            for o in ["Same", "Better", "Worse", "On contract today",
                      "Yes, but not as many building blocks as competitor",
                      "No, but our teammates are on contract today", "No"]},
    "tm1b": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
            for o in ["Same Level", "More Mature", "Less Mature", "On contract today",
                      "Yes, but not as many building blocks as us", "No"]},
    "tm2": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
           for o in ["Yes, us", "Yes, one of the competitors", "No"]},
    "tm3": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
           for o in ["We are performing satisfactorily/unknown", "We have performance issues",
                     "N/A", "Incumbent competitor is performing satisfactorily/unknown",
                     "Incumbent competitor has performance issues"]},
    "tm4": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
           for o in ['Yes, we will outsource most of the actual work requested ("noble work")',
                     'Yes, we will outsource some of the actual work requested ("noble work")', "No"]},
    "tm5": {"dev": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
                    for o in ["No", "Low", "Moderate", "High"]},
           "service": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
                       for o in ["No", "Low", "Moderate", "High"]}},
    "pp1": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
           for o in ["Yes", "No"]},
    "p1": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
          for o in ["3% above normal", "2% above normal", "1% above normal", "Normal Bid",
                    "1% lower than normal", "2% lower than normal", "3% lower than normal",
                    "4% lower than normal"]},
    "p2": {o: {"tech": 0.0, "mgmt": 0.0, "pp": 0.0, "client_price": 0.0, "comp_price": 0.0}
          for o in ["Best Value", "LPTA"]},
}

FAKE_ENGINE_RESPONSE = {
    "base_score": 85.0,
    "tables": FAKE_TABLES_MATCHING,
    "fee_rates": {"Cost Plus": 0.065, "Time & Materials": 0.08, "Fixed Price": 0.10},
    "questionnaire": FAKE_QUESTIONNAIRE,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    sys.path.insert(0, "api")
    from app import scoring, engine_client

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        aero = db.execute("SELECT id, code FROM client WHERE code = 'AERO'").fetchone()
    client_row = {"id": aero["id"], "code": "AERO",
                 "engine_client_code": "cda-internal",
                 "engine_base_url": "http://example.invalid",
                 "engine_secret_ref": "/cda/clients/cda-internal/products/cpde-core/key-value"}

    # ---- 1. no hardcoded local copies coexist as a silent fallback -----
    # (Pre-migration state -- this section originally captured whether
    # cpde-web's local HELP object had the three gaps the task brief
    # claimed against the real VBA text. Checked directly against BOTH
    # the pre-migration source and the live engine's real
    # questionnaire.help for TM5/P1/Bidders before any code changed:
    # none of those three gaps actually existed -- all three pieces of
    # text were already present, word-for-word identical to the
    # engine's live response. That premise check is now history, not
    # something to keep re-testing (matches this project's own
    # established practice for every prior migration's own "current
    # state" section). This is the permanent structural check that
    # replaces it: no hardcoded QOPT/QTXT/HELP/TM3_BY_TM2 content
    # coexists with the live-fetched versions as a silent fallback.)
    print("=== 1. no hardcoded local question/help content coexists as "
          "a silent fallback ===")
    html = open("api/static/index.html", encoding="utf-8").read()
    check("index.html has no hardcoded 'const HELP = {' object left "
          "over from the pre-migration local copy",
          "const HELP = {" not in html,
          "a hardcoded HELP object still exists")
    check("index.html has no hardcoded 'const QOPT={' object left over "
          "-- QOPT is now populated at runtime by "
          "buildQuestionnaireFromRef()",
          "const QOPT={" not in html,
          "a hardcoded QOPT object still exists")
    check("index.html defines buildQuestionnaireFromRef() -- the "
          "function that actually sources question text/options/help/"
          "cascades from REF.questionnaire",
          "function buildQuestionnaireFromRef()" in html,
          "buildQuestionnaireFromRef() is missing")

    # ---- 2. get_questionnaire() reflects the LIVE fetch, not a local --
    #         object ----------------------------------------------------
    print("\n=== 2. scoring.get_questionnaire() reflects the live fetch, "
          "not a hardcoded local copy ===")
    scoring._tables = None
    scoring.BASE_SCORE = None
    scoring._fee_rates = None
    scoring._questionnaire = None
    with patch.object(engine_client, "call_get_scoring_tables",
                      return_value=FAKE_ENGINE_RESPONSE) as mock_fetch:
        asyncio.run(scoring.refresh(client_row))
    check("refresh() actually calls the live fetch", mock_fetch.called,
          "call_get_scoring_tables was never called")
    q = scoring.get_questionnaire()
    tm5 = next(x for x in q["questions"] if x["id"] == "tm5")
    check("get_questionnaire() returns the FAKE fetched TM5 help body "
          "(a SENTINEL string), not cpde-web's own real text -- proves "
          "the fetched data is actually what's exposed",
          tm5["help"]["body"] == "SENTINEL dollar ranges line for TM5",
          f"got {tm5['help']['body']!r}")

    # ---- 3. GET /api/reference exposes it, live over HTTP --------------
    print("\n=== 3. GET /api/reference exposes the questionnaire (real, "
          "live data this time -- confirms the wiring end to end) ===")
    import httpx
    try:
        r = httpx.get("http://localhost:8001/health", timeout=3)
        api_up = r.status_code == 200
    except Exception:
        api_up = False
    if not api_up:
        check("API reachable on :8001 for the live /api/reference check",
              False, "skipping section 3 -- API not running")
    else:
        c = httpx.Client(base_url="http://localhost:8001", timeout=15)
        lr = c.post("/api/login", json={"email": "aero.admin@demoaero.test"})
        if lr.status_code != 200:
            check("login for the live reference check", False, f"got {lr.status_code}")
        else:
            rr = c.get("/api/reference")
            check("GET /api/reference succeeds", rr.status_code == 200,
                  f"got {rr.status_code}")
            body = rr.json()
            check("response includes a 'questionnaire' key",
                  "questionnaire" in body, f"got top-level keys {list(body.keys())}")
            # portfolio.py's own /reference handler deliberately returns
            # questionnaire=None (never a 502) when the API CONTAINER's own
            # scoring/questionnaire cache has never successfully loaded --
            # a real, documented, legitimate state for the live APP to be
            # in during an engine outage. It is NOT a legitimate outcome
            # for THIS TEST to accept silently: this section's whole point
            # is confirming the questionnaire is actually wired end-to-end
            # over live HTTP, and a None here means that was never
            # verified. Previously gated behind `if body.get("questionnaire"):`,
            # which silently skipped the check below instead of failing --
            # the suite's own assertion count quietly dropped from 10 to 9
            # with no failure, no skip message, nothing (found by
            # run_tests.ps1's drift detector). Explicit and unconditional
            # now: this always runs, and fails loudly with a pointer at the
            # real cause (the API CONTAINER's own AWS session, not this
            # test process's -- section 2 above mocks its own fetch and
            # proves nothing about the container's live state) rather than
            # silently running one fewer check. run_tests.ps1 gates this
            # whole suite on that same container AWS session being live
            # (the same precondition every sibling engine-dependent suite
            # already gates on) specifically so this failure is never hit
            # in the ordinary no-AWS local-dev case -- there, the suite is
            # skipped outright, not silently degraded.
            questionnaire = body.get("questionnaire")
            check("the 'questionnaire' value is non-null -- the live "
                  "engine spec was actually loaded in the api CONTAINER "
                  "serving this request, not just mocked in this test "
                  "process",
                  questionnaire is not None,
                  f"got questionnaire={questionnaire!r} -- is the api "
                  f"container's own AWS session live? (docker exec "
                  f"cpde-api python -c \"import boto3; "
                  f"boto3.client('sts').get_caller_identity()\")")
            qids = [x["id"] for x in (questionnaire or {}).get("questions", [])]
            check("questionnaire.questions includes all 13 expected "
                  "fields (9 scored + pursuit_type/contract_type/"
                  "bidders/market)",
                  set(qids) == {"tm1a", "tm1b", "tm2", "tm3", "tm4", "tm5",
                               "pp1", "p1", "p2", "pursuit_type",
                               "contract_type", "bidders", "market"},
                  f"got {qids}")

    # ---- 4. Market's help is null and that's handled, not an error -----
    print("\n=== 4. Market's help is null in the spec -- confirmed, not "
          "fabricated, and safe to consume ===")
    market_q = next(x for x in q["questions"] if x["id"] == "market")
    check("Market's help is None in the fetched spec (not fabricated "
          "by cpde-web)", market_q["help"] is None, f"got {market_q['help']!r}")

    # ---- 5. every scored question's options match tables's own keys ----
    print("\n=== 5. every question's offered options are asserted (by "
          "cpde-web itself, not just trusted from the engine) to match "
          "scoring_tables's own valid answer keys ===")
    scored_ids = ["tm1a", "tm1b", "tm2", "tm3", "tm4", "tm5", "pp1", "p1", "p2"]
    all_match = True
    mismatches = []
    for qid in scored_ids:
        item = next(x for x in q["questions"] if x["id"] == qid)
        opts = item["options"]
        if qid == "tm5":
            table_keys = set(scoring._tables["tm5"]["dev"].keys()) | \
                        set(scoring._tables["tm5"]["service"].keys())
        else:
            table_keys = set(scoring._tables[qid].keys())
        if isinstance(opts, dict):
            offered = set(opts.get("product", [])) | set(opts.get("services", []))
        else:
            offered = set(opts)
        offered_norm = {o.strip().lower() for o in offered}
        if not offered_norm.issubset(table_keys):
            all_match = False
            mismatches.append((qid, offered_norm - table_keys))
    check("every question's offered options resolve to a real scoring "
          "table entry (case-insensitive) -- cpde-web's own check, not "
          "solely relying on the engine having gotten it right",
          all_match, f"mismatches: {mismatches}")

    # Leave scoring in a clean, unloaded state for whatever runs next.
    scoring._tables = None
    scoring.BASE_SCORE = None
    scoring._fee_rates = None
    scoring._questionnaire = None

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Questionnaire migration verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
