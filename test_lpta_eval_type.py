#!/usr/bin/env python3
"""
test_lpta_eval_type.py -- eval_type sent to the engine must be derived
from the pursuit's real, stored P2 answer, never a hardcoded literal.

Confirmed real bug: recalc.py's engine payload previously hardcoded
"eval_type": "Best Value" unconditionally, for every pursuit, regardless
of its actual P2 answer. The engine's own dap_solver.solve_all_daps has
a genuinely different, verified code path for EvalType.LPTA (DAP =
bid price, tech/mgmt/pp excluded entirely -- see cda-engine's own
test_lpta_dap_equals_bid_price) versus EvalType.BEST_VALUE (solve_dap(),
which uses the tech/mgmt/pp differential). Every real LPTA pursuit's
Pwin was being computed as if it were a competitive Best Value
evaluation. Wrong since recalculation was first built (v0.2.0,
2026-08-28) until this fix.

This exact class of bug -- a literal standing in for a real lookup --
has shown up more than once this session (Owner/POC's missing
UI_TO_API entry, the hardcoded scenario='BASE' throughout recalc.py).
This test locks down THIS specific instance: it recalculates a real
LPTA pursuit and a real Best Value pursuit and asserts the actual
persisted engine_request (the JSONB payload recalculate_pwin() sent,
not a guess at it) names the correct eval_type for each -- not just
"the Pwin changed", which a coincidence could mask, but the literal
value sent to the engine.

Fixtures (real AERO pursuits, both genuinely Pre-BH and OPEN -- verified
directly, not assumed, after an earlier draft of this test picked 1027
by name alone and it turned out to be POST_PTW/WON, not Pre-BH):
  1055 -- Inlet Program, Pre-BH, open, real P2=LPTA answer
  1060 -- Ridgeline Upgrade, Pre-BH, open, real P2=Best Value answer

    python test_lpta_eval_type.py --base http://localhost:8001 ^
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


def sent_eval_type(db, pursuit_id):
    """The eval_type actually persisted in engine_request on the
    pursuit's current BASE assessment -- what recalculate_pwin() really
    sent to the engine, not what the code merely intends to send."""
    row = db.execute("""
        SELECT engine_request->>'eval_type' AS eval_type
          FROM pwin_assessment
         WHERE pursuit_id = %s AND scenario = 'BASE' AND is_current""",
        (pursuit_id,)).fetchone()
    return row["eval_type"] if row else None


def current_id(db, pursuit_id):
    row = db.execute("""
        SELECT id FROM pwin_assessment
         WHERE pursuit_id = %s AND scenario = 'BASE' AND is_current""",
        (pursuit_id,)).fetchone()
    return row["id"] if row else None


def undo_recalc(db, pursuit_id, original_id):
    """Deletes the pwin_assessment row /recalculate created for this
    pursuit during this test run (identified precisely: the current row
    now, only if it differs from the id captured BEFORE this test ever
    called /recalculate) and restores is_current onto the original row.
    finally-block only -- this test's own repeated runs were
    accumulating permanent history otherwise (confirmed live: 1055/1060
    had 42/50 pwin_assessment rows before this fix, purely from re-runs
    of this suite and test_blended_pwin.py)."""
    if original_id is None:
        return
    now_id = current_id(db, pursuit_id)
    if now_id is None or now_id == original_id:
        return
    db.execute("DELETE FROM pwin_answer WHERE pwin_assessment_id = %s", (now_id,))
    db.execute("DELETE FROM pwin_assessment WHERE id = %s", (now_id,))
    db.execute("UPDATE pwin_assessment SET is_current = TRUE WHERE id = %s",
               (original_id,))


def p2_answer(db, uid):
    return db.execute("""
        SELECT o.label_text FROM pwin_assessment a
          JOIN pwin_answer w ON w.pwin_assessment_id = a.id
          JOIN question q ON q.id = w.question_id AND q.code = 'P2'
          JOIN question_option o ON o.id = w.question_option_id
         WHERE a.pursuit_id = (SELECT id FROM pursuit
                                 WHERE external_opportunity_id = %s)
           AND a.scenario = 'BASE' AND a.is_current""",
        (uid,)).fetchone()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        p_lpta = db.execute(
            "SELECT id FROM pursuit WHERE external_opportunity_id = '1055'").fetchone()
        p_bv = db.execute(
            "SELECT id FROM pursuit WHERE external_opportunity_id = '1060'").fetchone()

    if not p_lpta or not p_bv:
        check("fixture pursuits 1055 (LPTA) and 1060 (Best Value) exist",
              False, f"got {p_lpta}, {p_bv}")
        print(f"\n{'='*58}\n{len(PASS)} passed, {len(FAIL)} failed")
        return 1

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        lpta_answer = p2_answer(db, "1055")
        bv_answer = p2_answer(db, "1060")
    check("1055's real, stored P2 answer is genuinely LPTA (fixture "
          "sanity, not assumed)",
          lpta_answer and lpta_answer["label_text"] == "LPTA",
          f"got {lpta_answer}")
    check("1060's real, stored P2 answer is genuinely Best Value "
          "(fixture sanity, not assumed)",
          bv_answer and bv_answer["label_text"] == "Best Value",
          f"got {bv_answer}")

    A = login(args.base, "aero.admin@demoaero.test")

    # Captured BEFORE either /recalculate call -- what the finally block
    # below restores each pursuit's current BASE row back onto.
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        orig_lpta_id = current_id(db, p_lpta["id"])
        orig_bv_id = current_id(db, p_bv["id"])

    try:
        print("\n=== eval_type sent to the engine matches the real stored "
              "P2 answer, not a hardcoded literal ===")
        r = safe(A.post, f"/api/pursuits/{p_lpta['id']}/recalculate", json={})
        check("recalculating the real LPTA pursuit succeeds",
              r.status_code == 200, f"got {r.status_code}: {r.text}")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            sent = sent_eval_type(db, p_lpta["id"])
        check("the engine_request ACTUALLY PERSISTED for the LPTA pursuit "
              "names eval_type='LPTA' -- not the old hardcoded 'Best Value' "
              "literal, and not just asserted from the code, read back from "
              "what was really sent",
              sent == "LPTA", f"got {sent!r}")

        r = safe(A.post, f"/api/pursuits/{p_bv['id']}/recalculate", json={})
        check("recalculating the real Best Value pursuit succeeds",
              r.status_code == 200, f"got {r.status_code}: {r.text}")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            sent_bv = sent_eval_type(db, p_bv["id"])
        check("the engine_request for the Best Value pursuit still names "
              "eval_type='Best Value' -- proves this isn't just a second "
              "hardcoded literal ('always LPTA' would also make the first "
              "check above pass)",
              sent_bv == "Best Value", f"got {sent_bv!r}")
    finally:
        # Unconditional, direct-SQL -- runs even if a check above raised.
        # Deletes only the row(s) THIS run created (see undo_recalc's own
        # docstring for exactly how that's identified) and restores each
        # pursuit's original current row -- so running this suite twice
        # in a row never accumulates a second run's worth of rows.
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            undo_recalc(db, p_lpta["id"], orig_lpta_id)
            undo_recalc(db, p_bv["id"], orig_bv_id)
            db.commit()
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            final_lpta_id = current_id(db, p_lpta["id"])
            final_bv_id = current_id(db, p_bv["id"])
        check("cleanup: 1055's current BASE row is the original one -- "
              "this run's own recalculation was undone, not left behind",
              orig_lpta_id is None or final_lpta_id == orig_lpta_id,
              f"got {final_lpta_id}, expected {orig_lpta_id}")
        check("cleanup: 1060's current BASE row is the original one",
              orig_bv_id is None or final_bv_id == orig_bv_id,
              f"got {final_bv_id}, expected {orig_bv_id}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("LPTA eval_type derivation verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
