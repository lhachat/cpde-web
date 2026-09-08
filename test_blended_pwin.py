#!/usr/bin/env python3
"""
test_blended_pwin.py -- blended_pwin must be computed and persisted for
every real dependent pursuit's BASE row, per the confirmed production
spreadsheet formula:

    blended = base + (dep_won_pwin - base) * dep_factor

dep_factor is the predecessor's realized outcome as a hard 0/1 weight
once decided (WON=1, LOST=0), or the predecessor's own current BASE Pwin
while still open. Confirmed exactly against migrate_workbook.py's own
migrated historical data before writing any implementation:

  - 1073 (predecessor 1058, open): base=0.199000, dep_won=0.134575,
    dep_factor=0.119825 (predecessor's own live Pwin) => blended=0.191280,
    matching the migrated blended_pwin exactly.
  - 53 (predecessor 11, LOST): migrated blended_pwin (0.089500) ==
    base_pwin (0.089500) exactly -- confirms LOST => factor 0.
  - 61 (predecessor 54, WON): migrated blended_pwin (0.564025) ==
    dependent_won's own pwin (0.564025) exactly -- confirms WON => factor 1.

CANCELLED/NO_BID predecessors: confirmed live that NO real dependent
pursuit in AERO/DEMO has one today, and the source spreadsheet formula
has no branch for this case -- recalc.py's apply_dependency_blend()
raises rather than inventing a rule for it. Not exercised here since it
cannot be exercised against real data (would require inventing a
fixture the real system has never actually had).

Fixtures (real pursuits, all genuinely Pre-BH and open):
  1055 (AERO) -- no dependency (existing LPTA fixture, reused for its
                 "not a dependent pursuit at all" property, not its
                 LPTA-ness)
  1073 (AERO) -- dependency on 1058, predecessor still open
  61   (DEMO) -- dependency on 54, predecessor decided WON
  53   (DEMO) -- dependency on 11, predecessor decided LOST

    python test_blended_pwin.py --base http://localhost:8001 ^
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


def pursuit_id(db, uid):
    return db.execute(
        "SELECT id, depends_on_pursuit_id FROM pursuit "
        "WHERE external_opportunity_id = %s", (uid,)).fetchone()


def current_row(db, pid, scenario):
    return db.execute("""
        SELECT pwin, base_pwin, blended_pwin FROM pwin_assessment
         WHERE pursuit_id = %s AND scenario = %s AND is_current""",
        (pid, scenario)).fetchone()


def predecessor_outcome_and_pwin(db, pred_id):
    outcome = db.execute(
        "SELECT outcome FROM pursuit WHERE id = %s", (pred_id,)).fetchone()
    pwin = current_row(db, pred_id, "BASE")
    return (outcome["outcome"] if outcome else None,
            float(pwin["pwin"]) if pwin and pwin["pwin"] is not None else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    A = login(args.base, "aero.admin@demoaero.test")
    D = login(args.base, "demo.admin@democlient.test")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        p_none = pursuit_id(db, "1055")
        p_open = pursuit_id(db, "1073")
        p_won = pursuit_id(db, "61")
        p_lost = pursuit_id(db, "53")

    for name, p in [("1055", p_none), ("1073", p_open), ("61", p_won), ("53", p_lost)]:
        check(f"fixture pursuit {name} exists", p is not None)
    if not all([p_none, p_open, p_won, p_lost]):
        print(f"\n{'='*58}\n{len(PASS)} passed, {len(FAIL)} failed")
        return 1

    check("1055 fixture sanity: genuinely has no dependency",
          p_none["depends_on_pursuit_id"] is None)
    check("1073 fixture sanity: genuinely has a dependency",
          p_open["depends_on_pursuit_id"] is not None)
    check("61 fixture sanity: genuinely has a dependency",
          p_won["depends_on_pursuit_id"] is not None)
    check("53 fixture sanity: genuinely has a dependency",
          p_lost["depends_on_pursuit_id"] is not None)

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        won_outcome, _ = predecessor_outcome_and_pwin(db, p_won["depends_on_pursuit_id"])
        lost_outcome, _ = predecessor_outcome_and_pwin(db, p_lost["depends_on_pursuit_id"])
        open_outcome, _ = predecessor_outcome_and_pwin(db, p_open["depends_on_pursuit_id"])
    check("61's real predecessor (54) is genuinely decided WON",
          won_outcome == "WON", f"got {won_outcome!r}")
    check("53's real predecessor (11) is genuinely decided LOST",
          lost_outcome == "LOST", f"got {lost_outcome!r}")
    check("1073's real predecessor (1058) is genuinely still open",
          open_outcome is None, f"got {open_outcome!r}")

    print("\n=== Case: no dependency -- blended_pwin stays NULL, pwin == base_pwin ===")
    r = safe(A.post, f"/api/pursuits/{p_none['id']}/recalculate", json={})
    check("recalculating 1055 (no dependency) succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        row = current_row(db, p_none["id"], "BASE")
    check("1055's blended_pwin is NULL (nothing to blend)",
          row["blended_pwin"] is None, f"got {row['blended_pwin']}")
    check("1055's pwin == base_pwin",
          abs(float(row["pwin"]) - float(row["base_pwin"])) < TOL,
          f"pwin={row['pwin']} base_pwin={row['base_pwin']}")

    print("\n=== Case: dependency still open -- blended by predecessor's live Pwin ===")
    r = safe(A.post, f"/api/pursuits/{p_open['id']}/recalculate", json={})
    check("recalculating 1073 (open predecessor) succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        base_row = current_row(db, p_open["id"], "BASE")
        dep_won_row = current_row(db, p_open["id"], "DEPENDENT_WON")
        _, pred_pwin = predecessor_outcome_and_pwin(db, p_open["depends_on_pursuit_id"])
    base = float(base_row["base_pwin"])
    dep_win = float(dep_won_row["pwin"]) if dep_won_row and dep_won_row["pwin"] is not None else base
    expected = base + (dep_win - base) * pred_pwin
    check("1073's stored blended_pwin matches base+(depWin-base)*predecessorPwin",
          base_row["blended_pwin"] is not None
          and abs(float(base_row["blended_pwin"]) - expected) < TOL,
          f"got {base_row['blended_pwin']}, expected {expected}")
    check("1073's pwin equals its own blended_pwin (headline value is the blend)",
          base_row["blended_pwin"] is not None
          and abs(float(base_row["pwin"]) - float(base_row["blended_pwin"])) < TOL,
          f"pwin={base_row['pwin']} blended_pwin={base_row['blended_pwin']}")

    print("\n=== Case: dependency decided WON -- factor 1, blended == dep-won Pwin ===")
    r = safe(D.post, f"/api/pursuits/{p_won['id']}/recalculate", json={})
    check("recalculating 61 (WON predecessor) succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        base_row = current_row(db, p_won["id"], "BASE")
        dep_won_row = current_row(db, p_won["id"], "DEPENDENT_WON")
    check("61's blended_pwin == its own DEPENDENT_WON pwin exactly (factor 1)",
          base_row["blended_pwin"] is not None
          and abs(float(base_row["blended_pwin"]) - float(dep_won_row["pwin"])) < TOL,
          f"blended={base_row['blended_pwin']} dep_won={dep_won_row['pwin']}")

    print("\n=== Case: dependency decided LOST -- factor 0, blended == own base Pwin ===")
    r = safe(D.post, f"/api/pursuits/{p_lost['id']}/recalculate", json={})
    check("recalculating 53 (LOST predecessor) succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        base_row = current_row(db, p_lost["id"], "BASE")
    check("53's blended_pwin == its own base_pwin exactly (factor 0)",
          base_row["blended_pwin"] is not None
          and abs(float(base_row["blended_pwin"]) - float(base_row["base_pwin"])) < TOL,
          f"blended={base_row['blended_pwin']} base={base_row['base_pwin']}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("blended_pwin computation verified against real dependent pursuits.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
