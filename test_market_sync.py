#!/usr/bin/env python3
"""
test_market_sync.py -- market_sync.py's DB-application logic and its
shared-credential wiring to engine_client.py.

Matching is by NAME ONLY -- GET /v1/markets returns bare display-name
strings with no code or id (confirmed by reading cda_engine's own
runtime/api.py and config_loader.py directly, not assumed), so a
"rename" is structurally indistinguishable from "old market gone, new
one appeared." There is therefore no rename test here -- see
market_sync.py's own docstring for the full reasoning. What IS tested:
create, flag (never delete), idempotent re-sync, a previously-flagged
market resurfacing, all-or-nothing failure behavior, and that the sync
job authenticates through the exact same path Recalculate Pwin does.

    python test_market_sync.py --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

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
    from app import market_sync, engine_client
    from app.db import tenant_tx

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as admin:
        aero = admin.execute("SELECT id FROM client WHERE code = 'AERO'").fetchone()["id"]

        # Fixture: a small, throwaway market set for AERO, isolated from
        # real seed data by a distinctive TESTMKT_ prefix -- deleted at
        # the end regardless of outcome.
        admin.execute("DELETE FROM market WHERE client_id = %s AND name LIKE 'Test %%Market'", (aero,))
        admin.execute("""
            INSERT INTO market (client_id, code, name, is_active)
            VALUES (%s, 'TESTMKT_KEEP', 'Test Keep Market', true),
                   (%s, 'TESTMKT_GONE', 'Test Gone Market', true)""", (aero, aero))
        admin.commit()

    try:
        # ---- 1. a market present in engine response but not locally ---
        print("=== 1. new engine market gets created ===")
        with tenant_tx(aero) as cur:
            result = market_sync.apply_market_sync(
                cur, aero, ["Test Keep Market", "Test Gone Market", "Test New Market"])
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as admin:
            new_row = admin.execute("""
                SELECT code, is_active, flagged_for_review FROM market
                 WHERE client_id = %s AND name = 'Test New Market'""", (aero,)).fetchone()
        check("a new engine-reported name gets a new local market row",
              new_row is not None and new_row["is_active"] and not new_row["flagged_for_review"],
              f"got {new_row}")
        check("apply_market_sync reports the creation",
              result["created"] == ["Test New Market"], f"got {result}")
        check("an already-matching market is untouched (no spurious create)",
              "Test Keep Market" not in result["created"], f"got {result}")

        # ---- 2. idempotency + a previously-flagged market resurfacing --
        print("\n=== 2. idempotent re-sync; a flagged market resurfacing gets unflagged ===")
        # (no rename test -- see module docstring: the engine's own
        # response has no stable key to detect one)
        with tenant_tx(aero) as cur:
            result2 = market_sync.apply_market_sync(
                cur, aero, ["Test Keep Market", "Test Gone Market", "Test New Market"])
        check("re-syncing the identical name set creates and flags nothing",
              result2 == {"created": [], "flagged": [], "unflagged": []},
              f"got {result2}")

        with tenant_tx(aero) as cur:
            flag_result = market_sync.apply_market_sync(cur, aero, ["Test Keep Market"])
        check("Gone and New market are flagged when absent from a later sync",
              set(flag_result["flagged"]) == {"Test Gone Market", "Test New Market"},
              f"got {flag_result}")

        with tenant_tx(aero) as cur:
            resurface_result = market_sync.apply_market_sync(
                cur, aero, ["Test Keep Market", "Test Gone Market", "Test New Market"])
        check("a previously-flagged market that reappears is unflagged, "
              "not re-created as a duplicate",
              resurface_result["unflagged"] == ["Test Gone Market", "Test New Market"]
              and resurface_result["created"] == [],
              f"got {resurface_result}")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as admin:
            dupes = admin.execute("""
                SELECT count(*) AS n FROM market
                 WHERE client_id = %s AND name = 'Test Gone Market'""", (aero,)).fetchone()["n"]
        check("no duplicate row was created for the resurfaced market",
              dupes == 1, f"got {dupes} rows")

        # ---- 3. absent from engine -> flagged, never deleted ----------
        print("\n=== 3. absent-from-engine market is flagged, never deleted, "
              "pursuits unaffected ===")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as admin:
            gone_id = admin.execute("""
                SELECT id FROM market WHERE client_id = %s
                 AND name = 'Test Gone Market'""", (aero,)).fetchone()["id"]
            # A real pursuit referencing this market, restored afterward --
            # same "temp mutation restored via the real state, verified"
            # discipline as every other round's DB test data.
            some_pursuit = admin.execute("""
                SELECT id, market_id FROM pursuit
                 WHERE client_id = %s LIMIT 1""", (aero,)).fetchone()
            admin.execute("UPDATE pursuit SET market_id = %s WHERE id = %s",
                          (gone_id, some_pursuit["id"]))
            admin.commit()

        with tenant_tx(aero) as cur:
            flag_result3 = market_sync.apply_market_sync(cur, aero, ["Test Keep Market"])
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as admin:
            gone_row = admin.execute("""
                SELECT flagged_for_review, is_active FROM market
                 WHERE id = %s""", (gone_id,)).fetchone()
            pursuit_row = admin.execute("""
                SELECT market_id FROM pursuit WHERE id = %s""",
                (some_pursuit["id"],)).fetchone()
        check("the market row still exists (not deleted)", gone_row is not None,
              "row was deleted")
        check("it is flagged for review", gone_row and gone_row["flagged_for_review"] is True,
              f"got {gone_row}")
        check("is_active is untouched by flagging (separate concern)",
              gone_row and gone_row["is_active"] is True, f"got {gone_row}")
        check("the pursuit referencing the flagged market is completely "
              "unaffected -- still points at the same market_id",
              pursuit_row and str(pursuit_row["market_id"]) == str(gone_id),
              f"got {pursuit_row}")

        # Restore the pursuit's real market via direct write (this is
        # test-induced state, not a real user's data -- same discipline
        # as every other round's DB fixture restore).
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as admin:
            admin.execute("UPDATE pursuit SET market_id = %s WHERE id = %s",
                          (some_pursuit["market_id"], some_pursuit["id"]))
            admin.commit()

        # ---- 4. shared credential path, not a second mechanism --------
        print("\n=== 4. sync job uses the SAME key-resolution path as call_run ===")
        client_row = {"id": aero, "code": "AERO", "engine_base_url": "http://example.invalid",
                      "engine_client_code": "cda-internal"}
        with patch.object(engine_client, "resolve_engine_api_key_for_client",
                          return_value="SENTINEL-KEY-777") as mock_key:
            captured = {}

            async def fake_get(self_http, url, headers=None, **kw):
                captured["headers"] = headers
                class R:
                    status_code = 200
                    def raise_for_status(self): pass
                    def json(self): return {"markets": ["X"]}
                return R()

            with patch("httpx.AsyncClient.get", new=fake_get):
                asyncio.run(engine_client.call_get_markets(client_row))
        check("call_get_markets resolved the key through the SAME "
              "resolve_engine_api_key_for_client function call_run uses",
              mock_key.called, "resolve_engine_api_key_for_client was never called")
        check("the resolved key was actually sent as x-api-key",
              captured.get("headers", {}).get("x-api-key") == "SENTINEL-KEY-777",
              f"got headers {captured.get('headers')}")

        # ---- 5. sync failure never partially applies -------------------
        print("\n=== 5. a fetch failure leaves local data completely untouched ===")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as admin:
            before = {r["name"]: dict(r) for r in admin.execute("""
                SELECT name, flagged_for_review, is_active FROM market
                 WHERE client_id = %s AND name LIKE 'Test %%Market'""", (aero,)).fetchall()}
            n_runs_before = admin.execute(
                "SELECT count(*) AS n FROM market_sync_run WHERE client_id = %s",
                (aero,)).fetchone()["n"]

        async def boom(client_row):
            raise RuntimeError("simulated: engine unreachable")

        with patch.object(market_sync, "fetch_engine_market_names", new=boom):
            fail_result = asyncio.run(market_sync.sync_client_markets(
                {"id": aero, "code": "AERO", "engine_base_url": "http://example.invalid",
                 "engine_client_code": "cda-internal"}))
        check("sync_client_markets reports failure, not a silent success",
              fail_result["status"] == "failed", f"got {fail_result}")

        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as admin:
            after = {r["name"]: dict(r) for r in admin.execute("""
                SELECT name, flagged_for_review, is_active FROM market
                 WHERE client_id = %s AND name LIKE 'Test %%Market'""", (aero,)).fetchall()}
            n_runs_after = admin.execute(
                "SELECT count(*) AS n FROM market_sync_run WHERE client_id = %s",
                (aero,)).fetchone()["n"]
            last_run = admin.execute("""
                SELECT status, error_message FROM market_sync_run
                 WHERE client_id = %s ORDER BY started_at DESC LIMIT 1""",
                (aero,)).fetchone()
        check("local market data is byte-for-byte unchanged after a "
              "fetch failure -- no partial writes",
              before == after, f"before={before} after={after}")
        check("a failed run IS logged (reviewable), with the real error",
              n_runs_after == n_runs_before + 1
              and last_run["status"] == "failed"
              and "simulated" in (last_run["error_message"] or ""),
              f"got {last_run}")

    finally:
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as admin:
            admin.execute("DELETE FROM market WHERE client_id = %s AND name LIKE 'Test %%Market'",
                          (aero,))
            admin.execute("""
                DELETE FROM market_sync_run WHERE client_id = %s
                 AND started_at > now() - interval '1 hour'""", (aero,))
            admin.commit()

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Market sync verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
