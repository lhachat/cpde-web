#!/usr/bin/env python3
"""
test_scoring_migration.py -- scoring.py migrated from a hardcoded table
to a live fetch of the engine's GET /v1/scoring-tables.

fee.py is NOT covered here -- checked directly, not assumed: fee.py
reads price_delta from the question_option DATABASE table (seeded once
by ddl/13_bhptw_fee.sql), never imports or calls scoring.py at all.
This migration has zero effect on fee.py's behavior; there is no
fee.py call site to migrate. See scoring.py's own docstring for the
same note.

Mocked, not live -- these test scoring.py's OWN logic deterministically
(does it actually call the fetch, does it cache, does a failure surface
loudly). The live end-to-end proof (real engine, known pursuit, real
comparison against the pre-migration stored Pwin) is run separately,
by hand, as this round's Step 3 verification.

    python test_scoring_migration.py --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

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


# A deliberately FAKE scoring table -- distinct numeric values from the
# real ones, so a test passing here proves the live-fetched data is
# actually what's used, not a coincidental match with old hardcoded
# constants left in place as a silent fallback.
FAKE_ENGINE_RESPONSE = {
    "base_score": 77.0,
    "tables": {
        "tm1a": {
            "On Contract Today": {"tech": 111.0, "mgmt": 0.0, "pp": 0.0,
                                  "client_price": 0.0, "comp_price": 0.0},
        },
        "tm1b": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                        "client_price": 0.0, "comp_price": 0.0}},
        "tm2": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                       "client_price": 0.0, "comp_price": 0.0}},
        "tm3": {"N/A": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                        "client_price": 0.0, "comp_price": 0.0}},
        "tm4": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                       "client_price": 0.0, "comp_price": 0.0}},
        "tm5": {
            "dev": {"Low": {"tech": 222.0, "mgmt": 0.0, "pp": 0.0,
                            "client_price": -0.99, "comp_price": 0.0}},
            "service": {"Low": {"tech": 222.0, "mgmt": 0.0, "pp": 0.0,
                                "client_price": 0.0, "comp_price": 0.0}},
        },
        "pp1": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                       "client_price": 0.0, "comp_price": 0.0}},
        "p1": {"Normal Bid": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                              "client_price": 0.0, "comp_price": 0.0}},
    },
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

    # ---- 1. no hardcoded fallback table left in the module -------------
    print("=== 1. no hardcoded table coexists as a silent fallback ===")
    check("scoring.py has no module-level TABLES constant left over from "
          "the pre-migration hardcoded copy",
          not hasattr(scoring, "TABLES"),
          "TABLES still exists -- old hardcoded copy was not removed")
    check("scoring.py has no _TM5_INVEST constant either -- the engine's "
          "live tm5 response already provides the dev/service split "
          "pre-computed, per-row, so this local table is now redundant",
          not hasattr(scoring, "_TM5_INVEST"),
          "_TM5_INVEST still exists")

    # ---- 2. lookup()/accumulate() actually reflect the LIVE fetch ------
    print("\n=== 2. values come from the live fetch, not a hardcoded copy ===")
    scoring._tables = None
    scoring.BASE_SCORE = None
    with patch.object(engine_client, "call_get_scoring_tables",
                      return_value=FAKE_ENGINE_RESPONSE) as mock_fetch:
        asyncio.run(scoring.refresh(client_row))
    check("refresh() actually calls engine_client.call_get_scoring_tables "
          "(the real fetch path), not a value computed some other way",
          mock_fetch.called, "call_get_scoring_tables was never called")
    check("BASE_SCORE reflects the fetched value (77.0), not the old "
          "hardcoded 85.0",
          scoring.BASE_SCORE == 77.0, f"got {scoring.BASE_SCORE}")
    row = scoring.lookup("tm1a", "On Contract Today")
    check("lookup() returns the fetched table's value (tech=111.0), not "
          "the old hardcoded value (tech=10.0) -- proves the fake data "
          "was actually used, not coincidentally matching",
          row["tech"] == 111.0, f"got {row}")
    row_dev = scoring.lookup("tm5", "Low", "Development pursuit")
    row_svc = scoring.lookup("tm5", "Low", "Services pursuit")
    check("tm5's dev/service split comes from the engine's own "
          "pre-computed branches, not a local _TM5_INVEST table",
          row_dev["client_price"] == -0.99 and row_svc["client_price"] == 0.0,
          f"dev={row_dev} svc={row_svc}")

    # ---- 3. a fetch failure surfaces a clear, specific error -----------
    print("\n=== 3. fetch failure fails loudly at the point of use, not "
          "silently ===")
    scoring._tables = None
    scoring.BASE_SCORE = None
    with patch.object(engine_client, "call_get_scoring_tables",
                      side_effect=RuntimeError("simulated: engine unreachable")):
        raised = None
        try:
            asyncio.run(scoring.refresh(client_row))
        except scoring.ScoringTableError as exc:
            raised = exc
    check("a fetch failure during refresh() raises ScoringTableError, "
          "not silently leaving old data in place or swallowing the error",
          raised is not None and "simulated" in str(raised),
          f"got {raised}")
    try:
        scoring.lookup("tm1a", "On Contract Today")
        check("lookup() with no successfully-loaded table raises "
              "ScoringTableError rather than returning a zero row",
              False, "lookup() returned normally instead of raising")
    except scoring.ScoringTableError:
        check("lookup() with no successfully-loaded table raises "
              "ScoringTableError rather than returning a zero row",
              True)

    # And end to end, through recalc.py's real call path:
    from app import recalc as recalc_module
    from app.db import tenant_tx
    from fastapi import HTTPException

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        pursuit = db.execute("""
            SELECT p.id FROM pursuit p
              JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
             WHERE p.client_id = %s AND ps.code = 'PRE_BH' AND p.outcome IS NULL
             ORDER BY p.external_opportunity_id LIMIT 1""", (aero["id"],)).fetchone()

    raised_http = None
    try:
        with tenant_tx(aero["id"]) as cur:
            asyncio.run(recalc_module.recalculate_pwin(
                cur, str(pursuit["id"]), None, persist=False))
    except HTTPException as exc:
        raised_http = exc
    check("recalculate_pwin() fails with a CLEAR, scoring-specific error "
          "when the table can't be loaded -- not a generic 'recalculation "
          "failed' message, and not a silently wrong Pwin",
          raised_http is not None and "scoring table" in str(raised_http.detail).lower(),
          f"got {raised_http.detail if raised_http else None}")

    # ---- 4. lookup() never triggers a fetch itself -- pure cache read --
    print("\n=== 4. repeated lookups after one refresh() never re-fetch ===")
    with patch.object(engine_client, "call_get_scoring_tables",
                      return_value=FAKE_ENGINE_RESPONSE) as mock_fetch2:
        asyncio.run(scoring.refresh(client_row))
        for _ in range(25):
            scoring.lookup("tm1a", "On Contract Today")
            scoring.lookup("tm5", "Low", "Development")
        check("25 lookups after a single refresh() call the engine "
              "exactly once (the refresh itself), never per-lookup",
              mock_fetch2.call_count == 1, f"engine called {mock_fetch2.call_count} times")

    # Leave scoring in a clean, unloaded state for whatever runs next.
    scoring._tables = None
    scoring.BASE_SCORE = None

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Scoring table migration verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
