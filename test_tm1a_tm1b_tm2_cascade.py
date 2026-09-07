#!/usr/bin/env python3
"""
test_tm1a_tm1b_tm2_cascade.py -- re-verification after the engine fixed
a real ambiguity in the tm1a_tm1b_to_tm2 cascade rule (v0.33): the old
encoding was ambiguous between OR and AND under De Morgan's, and the OR
reading (wrong) would force TM2 whenever EITHER TM1a or TM1b was "No",
instead of only when BOTH are "No"/unanswered.

TWO SEPARATE THINGS, per this round's own task brief -- do not conflate
them:

1. Is the engine's SPEC (the JSON cpde-web fetches and caches) actually
   the corrected v0.33 shape now, not a stale cached v0.32 payload?
   THIS is what section 1 below tests, and it genuinely differs between
   the two versions -- a meaningful RED (old shape) / GREEN (new shape)
   distinction.

2. Does cpde-web's OWN gating logic (index.html's optionsFor(), the
   code that decides whether TM2's dropdown is restricted to "No")
   correctly implement AND, not OR?

REAL FINDING on (2), confirmed by reading the code directly, not
assumed: cpde-web does NOT generically evaluate the engine's `when`
JSON for this rule at all. optionsFor() only pulls the OPTIONS TO
FORCE (rule.force_options.options, e.g. ["No"]) from the fetched spec
-- the CONDITION governing WHEN to force them is a hardcoded JS
expression (`!yA && !yB`, where yA/yB are true only when TM1a/TM1b are
answered with something other than "No") that has ALWAYS implemented
correct AND semantics, independent of whatever ambiguous shape the
engine's `when` clause described. This means section 1's RED/GREEN
distinction does NOT extend to cpde-web's actual rendered behavior --
the frontend was never vulnerable to the engine's v0.32 bug in the
first place, and a test of its behavor cannot be meaningfully made RED
against a v0.32 spec and GREEN against v0.33, because that behavior
never depended on this field. The live end-to-end confirmation of (2)
was therefore done separately, by hand, via Playwright against the
real discriminating pair (TM1a="No", TM1b="On contract today") on a
real AERO pursuit (opp 1046, temporarily modified and reverted) -- see
this round's report for the full transcript. Not re-encoded here as an
automated test, to avoid silently duplicating the SAME hardcoded
condition in a second place (Python) that could drift from the real
JS without either failing loudly.

    python test_tm1a_tm1b_tm2_cascade.py --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

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


# The OLD, ambiguous v0.32 shape -- a negated conjunction that reads
# correctly as AND on paper but is the exact encoding the engine team
# confirmed was actually being evaluated as OR by at least one real
# consumer. Used here only to prove this test can tell the two shapes
# apart -- a real RED case.
V032_SHAPE = {
    "when": {
        "question": "tm1a", "answer_is_not": "No",
        "and_question": "tm1b", "and_answer_is_not": "No",
        "negate": True,
    },
    "force_options": {"question": "tm2", "options": ["No"]},
}

# The CORRECTED v0.33 shape -- explicit "all" with "is_no_or_unanswered"
# per question, unambiguous under any reading.
V033_SHAPE = {
    "when": {
        "all": [
            {"question": "tm1a", "is_no_or_unanswered": True},
            {"question": "tm1b", "is_no_or_unanswered": True},
        ]
    },
    "force_options": {"question": "tm2", "options": ["No"]},
}


def is_v033_shape(rule: dict) -> bool:
    """The one structural fact that actually distinguishes the fixed
    spec from the buggy one: an explicit "all" list of per-question
    is_no_or_unanswered checks, not a negated conjunction with a
    negate flag."""
    when = rule.get("when", {})
    return (
        "all" in when
        and isinstance(when["all"], list)
        and len(when["all"]) == 2
        and all(c.get("is_no_or_unanswered") is True for c in when["all"])
        and "negate" not in when
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    sys.path.insert(0, "api")
    sys.path.insert(0, "/srv")
    from app import scoring, engine_client

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        aero = db.execute("SELECT id, code FROM client WHERE code = 'AERO'").fetchone()
    client_row = {"id": aero["id"], "code": "AERO",
                 "engine_client_code": "cda-internal",
                 "engine_base_url": "http://example.invalid",
                 "engine_secret_ref": "/cda/clients/cda-internal/products/cpde-core/key-value"}

    # ---- proves this test can actually tell the two shapes apart -----
    print("=== 0. sanity: is_v033_shape() actually distinguishes the "
          "two real shapes ===")
    check("the OLD v0.32 shape is correctly recognized as NOT fixed",
          not is_v033_shape(V032_SHAPE), "false positive on the buggy shape")
    check("the NEW v0.33 shape is correctly recognized as fixed",
          is_v033_shape(V033_SHAPE), "false negative on the fixed shape")

    # ---- 1. a MOCKED v0.32 response fails this check (RED) ------------
    print("\n=== 1a. RED: a cached v0.32-shaped spec is correctly "
          "flagged as NOT the fix ===")
    fake_tables = {c: {} for c in
                  ["tm1a", "tm1b", "tm2", "tm3", "tm4", "tm5", "pp1", "p1"]}
    fake_tables["tm5"] = {"dev": {}, "service": {}}
    fake_v032_response = {
        "base_score": 85.0, "tables": fake_tables, "fee_rates": {},
        "questionnaire": {"sections": {}, "questions": [],
                          "cascades": {"tm1a_tm1b_to_tm2": {"rule": V032_SHAPE}}},
    }
    scoring._tables = None
    scoring.BASE_SCORE = None
    scoring._fee_rates = None
    scoring._questionnaire = None
    with patch.object(engine_client, "call_get_scoring_tables",
                      return_value=fake_v032_response):
        asyncio.run(scoring.refresh(client_row))
    rule = scoring.get_questionnaire()["cascades"]["tm1a_tm1b_to_tm2"]["rule"]
    check("a v0.32-shaped cached spec is correctly identified as the "
          "buggy shape, not silently treated as fine",
          not is_v033_shape(rule), "should have failed -- this is the buggy shape")

    # ---- 2. the REAL live spec is confirmed v0.33 (GREEN) --------------
    print("\n=== 1b. GREEN: the REAL live-fetched spec is the corrected "
          "v0.33 shape, not a stale cached v0.32 payload ===")
    scoring._tables = None
    scoring.BASE_SCORE = None
    scoring._fee_rates = None
    scoring._questionnaire = None
    asyncio.run(scoring.refresh(client_row))
    real_rule = scoring.get_questionnaire()["cascades"]["tm1a_tm1b_to_tm2"]["rule"]
    check("the engine's real, live GET /v1/scoring-tables now serves "
          "the corrected all/is_no_or_unanswered shape for "
          "tm1a_tm1b_to_tm2, confirmed by an actual fresh fetch, not "
          "assumed from the version number alone",
          is_v033_shape(real_rule), f"got {real_rule}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("tm1a_tm1b_to_tm2 spec-shape re-verification complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
