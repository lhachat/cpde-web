#!/usr/bin/env python3
"""
test_cancelled_predecessor.py -- a cancelled predecessor must auto-clear
the dependency on every pursuit that depends on it, not hard-lock them.

WHY: apply_dependency_blend() used to raise 409 for a CANCELLED (or
NO_BID) predecessor, blocking the dependent pursuit's own recalculate
and Black Hat/PTW submission until a human manually cleared the
dependency by hand. Confirmed against the real VBA source
(ClearDependencyRefs_) -- a cancelled predecessor should instead
auto-clear depends_on_pursuit_id on every dependent, exactly the same
way the sole-source/LPTA reverse-transition auto-clear already works
(write.py's own dependency_cleared field). The dependent's Pwin then
reverts to its own Base Pwin via the ALREADY-BUILT no-dependency case
(blended_pwin stays NULL, pwin == base_pwin) -- no new blend math, just
the trigger (plan_scope.auto_clear_dependents_of_cancelled).

NO_BID predecessors are explicitly OUT OF SCOPE for this fix -- no
auto-clear exists for NO_BID (confirmed live: outcome='NO_BID' is a
real, valid `pursuit.outcome` CHECK-constraint value, but the live
/api/pursuits/{id}/outcome endpoint's own validator only ever accepts
WON/LOST/CANCELLED/null, so no real pursuit reaches NO_BID through the
running app at all -- 0 real AERO/DEMO pursuits have it today). The
hard lock in apply_dependency_blend() for NO_BID is unchanged.

RED (confirmed live before this fix existed, not re-exercised here --
reverting the fix just to re-prove the bug on every run would be
pointless): with the auto-clear disabled and the old
outcome-in-(CANCELLED,NO_BID) raise still in place, setting a real
dependency (1054 -> 1056) then cancelling 1056 left 1054's dependency
untouched and POST /pursuits/1054/recalculate returned 409 naming
CANCELLED, writing nothing.

Fixtures (real AERO pursuits, Pre-BH, open, not already a dependent or
predecessor anywhere else -- confirmed live before choosing them):
  1054 (Sentinel Upgrade) -- the dependent
  1056 (Zephyr Phase II)  -- the predecessor

    python test_cancelled_predecessor.py --base http://localhost:8001 ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Requires the API running AND a live AWS session (recalculate calls the
real engine). Skipped, not failed, by run_tests.ps1 if either is
unavailable. Exit 0 = all passed.
"""
from __future__ import annotations

import argparse
import sys

import httpx
import psycopg
from psycopg.rows import dict_row

PASS, FAIL = [], []
TOL = 1e-4

DEP_UID = "1054"
PRED_UID = "1056"


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


def pursuit_row(db, uid):
    return db.execute("""
        SELECT id, outcome, depends_on_pursuit_id FROM pursuit
         WHERE external_opportunity_id = %s""", (uid,)).fetchone()


def current_row(db, pid, scenario):
    return db.execute("""
        SELECT id, pwin, base_pwin, blended_pwin, is_current
          FROM pwin_assessment
         WHERE pursuit_id = %s AND scenario = %s AND is_current""",
        (pid, scenario)).fetchone()


