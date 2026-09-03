#!/usr/bin/env python3
"""
test_recalc_response_handling.py -- Priority 6 regression: /v1/run
ALWAYS returns HTTP 200 -- solver_succeeded is the real success signal,
not the HTTP status. Confirms recalc.py checks the right one.

Mocked, not live -- this tests recalc.py's OWN logic deterministically
(does a 200-with-solver_succeeded:false response get treated as a
failure?), not the live engine's behavior, which Priority 1/7's tests
already cover separately. No AWS/engine access needed; always runs.

    python test_recalc_response_handling.py --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    sys.path.insert(0, "api")
    from app import recalc as recalc_module, scoring
    from app.db import tenant_tx
    from fastapi import HTTPException

    # This test is about solver_succeeded handling, not scoring values --
    # an empty-but-loaded table is enough (every lookup() call falls
    # through to the all-zero row, same as an unknown answer). Populating
    # it directly, not via a real engine fetch, keeps this test fast and
    # AWS-independent -- scoring.py's OWN fetch/cache behavior has its
    # own dedicated test (test_scoring_migration.py).
    # fee.py's resolve_fee() now reads from scoring's live-fetched fee
    # rate table + p1 table too (fee/competitor migration) -- populate
    # both here for the same AWS-independent reason as _tables/
    # BASE_SCORE above. "p1" needs at least the option label used by
    # the test pursuit's real P1 answer, with a real client_price, or
    # lookup() falls through to the all-zero row and resolve_fee()
    # still works (0.0 delta) -- either way this test isn't about fee
    # VALUES, just about not raising ScoringTableError from an unloaded
    # cache.
    scoring._tables = {}
    scoring.BASE_SCORE = 85.0
    scoring._fee_rates = {"cost plus": 0.065, "time & materials": 0.08,
                          "fixed price": 0.10}

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        aero = db.execute("SELECT id FROM client WHERE code = 'AERO'").fetchone()["id"]
        pursuit = db.execute("""
            SELECT p.id FROM pursuit p
              JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
             WHERE p.client_id = %s AND ps.code = 'PRE_BH' AND p.outcome IS NULL
             ORDER BY p.external_opportunity_id LIMIT 1""", (aero,)).fetchone()

    print("=== Priority 6: /v1/run's real failure signal is "
          "solver_succeeded, never HTTP status alone ===")

    # 1. A 200 response with solver_succeeded: false must be treated as
    # a hard failure -- exactly the bug class this priority warns
    # about ("if anything checks response.status == 200 alone...").
    async def fake_call_run_solver_failed(client_row, payload):
        return {"uid": payload["uid"], "pwin": 0.0, "solver_succeeded": False,
               "solver_message": "DAP solve failed: simulated", "fee": payload["fee"]}

    with patch.object(recalc_module, "call_run", new=fake_call_run_solver_failed):
        raised = None
        try:
            with tenant_tx(aero) as cur:
                asyncio.run(recalc_module.recalculate_pwin(
                    cur, str(pursuit["id"]), None, persist=False))
        except HTTPException as exc:
            raised = exc
    check("a 200 response with solver_succeeded=false raises, rather "
          "than being treated as a successful computation",
          raised is not None, "no exception raised -- treated as success")
    check("the raised error surfaces the engine's own solver_message, "
          "not a generic failure string",
          raised is not None and "simulated" in str(raised.detail),
          f"got {raised.detail if raised else None}")

    # 2. The mirror case -- solver_succeeded: true must NOT be treated
    # as a failure (confirms this isn't just "always raise").
    async def fake_call_run_ok(client_row, payload):
        return {"uid": payload["uid"], "pwin": 0.42, "solver_succeeded": True,
               "solver_message": "", "fee": payload["fee"],
               "competitor_results": []}

    with patch.object(recalc_module, "call_run", new=fake_call_run_ok):
        result = None
        try:
            with tenant_tx(aero) as cur:
                result = asyncio.run(recalc_module.recalculate_pwin(
                    cur, str(pursuit["id"]), None, persist=False))
        except HTTPException as exc:
            check("a genuinely successful (solver_succeeded=true) "
                  "response is NOT treated as a failure", False, str(exc.detail))
        else:
            check("a genuinely successful (solver_succeeded=true) "
                  "response is NOT treated as a failure",
                  result is not None and result.get("pwin") == 0.42,
                  f"got {result}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("recalc.py's response-shape discipline verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
