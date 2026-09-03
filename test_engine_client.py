#!/usr/bin/env python3
"""
test_engine_client.py -- real per-client SSM key resolution
(engine_client.py) and the real engine's actual request-shape
requirements, run against the REAL shared AWS account and the REAL
engine (not the local dev stub).

Requires a live, correctly-scoped AWS session -- run
`.\\refresh-aws-creds.ps1` first (never your own personal SSO admin
session; see that script's own docstring for why). This is exactly what
the narrow IAM policy (/cda/clients/*/products/cpde-core/* only) exists
to make safe to test directly: real keys, real client rows, real IAM
denial, no mocking, no local stub.

Section 5 used to lock in a real, live finding about competitor-score
key style (short tech/mgmt/pp keys failed the live DAP solver; the
long Technical/Management/Past Performance style recalc.py sent
worked). That hand-built competitors array is gone as of the
fee/competitor migration -- recalc.py now sends bidders: N and lets
the engine build the same synthetic competitors itself (engine
v0.29+). Section 5 now independently verifies THAT claim live: the
current bidders-only payload and the old hand-built long-key
competitors array are both run against the same real pursuit on the
same live engine, and the two pwin results are confirmed identical --
not just trusted from the engine team's own "byte-identical" claim,
same discipline as the original short/long key finding above.

    python test_engine_client.py

Exit 0 = all passed.
"""
from __future__ import annotations

import asyncio
import copy
import os
import sys

PASS, FAIL = [], []


def check(name, ok, detail=""):
    (PASS if ok else FAIL).append((name, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}"
          f"{'  -- ' + detail if detail and not ok else ''}")


