#!/usr/bin/env python3
"""
test_cancelled_predecessor.py -- a CANCELLED or NO_BID predecessor must
auto-clear the dependency on every pursuit that depends on it, not
hard-lock them.

WHY: apply_dependency_blend() used to raise 409 for a CANCELLED or
NO_BID predecessor, blocking the dependent pursuit's own recalculate
and Black Hat/PTW submission until a human manually cleared the
dependency by hand. Confirmed against the real VBA source
(ClearDependencyRefs_) -- a predecessor reaching either outcome should
instead auto-clear depends_on_pursuit_id on every dependent, exactly
the same way the sole-source/LPTA reverse-transition auto-clear already
works (write.py's own dependency_cleared field). The dependent's Pwin
then reverts to its own Base Pwin via the ALREADY-BUILT no-dependency
case (blended_pwin stays NULL, pwin == base_pwin) -- no new blend math,
just the trigger (plan_scope.auto_clear_dependents_of_outcome).

CANCELLED was fixed first (2026-09-09); NO_BID was extended to the same
treatment later (2026-09-14) for consistency and defense in depth, not
because it was an active bug -- outcome='NO_BID' is a real, valid
`pursuit.outcome` CHECK-constraint value, but the live
/api/pursuits/{id}/outcome endpoint's own validator only ever accepts
WON/LOST/CANCELLED/null, so no real pursuit reaches NO_BID through the
running app's own outcome-setting endpoint. This test sets it directly
at the database level for its own NO_BID scenario, exactly as the RED
step for that fix did, to exercise apply_dependency_blend()/
auto_clear_dependents_of_outcome() against a real NO_BID predecessor
the same way the CANCELLED scenario exercises them through the real
API end to end.

RED (confirmed live before each fix existed, not re-exercised on every
run -- reverting the fix just to re-prove the bug each time would be
pointless): with auto-clear disabled and the old
outcome-in-(CANCELLED,NO_BID) raise still in place, setting a real
dependency then deciding the predecessor left the dependent's
dependency untouched and its own recalculate/apply_dependency_blend
call returned 409 naming the outcome, writing nothing. Confirmed for
CANCELLED via the live /recalculate endpoint (2026-09-09) and for
NO_BID via a direct call to apply_dependency_blend() itself
(2026-09-14, since apply_dependency_blend() runs after recalculate_pwin
already reached a live engine, and no live engine session was available
at RED-confirmation time for that scenario -- the function itself does
no engine/scoring work, so this is an equally direct test of the exact
code path under fix).

Fixtures (real AERO pursuits, Pre-BH, open, not already a dependent or
predecessor anywhere else -- confirmed live before choosing them):
  CANCELLED scenario: 1054 (Sentinel Upgrade, dependent) -> 1056 (Zephyr
    Phase II, predecessor)
  NO_BID scenario:    1059 (Pinnacle Follow-On, dependent) -> 1057
    (Trellis Modernization, predecessor)

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


def run_scenario(A, admin_dsn, outcome, dep_uid, pred_uid):
    """One full setup -> decide -> verify -> cleanup cycle for one
    outcome value (CANCELLED or NO_BID). CANCELLED is settable through
    the real /outcome endpoint; NO_BID is not (OutcomeIn's own
    validator rejects it), so that scenario decides the predecessor via
    a direct UPDATE instead -- the one legitimate way to reach that
    state at all today, exactly matching how this fix's own RED step
    was confirmed."""
    print(f"\n########## {outcome} PREDECESSOR ##########")
    settable_via_api = outcome == "CANCELLED"

    with psycopg.connect(admin_dsn, row_factory=dict_row) as db:
        dep = pursuit_row(db, dep_uid)
        pred = pursuit_row(db, pred_uid)
    check(f"fixture pursuit {dep_uid} exists", dep is not None)
    check(f"fixture pursuit {pred_uid} exists", pred is not None)
    if not (dep and pred):
        return

    check(f"{dep_uid} fixture sanity: genuinely has no dependency yet",
          dep["depends_on_pursuit_id"] is None, f"got {dep['depends_on_pursuit_id']}")
    check(f"{pred_uid} fixture sanity: genuinely open (no outcome) yet",
          pred["outcome"] is None, f"got {pred['outcome']}")

    # Captured BEFORE this run touches anything -- what the finally block
    # restores onto, and what proves this run's own writes were undone.
    with psycopg.connect(admin_dsn, row_factory=dict_row) as db:
        orig_base = current_row(db, dep["id"], "BASE")

    try:
        print(f"=== Setup: give {dep_uid} a real, open dependency on {pred_uid} ===")
        r = safe(A.patch, f"/api/pursuits/{dep['id']}",
                 json={"depends_on_opp_id": pred_uid})
        check("PATCH depends_on_opp_id succeeds", r.status_code == 200,
              f"got {r.status_code}: {r.text}")

        r = safe(A.patch, f"/api/pursuits/{dep['id']}/answers",
                 json={"scenario": "DEPENDENT_WON", "answers": {"TM1A": "Same"}})
        check("saving a real DEPENDENT_WON answer succeeds (so there is a "
              "real is_current DEPENDENT_WON row for the orphan-demotion "
              "assertion below to actually exercise)",
              r.status_code == 200, f"got {r.status_code}: {r.text}")

        with psycopg.connect(admin_dsn, row_factory=dict_row) as db:
            dw_before = current_row(db, dep["id"], "DEPENDENT_WON")
        check("the DEPENDENT_WON row genuinely is_current before deciding",
              dw_before is not None and dw_before["is_current"],
              f"got {dw_before}")

        print(f"=== Deciding the predecessor {outcome} auto-clears the dependency ===")
        if settable_via_api:
            r = safe(A.post, f"/api/pursuits/{pred['id']}/outcome",
                     json={"outcome": outcome})
            check(f"POST .../outcome {outcome} succeeds", r.status_code == 200,
                  f"got {r.status_code}: {r.text}")
            cleared = (r.json() or {}).get("dependents_cleared", [])
        else:
            # NO_BID is not reachable through OutcomeIn's own validator --
            # the one legitimate way to reach this state today is a direct
            # write, same as this fix's own RED confirmation. The auto-
            # clear itself still goes through the REAL production
            # function (plan_scope.auto_clear_dependents_of_outcome), run
            # inside the API container against the same database, rather
            # than a hand-copied SQL substitute here that could silently
            # drift from the real implementation over time.
            with psycopg.connect(admin_dsn, row_factory=dict_row) as db:
                db.execute("""
                    UPDATE pursuit SET outcome = %s, outcome_date = now()
                     WHERE id = %s""", (outcome, pred["id"]))
                client_id = db.execute(
                    "SELECT client_id FROM pursuit WHERE id = %s",
                    (pred["id"],)).fetchone()["client_id"]
                db.commit()

            import json
            import subprocess  # noqa: PLC0415 -- only needed on this branch

            script = (
                "import asyncio\n"
                "from app.db import tenant_tx\n"
                "from app.plan_scope import auto_clear_dependents_of_outcome\n"
                "async def main():\n"
                f"    with tenant_tx('{client_id}') as cur:\n"
                f"        cleared = auto_clear_dependents_of_outcome(cur, '{pred['id']}', None)\n"
                "    print('CLEARED_JSON:' + __import__('json').dumps("
                "[{'id': str(c['id']), 'external_opportunity_id': c['external_opportunity_id']} "
                "for c in cleared]))\n"
                "asyncio.run(main())\n"
            )
            proc = subprocess.run(
                ["docker", "exec", "-i", "cpde-api", "sh", "-c",
                 "PYTHONPATH=/srv python -"],
                input=script, capture_output=True, text=True)
            check("auto_clear_dependents_of_outcome() ran inside the API "
                  "container without error",
                  proc.returncode == 0, f"stderr: {proc.stderr}")
            cleared_line = next(
                (l for l in proc.stdout.splitlines() if l.startswith("CLEARED_JSON:")), "")
            cleared = json.loads(cleared_line[len("CLEARED_JSON:"):]) if cleared_line else []

        check(f"the auto-clear ran and named {dep_uid} as an affected "
              "dependent -- not silent",
              any(d.get("external_opportunity_id") == dep_uid for d in cleared),
              f"got {cleared}")

        with psycopg.connect(admin_dsn, row_factory=dict_row) as db:
            dep_now = pursuit_row(db, dep_uid)
            base_now = current_row(db, dep["id"], "BASE")
            dw_now = db.execute("""
                SELECT is_current FROM pwin_assessment
                 WHERE pursuit_id = %s AND scenario = 'DEPENDENT_WON'
                 ORDER BY calculated_at DESC LIMIT 1""", (dep["id"],)).fetchone()

        check(f"{dep_uid}'s depends_on_pursuit_id is genuinely NULL now",
              dep_now["depends_on_pursuit_id"] is None,
              f"got {dep_now['depends_on_pursuit_id']}")
        check(f"{dep_uid}'s current BASE row reverted: pwin == base_pwin",
              abs(float(base_now["pwin"]) - float(base_now["base_pwin"])) < TOL,
              f"pwin={base_now['pwin']} base_pwin={base_now['base_pwin']}")
        check(f"{dep_uid}'s current BASE row reverted: blended_pwin is NULL again",
              base_now["blended_pwin"] is None, f"got {base_now['blended_pwin']}")
        check(f"{dep_uid}'s DEPENDENT_WON row is demoted (is_current = FALSE), "
              "not deleted -- preserved as history",
              dw_now is not None and dw_now["is_current"] is False,
              f"got {dw_now}")

        print("=== The hard lock is genuinely gone: recalculate proceeds ===")
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
        with psycopg.connect(admin_dsn, row_factory=dict_row) as db:
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

        # Real write path for the dependent's own dependency, either way.
        safe(A.patch, f"/api/pursuits/{dep['id']}",
             json={"depends_on_opp_id": None})
        if settable_via_api:
            safe(A.post, f"/api/pursuits/{pred['id']}/outcome", json={"outcome": None})
        else:
            # No real write path reopens a NO_BID pursuit either (the
            # endpoint that WOULD do this is the same one that can never
            # set NO_BID in the first place) -- direct SQL, same carve-out
            # as the DEPENDENT_WON row above.
            with psycopg.connect(admin_dsn, row_factory=dict_row) as db:
                db.execute("""
                    UPDATE pursuit SET outcome = NULL, outcome_date = NULL
                     WHERE id = %s""", (pred["id"],))
                db.commit()

        with psycopg.connect(admin_dsn, row_factory=dict_row) as db:
            final_dep = pursuit_row(db, dep_uid)
            final_pred = pursuit_row(db, pred_uid)
            final_base = current_row(db, dep["id"], "BASE")
            final_dw = db.execute("""
                SELECT count(*) AS n FROM pwin_assessment
                 WHERE pursuit_id = %s AND scenario = 'DEPENDENT_WON'""",
                (dep["id"],)).fetchone()
        check(f"cleanup: {dep_uid} has no dependency",
              final_dep["depends_on_pursuit_id"] is None)
        check(f"cleanup: {pred_uid} is open again (outcome NULL)",
              final_pred["outcome"] is None)
        check(f"cleanup: {dep_uid}'s current BASE row is the original one -- "
              "this run's own recalculation was undone, not left behind",
              (not orig_base) or (final_base and final_base["id"] == orig_base["id"]),
              f"got {final_base}")
        check(f"cleanup: {dep_uid}'s synthetic DEPENDENT_WON row is gone",
              final_dw["n"] == 0, f"got {final_dw['n']} remaining")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    A = login(args.base, "aero.admin@demoaero.test")

    run_scenario(A, args.admin_dsn, "CANCELLED", "1054", "1056")
    run_scenario(A, args.admin_dsn, "NO_BID", "1059", "1057")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Cancelled/NO_BID-predecessor auto-clear verified against real pursuits.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
