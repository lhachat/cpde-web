#!/usr/bin/env python3
"""
test_fee_competitor_migration.py -- fee.py's rate lookup migrated from
three DB-seeded copies to the engine's live GET /v1/scoring-tables
(fee_rates + the already-fetched p1 table), and recalc.py's hand-built
"Avg Co N" competitors array migrated to sending bidders: N and letting
the engine construct them.

Confirmed before writing this (not assumed): fee.py currently reads
BOTH contract_type.base_fee_rate AND question_option.price_delta from
the database (ddl/13_bhptw_fee.sql), a THIRD copy of P1 data on top of
the old hardcoded scoring.py table (already migrated) and the live
p1 table scoring.py now fetches. This file locks in the migration away
from all of that.

Mocked, not live -- these test the code's OWN logic deterministically.
The live end-to-end proof (real engine, known pursuit and fee case,
identical results) is run separately, by hand, as this round's Step 3.

    python test_fee_competitor_migration.py --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

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


FAKE_ENGINE_RESPONSE = {
    "base_score": 85.0,
    "fee_rates": {"Cost Plus": 0.999, "Time & Materials": 0.888, "Fixed Price": 0.777},
    "tables": {
        "tm1a": {"On Contract Today": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                                       "client_price": 0.0, "comp_price": 0.0}},
        "tm1b": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                        "client_price": 0.0, "comp_price": 0.0}},
        "tm2": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                       "client_price": 0.0, "comp_price": 0.0}},
        "tm3": {"N/A": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                        "client_price": 0.0, "comp_price": 0.0}},
        "tm4": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                       "client_price": 0.0, "comp_price": 0.0}},
        "tm5": {"dev": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                               "client_price": 0.0, "comp_price": 0.0}},
               "service": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                                  "client_price": 0.0, "comp_price": 0.0}}},
        "pp1": {"No": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                       "client_price": 0.0, "comp_price": 0.0}},
        "p1": {"1% Above Normal": {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
                                   "client_price": 0.444, "comp_price": 0.0}},
    },
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    sys.path.insert(0, "api")
    from app import scoring, engine_client, fee as fee_module
    from app.db import tenant_tx

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        aero = db.execute("SELECT id, code FROM client WHERE code = 'AERO'").fetchone()
        ct = db.execute("SELECT id, code, label, base_fee_rate FROM contract_type "
                        "WHERE code = 'COST_PLUS'").fetchone()
        p1 = db.execute("""
            SELECT o.id, o.label_text, o.price_delta FROM question_option o
              JOIN question q ON q.id = o.question_id
             WHERE q.code = 'P1' AND o.label_text = '1% above normal'""").fetchone()
    client_row = {"id": aero["id"], "code": "AERO",
                 "engine_client_code": "cda-internal",
                 "engine_base_url": "http://example.invalid",
                 "engine_secret_ref": "/cda/clients/cda-internal/products/cpde-core/key-value"}

    # ---- 1. fee.py genuinely depends on scoring.py now -----------------
    # (Pre-migration state -- fee.py read contract_type.base_fee_rate +
    # question_option.price_delta directly from the DB, confirmed live
    # before any code changed: 0.065 + 0.01 = 0.075 -- is now history,
    # not something to keep re-testing. This is the permanent guard
    # that replaces it: fee.py must actually route through scoring.py,
    # not silently keep a DB fallback alongside it.)
    print("=== 1. fee.py is wired to scoring.py, not a DB fallback ===")
    check("fee.py imports scoring.py -- the live-fetched table is its "
          "real dependency now, not an optional extra",
          hasattr(fee_module, "scoring"),
          "fee_module has no scoring reference at all")

    # ---- 2. after migration: rate comes from the LIVE fetch, not DB ---
    print("\n=== 2. rate lookup is sourced from the live fetch, not the "
          "DB columns ===")
    scoring._tables = None
    scoring.BASE_SCORE = None
    scoring._fee_rates = None
    with patch.object(engine_client, "call_get_scoring_tables",
                      return_value=FAKE_ENGINE_RESPONSE) as mock_fetch:
        asyncio.run(scoring.refresh(client_row))
    check("refresh() actually calls the live fetch", mock_fetch.called,
          "call_get_scoring_tables was never called")
    with tenant_tx(aero["id"]) as cur:
        fee_after = float(fee_module.resolve_fee(cur, ct["id"], p1["id"]))
    check("fee.py's result now reflects the FAKE fetched values "
          "(0.999 + 0.444 = 1.443), not the real DB-seeded ones "
          "(0.065 + 0.01) -- proves the live data is actually used",
          abs(fee_after - 1.443) < 1e-9,
          f"got {fee_after}, expected 1.443 (DB-seeded would give "
          f"{ct['base_fee_rate'] + p1['price_delta']})")

    # ---- 3/4. outgoing request sends bidders: N, no competitors array -
    # (Pre-migration state -- recalc.py hand-built a "competitors" array
    # with fixed 85/85/85 scores, confirmed live before any code
    # changed -- is now history. This is the permanent post-migration
    # check: the real outgoing request shape, not just that a result
    # comes back.)
    print("\n=== 3/4. outgoing request sends bidders: N, never a "
          "hand-built competitors array ===")
    from app import recalc as recalc_module

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        pursuit = db.execute("""
            SELECT p.id, p.bidders FROM pursuit p
              JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
             WHERE p.client_id = %s AND ps.code = 'PRE_BH' AND p.outcome IS NULL
             ORDER BY p.external_opportunity_id LIMIT 1""", (aero["id"],)).fetchone()

    captured = {}

    async def capturing_call_run(client_row_arg, payload):
        captured["payload"] = payload
        return {"pwin": 0.1, "solver_succeeded": True, "solver_message": "",
               "fee": payload["fee"], "competitor_results": []}

    # A valid (fake) scoring cache is still loaded from section 2 --
    # this section is only about the payload SHAPE, not the values.
    with patch.object(recalc_module, "call_run", new=capturing_call_run):
        with tenant_tx(aero["id"]) as cur:
            asyncio.run(recalc_module.recalculate_pwin(
                cur, str(pursuit["id"]), None, persist=False))
    payload = captured.get("payload")
    check("recalculate_pwin() actually reached call_run with a captured "
          "payload (confirms the mock wiring itself worked)",
          payload is not None, "call_run was never invoked")
    if payload is not None:
        check("the outgoing request has NO 'competitors' key -- the "
              "engine builds them now",
              "competitors" not in payload, f"got keys {list(payload.keys())}")
        check("the outgoing request sends 'bidders' as the real bidder "
              "count for this pursuit",
              payload.get("bidders") == max(int(pursuit["bidders"] or 1), 1),
              f"got bidders={payload.get('bidders')}")

    # ---- 5. fetch failure fails loud at BOTH call sites ----------------
    print("\n=== 5. a fetch failure fails loudly at both fee computation "
          "and recalculation -- same pattern as scoring's own failure ===")
    scoring._tables = None
    scoring.BASE_SCORE = None
    scoring._fee_rates = None
    from fastapi import HTTPException

    raised_fee = None
    try:
        with tenant_tx(aero["id"]) as cur:
            fee_module.resolve_fee(cur, ct["id"], p1["id"])
    except HTTPException as exc:
        raised_fee = exc
    check("Black Hat fee computation fails loudly (HTTPException) when "
          "no fee table has ever been loaded, not a silent wrong number",
          raised_fee is not None
          and ("scoring" in str(raised_fee.detail).lower()
               or "fee" in str(raised_fee.detail).lower()),
          f"got {raised_fee.detail if raised_fee else None}")

    raised_recalc = None
    try:
        with tenant_tx(aero["id"]) as cur:
            asyncio.run(recalc_module.recalculate_pwin(
                cur, str(pursuit["id"]), None, persist=False))
    except HTTPException as exc:
        raised_recalc = exc
    check("recalculation fails loudly the same way, consistent with "
          "scoring's own established failure pattern -- not a second, "
          "different failure shape",
          raised_recalc is not None and raised_recalc.status_code == 502,
          f"got {raised_recalc}")

    # Leave scoring in a clean, unloaded state for whatever runs next.
    scoring._tables = None
    scoring.BASE_SCORE = None
    scoring._fee_rates = None

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Fee/competitor migration verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