def main():
    # Repo-root layout (api/app/...) when run locally; /srv/app when run
    # via `docker exec cpde-api python test_engine_client.py`, where the
    # real AWS credentials (from refresh-aws-creds.ps1) actually live.
    sys.path.insert(0, "api")
    sys.path.insert(0, "/srv")
    from app import engine_client
    from app.db import fetch_all, unscoped_tx

    # Read client rows LIVE from the DB rather than hardcoding client
    # codes/secret refs here -- engine_client_code and engine_secret_ref
    # have already changed once during this project (DEMO's
    # 'collins' -> 'collins-aerospace' correction), and a hardcoded
    # value in a test file is exactly the kind of thing that silently
    # goes stale when that happens again.
    with unscoped_tx() as cur:
        clients = fetch_all(cur, "SELECT * FROM fn_list_active_clients()")
    aero_row = next(c for c in clients if c["code"] == "AERO")
    demo_row = next(c for c in clients if c["code"] == "DEMO")

    print("=== 1. a client with a valid engine_secret_ref resolves a real key ===")
    engine_client._key_cache.clear()
    try:
        key = engine_client.resolve_engine_api_key_for_client(aero_row)
        check("AERO's real SSM SecureString resolves and decrypts",
              isinstance(key, str) and len(key) > 0, f"got {key!r}")
    except engine_client.EngineCredentialError as exc:
        check("AERO's real SSM SecureString resolves and decrypts", False, str(exc))

    print("\n=== 2. a nonexistent parameter fails clearly, not a silent empty key ===")
    # Deliberately a fake, made-up path -- NOT tied to any real client's
    # current provisioning state. An earlier version of this test relied
    # on DEMO's own key-value parameter genuinely not existing yet, which
    # was true when written but stopped being true once it was
    # provisioned -- exactly the kind of drift a test should not depend on.
    fake_row = {"code": "NONEXISTENT", "engine_client_code": "nonexistent",
               "engine_secret_ref": "/cda/clients/nonexistent-test-client/products/cpde-core/key-value"}
    engine_client._key_cache.clear()
    try:
        engine_client.resolve_engine_api_key_for_client(fake_row)
        check("a client whose parameter does not exist raises, rather "
              "than returning an empty/fake key", False,
              "resolved without error -- should have raised")
    except engine_client.EngineCredentialError as exc:
        msg = str(exc)
        check("a client whose parameter does not exist raises "
              "EngineCredentialError naming the client and the real reason",
              "NONEXISTENT" in msg and "ParameterNotFound" in msg, f"got {msg!r}")

    print("\n=== 3. the resolver does not re-hit SSM within the cache window ===")
    engine_client._key_cache.clear()
    calls = {"n": 0}
    real_fn = engine_client._resolve_key_from_ssm

    def counting(ref):
        calls["n"] += 1
        return real_fn(ref)

    engine_client._resolve_key_from_ssm = counting
    try:
        k1 = engine_client.resolve_engine_api_key_for_client(aero_row)
        k2 = engine_client.resolve_engine_api_key_for_client(aero_row)
        check("two resolutions within the TTL window hit SSM exactly once",
              calls["n"] == 1, f"SSM was called {calls['n']} times")
        check("both resolutions return the identical cached value",
              k1 == k2, f"{k1!r} != {k2!r}")
    finally:
        engine_client._resolve_key_from_ssm = real_fn

    print("\n=== 4. IAM genuinely cannot read a different product's path ===")
    # Same client (DEMO's real engine_client_code), a DIFFERENT product --
    # must be denied by the /cda/clients/*/products/cpde-core/* scoping.
    # Tested from cpde-web's own code path (boto3, via _ssm()), not just
    # trusting the policy JSON in isolation.
    foreign_ref = f"/cda/clients/{demo_row['engine_client_code']}/products/cpde-salesforce/key-value"
    try:
        engine_client._ssm().get_parameter(Name=foreign_ref, WithDecryption=True)
        check("reading a different product's SSM path is denied", False,
              "read SUCCEEDED -- IAM scoping is not enforced as documented")
    except Exception as exc:
        check("reading a different product's SSM path is denied "
              "(AccessDeniedException)",
              "AccessDenied" in type(exc).__name__ or "AccessDenied" in str(exc),
              f"got {type(exc).__name__}: {exc}")

    print("\n=== 5. bidders: N vs. the old hand-built competitors array -- "
          "independently confirmed identical against the live engine ===")
    # Pre-migration, recalc.py hand-built a synthetic competitors array
    # (fixed 85/85/85 "Avg Co N" scores, one per bidder, long
    # Technical/Management/Past Performance keys -- confirmed against
    # BuildInputJson_). The fee/competitor migration replaced that with
    # sending bidders: N and letting the engine build the identical
    # array itself (engine v0.29+, "confirmed byte-identical" by the
    # engine team). Not taken on trust: both payloads are run live
    # against the same real pursuit on the same real engine below, and
    # the two pwin results are compared directly.
    from app.db import tenant_tx
    from app import recalc as recalc_module, scoring

    AERO_ID = str(aero_row["id"])
    PURSUIT_ID = None
    with tenant_tx(AERO_ID) as cur:
        row = cur.execute("""
            SELECT p.id FROM pursuit p
              JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
             WHERE p.client_id = %s AND ps.code = 'PRE_BH' AND p.outcome IS NULL
             ORDER BY p.external_opportunity_id LIMIT 1""", (AERO_ID,)).fetchone()
        PURSUIT_ID = row["id"] if row else None

    if PURSUIT_ID is None:
        check("a real PRE_BH AERO pursuit exists to test against", False,
              "none found -- cannot run this check")
    else:
        captured = {}
        real_call_run = engine_client.call_run

        async def capturing_call_run(client_row, payload):
            captured["client_row"] = client_row
            captured["payload"] = copy.deepcopy(payload)
            return await real_call_run(client_row, payload)

        recalc_module.call_run = capturing_call_run
        prior_url_override = os.environ.pop("CPDE_ENGINE_URL", None)
        try:
            # recalculate_pwin() needs a loaded scoring table now
            # (scoring.py's live-fetch migration) -- a real fetch
            # against the same live engine this whole section is
            # already testing against, not a mock.
            asyncio.run(scoring.refresh(aero_row))
            with tenant_tx(AERO_ID) as cur:
                asyncio.run(recalc_module.recalculate_pwin(
                    cur, str(PURSUIT_ID), None, persist=False))
        finally:
            recalc_module.call_run = real_call_run
            if prior_url_override is not None:
                os.environ["CPDE_ENGINE_URL"] = prior_url_override

        payload_current = captured.get("payload")
        check("recalc.py's current outgoing payload has NO hand-built "
              "'competitors' key -- construction happens engine-side now",
              payload_current is not None and "competitors" not in payload_current,
              f"got keys {list(payload_current.keys()) if payload_current else None}")
        check("recalc.py's current outgoing payload sends 'bidders' "
              "instead", payload_current is not None and "bidders" in payload_current,
              f"got keys {list(payload_current.keys()) if payload_current else None}")

        if payload_current is not None:
            # Reconstruct the OLD hand-built array exactly as recalc.py
            # used to send it (git history, pre-migration), from the
            # SAME captured tech/mgmt/pp/price/fee/etc inputs, so the
            # only variable between the two live calls is competitors
            # vs. bidders.
            bidder_count = payload_current["bidders"]
            cprice_delta = payload_current["cprice_delta"]
            comp_bid_price = 100.0 * (1.0 + cprice_delta)
            payload_old_style = {k: v for k, v in payload_current.items()
                                 if k != "bidders"}
            payload_old_style["competitors"] = [
                {"name": f"Avg Co {i}", "bid_price": comp_bid_price,
                 "scores": {"Technical": 85.0, "Management": 85.0,
                            "Past Performance": 85.0},
                 "bid_probability": 1.0}
                for i in range(1, bidder_count + 1)
            ]

            async def run_both():
                os.environ.pop("CPDE_ENGINE_URL", None)
                try:
                    r_bidders = await engine_client.call_run(captured["client_row"], payload_current)
                    r_old = await engine_client.call_run(captured["client_row"], payload_old_style)
                finally:
                    if prior_url_override is not None:
                        os.environ["CPDE_ENGINE_URL"] = prior_url_override
                return r_bidders, r_old

            r_bidders, r_old = asyncio.run(run_both())
            check("the CURRENT bidders:N request solves successfully "
                  "against the live engine",
                  r_bidders.get("solver_succeeded") is True,
                  f"got {r_bidders}")
            check("the OLD hand-built competitors array also solves "
                  "successfully (both requests are actually comparable, "
                  "neither silently errored)",
                  r_old.get("solver_succeeded") is True,
                  f"got {r_old}")
            check("bidders:N produces an IDENTICAL pwin to the old "
                  "hand-built competitors array -- independently "
                  "verified live, not just taken on the engine team's "
                  "word",
                  r_bidders.get("solver_succeeded") is True
                  and r_old.get("solver_succeeded") is True
                  and abs(r_bidders.get("pwin", -1) - r_old.get("pwin", -2)) < 1e-9,
                  f"bidders pwin={r_bidders.get('pwin')}, "
                  f"old-style pwin={r_old.get('pwin')}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        print("\nIf every check above failed with a credential-shaped error, "
              "your AWS session may be missing or expired -- run "
              ".\\refresh-aws-creds.ps1 and try again.")
        return 1
    print("Engine client SSM resolution verified against the real AWS account.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
