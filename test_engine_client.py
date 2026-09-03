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

Section 5 locks in a real, live finding: a published engine integration
reference's example payload uses short competitor-score keys
(tech/mgmt/pp) that FAIL against the actual live engine (DAP solver
error) for a real pursuit's real inputs -- recalc.py's existing long-key
style (Technical/Management/Past Performance) is the one that works.
See that section for the full story.

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

    print("\n=== 5. competitor score keys -- locks in the CONFIRMED-correct "
          "style against the live engine (not the reference doc's example) ===")
    # A published integration reference showed synthetic-competitor
    # scores as {"tech": .., "mgmt": .., "pp": ..}; recalc.py has always
    # sent {"Technical": .., "Management": .., "Past Performance": ..}
    # (ported from BuildInputJson_). Verified live, directly: sending
    # THIS payload's competitors under the reference doc's short keys
    # makes the live engine's DAP solver fail outright
    # (solver_succeeded=false, "negative DAP" for every competitor) --
    # the long keys recalc.py already sends are the ones the engine
    # actually reads correctly. This locks that in so a future "helpful"
    # fix toward the doc's example does not silently break every
    # Recalculate Pwin call.
    from app.db import tenant_tx
    from app import recalc as recalc_module

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
            with tenant_tx(AERO_ID) as cur:
                asyncio.run(recalc_module.recalculate_pwin(
                    cur, str(PURSUIT_ID), None, persist=False))
        finally:
            recalc_module.call_run = real_call_run
            if prior_url_override is not None:
                os.environ["CPDE_ENGINE_URL"] = prior_url_override

        payload_current = captured.get("payload")
        current_keys = (set(payload_current["competitors"][0]["scores"])
                        if payload_current and payload_current.get("competitors") else set())
        check("recalc.py's current outgoing competitor score keys are "
              "the long style (Technical/Management/Past Performance)",
              current_keys == {"Technical", "Management", "Past Performance"},
              f"got {current_keys}")

        if payload_current is not None:
            payload_wrong = copy.deepcopy(payload_current)
            key_map = {"Technical": "tech", "Management": "mgmt", "Past Performance": "pp"}
            for comp in payload_wrong["competitors"]:
                comp["scores"] = {key_map.get(k, k): v for k, v in comp["scores"].items()}

            async def run_both():
                os.environ.pop("CPDE_ENGINE_URL", None)
                try:
                    r_current = await engine_client.call_run(captured["client_row"], payload_current)
                    r_wrong = await engine_client.call_run(captured["client_row"], payload_wrong)
                finally:
                    if prior_url_override is not None:
                        os.environ["CPDE_ENGINE_URL"] = prior_url_override
                return r_current, r_wrong

            r_current, r_wrong = asyncio.run(run_both())
            check("the CURRENT (long-key) request solves successfully "
                  "against the live engine",
                  r_current.get("solver_succeeded") is True,
                  f"got {r_current}")
            check("the reference doc's short-key style FAILS against the "
                  "same live engine for the same pursuit -- confirms the "
                  "keys are not interchangeable, and confirms which side "
                  "is actually correct",
                  r_wrong.get("solver_succeeded") is False,
                  f"got {r_wrong}")

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