def undo_recalc(db, pid, scenario, original_id):
    """Same discipline as test_blended_pwin.py's own helper -- deletes
    only the pwin_assessment row THIS run's own /recalculate created
    (identified precisely: the current row now, if and only if it
    differs from the id captured before this run touched anything) and
    restores is_current onto the original row. original_id may be None
    (no prior row for this scenario) -- nothing to restore onto, just
    delete what this run created."""
    now = db.execute("""
        SELECT id FROM pwin_assessment
         WHERE pursuit_id = %s AND scenario = %s AND is_current""",
        (pid, scenario)).fetchone()
    if now and now["id"] != original_id:
        db.execute("DELETE FROM pwin_answer WHERE pwin_assessment_id = %s", (now["id"],))
        db.execute("DELETE FROM pwin_assessment WHERE id = %s", (now["id"],))
    if original_id is not None:
        db.execute("UPDATE pwin_assessment SET is_current = TRUE WHERE id = %s",
                    (original_id,))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    A = login(args.base, "aero.admin@demoaero.test")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        dep = pursuit_row(db, DEP_UID)
        pred = pursuit_row(db, PRED_UID)
    check(f"fixture pursuit {DEP_UID} exists", dep is not None)
    check(f"fixture pursuit {PRED_UID} exists", pred is not None)
    if not (dep and pred):
        print(f"\n{'='*58}\n{len(PASS)} passed, {len(FAIL)} failed")
        return 1

    check(f"{DEP_UID} fixture sanity: genuinely has no dependency yet",
          dep["depends_on_pursuit_id"] is None, f"got {dep['depends_on_pursuit_id']}")
    check(f"{PRED_UID} fixture sanity: genuinely open (no outcome) yet",
          pred["outcome"] is None, f"got {pred['outcome']}")

    # Captured BEFORE this run touches anything -- what the finally block
    # restores onto, and what proves this run's own writes were undone.
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        orig_base = current_row(db, dep["id"], "BASE")

    try:
        print("\n=== Setup: give 1054 a real, open dependency on 1056 ===")
        r = safe(A.patch, f"/api/pursuits/{dep['id']}",
                 json={"depends_on_opp_id": PRED_UID})
        check("PATCH depends_on_opp_id succeeds", r.status_code == 200,
              f"got {r.status_code}: {r.text}")

        r = safe(A.patch, f"/api/pursuits/{dep['id']}/answers",
                 json={"scenario": "DEPENDENT_WON", "answers": {"TM1A": "Same"}})
        check("saving a real DEPENDENT_WON answer succeeds (so there is a "
              "real is_current DEPENDENT_WON row for the orphan-demotion "
              "assertion below to actually exercise)",
              r.status_code == 200, f"got {r.status_code}: {r.text}")

        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            dw_before = current_row(db, dep["id"], "DEPENDENT_WON")
        check("the DEPENDENT_WON row genuinely is_current before cancelling",
              dw_before is not None and dw_before["is_current"],
              f"got {dw_before}")

        print("\n=== Cancelling the predecessor auto-clears the dependency ===")
        r = safe(A.post, f"/api/pursuits/{pred['id']}/outcome",
                 json={"outcome": "CANCELLED"})
        check("POST .../outcome CANCELLED succeeds", r.status_code == 200,
              f"got {r.status_code}: {r.text}")
        cleared = (r.json() or {}).get("dependents_cleared", [])
        check("the response names 1054 as an affected dependent -- not silent",
              any(d.get("external_opportunity_id") == DEP_UID for d in cleared),
              f"got {cleared}")

        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            dep_now = pursuit_row(db, DEP_UID)
            base_now = current_row(db, dep["id"], "BASE")
            dw_now = db.execute("""
                SELECT is_current FROM pwin_assessment
                 WHERE pursuit_id = %s AND scenario = 'DEPENDENT_WON'
                 ORDER BY calculated_at DESC LIMIT 1""", (dep["id"],)).fetchone()

        check("1054's depends_on_pursuit_id is genuinely NULL now",
              dep_now["depends_on_pursuit_id"] is None,
              f"got {dep_now['depends_on_pursuit_id']}")
        check("1054's current BASE row reverted: pwin == base_pwin",
              abs(float(base_now["pwin"]) - float(base_now["base_pwin"])) < TOL,
              f"pwin={base_now['pwin']} base_pwin={base_now['base_pwin']}")
        check("1054's current BASE row reverted: blended_pwin is NULL again",
              base_now["blended_pwin"] is None, f"got {base_now['blended_pwin']}")
        check("1054's DEPENDENT_WON row is demoted (is_current = FALSE), "
              "not deleted -- preserved as history",
              dw_now is not None and dw_now["is_current"] is False,
              f"got {dw_now}")

        print("\n=== The hard lock is genuinely gone: recalculate proceeds ===")
        r = safe(A.post, f"/api/pursuits/{dep['id']}/recalculate")
        check("POST .../recalculate succeeds (was a 409 before this fix)",
              r.status_code == 200, f"got {r.status_code}: {r.text}")
        row = r.json() if r.status_code == 200 else {}
        check("the recalculated pwin equals base_pwin (no dependency left "
              "to blend against)",
              row and abs(float(row.get("pwin", -1))
                         - float(row.get("base_pwin", -2))) < TOL,
              f"got {row}")

    finally:
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            # Delete the synthetic DEPENDENT_WON row this run created --
            # there is no API path that un-demotes/deletes an assessment,
            # so this is the one direct-SQL step, same exception this
            # session's own standing rule carves out for exactly this
            # case (no real write path exists to undo it).
            db.execute("""
                DELETE FROM pwin_answer WHERE pwin_assessment_id IN (
                    SELECT id FROM pwin_assessment
                     WHERE pursuit_id = %s AND scenario = 'DEPENDENT_WON')""",
                (dep["id"],))
            db.execute("""
                DELETE FROM pwin_assessment
                 WHERE pursuit_id = %s AND scenario = 'DEPENDENT_WON'""",
                (dep["id"],))
            undo_recalc(db, dep["id"], "BASE", orig_base["id"] if orig_base else None)
            db.commit()

        # Real write path for the rest: reopen the predecessor, clear the
        # dependency (idempotent -- already NULL if the auto-clear ran).
        safe(A.post, f"/api/pursuits/{pred['id']}/outcome", json={"outcome": None})
        safe(A.patch, f"/api/pursuits/{dep['id']}",
             json={"depends_on_opp_id": None})

        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            final_dep = pursuit_row(db, DEP_UID)
            final_pred = pursuit_row(db, PRED_UID)
            final_base = current_row(db, dep["id"], "BASE")
            final_dw = db.execute("""
                SELECT count(*) AS n FROM pwin_assessment
                 WHERE pursuit_id = %s AND scenario = 'DEPENDENT_WON'""",
                (dep["id"],)).fetchone()
        check("cleanup: 1054 has no dependency", final_dep["depends_on_pursuit_id"] is None)
        check("cleanup: 1056 is open again (outcome NULL)", final_pred["outcome"] is None)
        check("cleanup: 1054's current BASE row is the original one -- "
              "this run's own recalculation was undone, not left behind",
              (not orig_base) or (final_base and final_base["id"] == orig_base["id"]),
              f"got {final_base}")
        check("cleanup: 1054's synthetic DEPENDENT_WON row is gone",
              final_dw["n"] == 0, f"got {final_dw['n']} remaining")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Cancelled-predecessor auto-clear verified against real pursuits.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
