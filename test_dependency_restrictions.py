#!/usr/bin/env python3
"""
test_dependency_restrictions.py -- a pursuit that is sole-source, or
currently answered LPTA (P2), must not be allowed to have
depends_on_pursuit_id set at all.

Why (confirmed empirically before building, not assumed):

  Sole source bypasses the engine entirely (flat 95% rule) -- there is
  no real base/dependent-won computation to blend, so the concept is
  structurally inapplicable.

  LPTA: since dap_solver's LPTA branch sets dap = bid_price (price
  only, tech/mgmt/pp excluded), the working assumption was that a
  predecessor win -- which typically only changes incumbency/experience
  answers feeding tech/mgmt/pp -- would leave an LPTA pursuit's
  Dependent-Won Pwin identical or near-identical to its Base Pwin.
  CONFIRMED FALSE for real pursuit 1140 (tech/mgmt/pp swung from
  75/75/85 to 95/95/90, Pwin stayed EXACTLY 0.346225 both times --
  confirming tech/mgmt/pp really is irrelevant under LPTA) but ALSO
  confirmed a real counter-example on pursuit 1139: cprice_delta
  (competitor price position, driven by TM2/TM3 -- the SAME competitive-
  position answers that plausibly change on a predecessor win) shifted
  from 0.0 to -0.1 between BASE and DEPENDENT_WON, and LPTA's own DAP
  computation uses the competitor's bid_price (built from cprice_delta)
  -- Base Pwin 0.155200 vs Dependent-Won Pwin 0.065278, a real ~9-point
  swing. The "always a no-op" premise is false; this restriction is a
  deliberate product decision, not a mathematical inevitability.

Existing violations (found live, reported before this restriction
existed, left untouched pending an explicit decision):
  Sole-source WITH a dependency set: 1080, 1098, 1124 (all AERO)
  LPTA WITH a dependency set:        1080, 1124 (also sole-source above),
                                      1139, 1140 (NOT sole-source --
                                      newly surfaced by the LPTA half of
                                      this rule specifically)
Approved and cleared via the real PATCH write path (not a direct SQL
update) in the round that found them -- this test now asserts ZERO
violators of either kind remain. If this assertion ever fails, a new
violation was created somewhere the guards above should have caught.

Fixtures for the NEW-set rejection (real AERO pursuits, Pre-BH, open,
not already a violator):
  1074 -- real sole source, no dependency
  1108 -- real LPTA (P2), no dependency, NOT sole source
  1060 -- valid dependency target (Best Value, not sole source, open)

    python test_dependency_restrictions.py --base http://localhost:8001 ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Requires the API running. Exit 0 = all passed.
"""
from __future__ import annotations

import argparse
import sys

import httpx
import psycopg
from psycopg.rows import dict_row

PASS, FAIL = [], []


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


def pursuit_id(db, uid, client="AERO"):
    return db.execute("""
        SELECT p.id FROM pursuit p JOIN client c ON c.id = p.client_id
         WHERE p.external_opportunity_id = %s AND c.code = %s""",
        (uid, client)).fetchone()["id"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        print("=== Existing violations, confirmed cleared via the real write path ===")
        sole_source_violators = db.execute("""
            SELECT p.external_opportunity_id AS uid FROM pursuit p
             WHERE p.is_sole_source AND p.depends_on_pursuit_id IS NOT NULL
             ORDER BY p.external_opportunity_id""").fetchall()
        check("zero sole-source-with-dependency violators remain (1080, "
              "1098, 1124 were cleared via the real write path)",
              sole_source_violators == [],
              f"got {[r['uid'] for r in sole_source_violators]}")

        lpta_violators = db.execute("""
            SELECT p.external_opportunity_id AS uid FROM pursuit p
              JOIN pwin_assessment a ON a.pursuit_id = p.id
                    AND a.is_current AND a.scenario = 'BASE'
              JOIN pwin_answer w ON w.pwin_assessment_id = a.id
              JOIN question q ON q.id = w.question_id AND q.code = 'P2'
              JOIN question_option o ON o.id = w.question_option_id
             WHERE o.label_text = 'LPTA' AND p.depends_on_pursuit_id IS NOT NULL
             ORDER BY p.external_opportunity_id""").fetchall()
        check("zero LPTA-with-dependency violators remain (1080, 1124, "
              "1139, 1140 were cleared via the real write path)",
              lpta_violators == [],
              f"got {[r['uid'] for r in lpta_violators]}")

    A = login(args.base, "aero.admin@demoaero.test")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        p_sole = pursuit_id(db, "1074")
        p_lpta = pursuit_id(db, "1108")
        target_uid = "1060"

    print("\n=== Case: setting a dependency on a sole-source pursuit is rejected ===")
    r = safe(A.patch, f"/api/pursuits/{p_sole}",
             json={"depends_on_opp_id": target_uid})
    check("PATCH depends_on_opp_id on a sole-source pursuit is rejected (400)",
          r.status_code == 400, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        row = db.execute("SELECT depends_on_pursuit_id FROM pursuit WHERE id = %s",
                          (p_sole,)).fetchone()
    check("the rejected assignment was never written",
          row["depends_on_pursuit_id"] is None, f"got {row['depends_on_pursuit_id']}")

    print("\n=== Case: setting a dependency on an LPTA pursuit is rejected ===")
    r = safe(A.patch, f"/api/pursuits/{p_lpta}",
             json={"depends_on_opp_id": target_uid})
    check("PATCH depends_on_opp_id on an LPTA pursuit is rejected (400)",
          r.status_code == 400, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        row = db.execute("SELECT depends_on_pursuit_id FROM pursuit WHERE id = %s",
                          (p_lpta,)).fetchone()
    check("the rejected assignment was never written",
          row["depends_on_pursuit_id"] is None, f"got {row['depends_on_pursuit_id']}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Sole-source/LPTA dependency restriction verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
