#!/usr/bin/env python3
"""
test_revert_to_pre_bh.py -- reverting a pursuit's phase back to Pre-BH
must produce a genuinely FRESH recalculation from the pursuit's
currently-saved questionnaire answers -- exactly the same computation
/recalculate itself uses -- not a resurrection of the old QUESTIONNAIRE
row's is_current flag (confirmed live, earlier this session, that
bootstrap.py has no such resurrection mechanism at all: it joins purely
on is_current with no way to flip it back on).

Fresh is deliberately better than resurrecting a stale value: market
differentials, fee rates and the scoring table have each been corrected
at least once this session, so a fresh recalculation reflects CURRENT
correct logic. This matters concretely for one of the 12 pursuits
promoted earlier this session via pulled-forward defaults (not a real
competitive analysis) -- reverting one of those must produce a real
number, not restore that promoted value.

Fixture (real AERO pursuit, genuinely Post-BH, one of the 12 promoted
this session): 1038 -- current row is BLACK_HAT, base_pwin=0.116160,
aggressiveness=NORMAL, investment=0. Restored to this exact state at
the end of this test via the real Black Hat submit endpoint (not a
direct SQL write).

    python test_revert_to_pre_bh.py --base http://localhost:8001 ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Requires the API running AND a live AWS session (a real recalculation
calls the real engine). Skipped, not failed, by run_tests.ps1 if either
is unavailable. Exit 0 = all passed.
"""
from __future__ import annotations

import argparse
import sys

import httpx
import psycopg
from psycopg.rows import dict_row

PASS, FAIL = [], []
TOL = 1e-4


def safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:          # noqa: BLE001
        class _R:
            status_code = 0
            text = f"request failed: {type(e).__name__}: {e}"

            @staticmethod
            def json():
                return {}
        return _R()


def check(name, ok, detail=""):
    (PASS if ok else FAIL).append((name, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}"
          f"{'  -- ' + detail if detail and not ok else ''}")


def login(base, email) -> httpx.Client:
    c = httpx.Client(base_url=base, timeout=30, follow_redirects=False)
    r = c.post("/api/login", json={"email": email})
    if r.status_code != 200:
        raise SystemExit(f"login failed for {email}: {r.status_code} {r.text}")
    return c


def current_base(db, pid):
    return db.execute("""
        SELECT id, assessment_type, pwin, base_pwin, blended_pwin,
               engine_request, calculated_at
          FROM pwin_assessment
         WHERE pursuit_id = %s AND scenario = 'BASE' AND is_current""",
        (pid,)).fetchone()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    A = login(args.base, "aero.admin@demoaero.test")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        p = db.execute(
            "SELECT id FROM pursuit WHERE external_opportunity_id = '1038'").fetchone()
    if not p:
        check("fixture pursuit 1038 exists", False)
        print(f"\n{'='*58}\n{len(PASS)} passed, {len(FAIL)} failed")
        return 1
    pid = p["id"]

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        before = current_base(db, pid)
    check("fixture sanity: 1038's current BASE row is genuinely a "
          "Black Hat assessment before this test (one of the 12 "
          "promoted pursuits)",
          before["assessment_type"] == "BLACK_HAT",
          f"got {before['assessment_type']}")
    before_id = before["id"]

    print("\n=== Revert to Pre-BH produces a FRESH QUESTIONNAIRE row, "
          "not a resurrected one ===")
    r = safe(A.patch, f"/api/pursuits/{pid}",
             json={"pipeline_stage_code": "PRE_BH"})
    check("PATCH pipeline_stage_code=PRE_BH succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        after = current_base(db, pid)
        old_row = db.execute(
            "SELECT is_current, assessment_type FROM pwin_assessment WHERE id = %s",
            (before_id,)).fetchone()

    check("the new current BASE row is a fresh QUESTIONNAIRE row, not "
          "the old Black Hat row reactivated",
          after["assessment_type"] == "QUESTIONNAIRE" and after["id"] != before_id,
          f"got assessment_type={after['assessment_type']!r}, "
          f"id changed={after['id'] != before_id}")
    check("the row is genuinely NEW (a later calculated_at, not the "
          "same historical timestamp)",
          after["calculated_at"] > before["calculated_at"])
    check("the row carries a real engine_request -- it was actually "
          "computed via a live engine call, not copied from history",
          after["engine_request"] is not None)
    check("the old Black Hat row still exists, demoted to is_current="
          "FALSE -- preserved, not deleted",
          old_row is not None and old_row["is_current"] is False
          and old_row["assessment_type"] == "BLACK_HAT")

    print("\n=== The fresh value matches an independent /recalculate "
          "call exactly -- genuinely live, not cached or coincidental ===")
    r2 = safe(A.post, f"/api/pursuits/{pid}/recalculate", json={})
    check("a second, independent recalculation succeeds",
          r2.status_code == 200, f"got {r2.status_code}: {r2.text}")
    if r2.status_code == 200:
        check("both calls produce the identical pwin -- the SAME real "
              "computation path, not two different mechanisms",
              abs(r2.json()["pwin"] - float(after["pwin"])) < TOL,
              f"revert produced {after['pwin']}, independent recalc "
              f"produced {r2.json()['pwin']}")

    print("\n=== Restore 1038 to its original Post-BH state via the "
          "real Black Hat submit endpoint ===")
    r3 = safe(A.patch, f"/api/pursuits/{pid}",
              json={"pipeline_stage_code": "POST_BH"})
    check("advancing back to Post-BH succeeds",
          r3.status_code == 200, f"got {r3.status_code}: {r3.text}")
    r4 = safe(A.post, f"/api/pursuits/{pid}/blackhat",
              json={"scenario": "BASE", "aggressiveness_option_code": "NORMAL",
                    "base_pwin": float(before["base_pwin"]), "investment": 0})
    check("re-submitting the original Black Hat values succeeds",
          r4.status_code == 200, f"got {r4.status_code}: {r4.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        restored = current_base(db, pid)
    check("1038 fully restored: current BASE row is Black Hat again "
          "with the original base_pwin",
          restored["assessment_type"] == "BLACK_HAT"
          and abs(float(restored["base_pwin"]) - float(before["base_pwin"])) < TOL,
          f"got {restored['assessment_type']}, base_pwin={restored['base_pwin']}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Revert-to-Pre-BH fresh recalculation verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
