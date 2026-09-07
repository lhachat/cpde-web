#!/usr/bin/env python3
"""
test_bhptw_phase_change.py -- three related bugs in the Post-BH/Post-PTW
phase transition, all fixed together since they touch the same path:

  Bug 1: Investment should become editable once a pursuit is past
         Pre-BH -- it was unconditionally locked ("derived") before,
         even though bhptw.py's submit endpoints are the real, correct
         place investment becomes analyst-owned.
  Bug 2: Margin / Bid price / Predicted Pwin should pre-populate from
         the already-answered questionnaire and the pursuit's own data
         the FIRST time a scenario's BH/PTW form is opened, not sit
         blank -- GET /api/pursuits/{id}/bhptw now returns a
         "defaults" object for exactly this.
  Bug 3: the frontend render path after a phase change -- covered
         separately, live, via Playwright (not practical to assert
         from a backend-only test file).

Uses the same known AERO pursuit (opp 1046,
33dab187-73dd-4c3e-8f66-cd5ffcd6fd72) verified throughout this
session's engine work: COST_PLUS, P1 "1% above normal" ->
0.065 + 0.01 = 0.075 fee, base_pwin 0.169275, award value
$125,400,000.00.

    python test_bhptw_phase_change.py --base http://localhost:8001 ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Exit 0 = all passed.
"""
from __future__ import annotations

import argparse
import sys

import httpx
import psycopg
from psycopg.rows import dict_row

PASS, FAIL = [], []

PURSUIT_ID = "33dab187-73dd-4c3e-8f66-cd5ffcd6fd72"


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        before = db.execute("""
            SELECT p.id, p.planned_investment, p.planned_total_award_value,
                   ps.code AS stage
              FROM pursuit p JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
             WHERE p.id = %s""", (PURSUIT_ID,)).fetchone()

    A = login(args.base, "aero.admin@demoaero.test")

    # ---- setup: make sure this pursuit is genuinely Pre-BH first -------
    if before["stage"] != "PRE_BH":
        r = safe(A.patch, f"/api/pursuits/{PURSUIT_ID}",
                 json={"pipeline_stage_code": "PRE_BH"})
        if r.status_code != 200:
            print(f"could not reset fixture pursuit to PRE_BH: {r.status_code} {r.text}")
            return 1

    try:
        # ---- 1. Investment is locked at Pre-BH, server-side too --------
        print("=== 1. Investment is genuinely TM5-derived at Pre-BH, not "
              "just hidden in the UI ===")
        r = safe(A.patch, f"/api/pursuits/{PURSUIT_ID}",
                 json={"planned_investment": 999999})
        check("PATCHing planned_investment at Pre-BH is rejected "
              "server-side (400), not silently accepted",
              r.status_code == 400, f"got {r.status_code}: {r.text}")

        # ---- 2. GET .../bhptw returns pre-populated defaults ------------
        print("\n=== 2. GET .../bhptw returns real, correct defaults for "
              "Margin / Bid price / Predicted Pwin -- pulled forward from "
              "the questionnaire and the pursuit's own data, not blank ===")
        boot = safe(A.get, "/api/bootstrap").json()
        r = next(x for x in boot["pursuits"] if x["id"] == PURSUIT_ID)
        check("fixture pursuit's contract is COST_PLUS with a real award "
              "value, matching this test's known values",
              r["contract"] == "Cost Plus"
              and abs(float(r["value"]) - 125400000.00) < 1,
              f"got contract={r.get('contract')} value={r.get('value')}")

        bh = safe(A.get, f"/api/pursuits/{PURSUIT_ID}/bhptw").json()
        defaults = bh.get("defaults") or {}
        check("defaults.margin_rate is the SAME live engine-served fee "
              "computation Pre-BH itself uses (0.065 COST_PLUS + 0.01 "
              "'1% above normal' = 0.075), not blank or a stale column",
              defaults.get("margin_rate") is not None
              and abs(float(defaults["margin_rate"]) - 0.075) < 1e-9,
              f"got {defaults.get('margin_rate')}")
        check("defaults.bid_price is the pursuit's real total award value "
              "($125,400,000.00)",
              defaults.get("bid_price") is not None
              and abs(float(defaults["bid_price"]) - 125400000.00) < 1,
              f"got {defaults.get('bid_price')}")
        check("defaults.base_pwin is the questionnaire's real calculated "
              "value (0.169275)",
              defaults.get("base_pwin") is not None
              and abs(float(defaults["base_pwin"]) - 0.169275) < 1e-9,
              f"got {defaults.get('base_pwin')}")
        check("defaults.investment reflects the pursuit's CURRENT "
              "planned_investment, not a hardcoded zero or None",
              defaults.get("investment") is not None
              and abs(float(defaults["investment"]) - float(before["planned_investment"])) < 1e-6,
              f"got {defaults.get('investment')}, expected {before['planned_investment']}")

        # ---- 3. Investment becomes editable, and PATCH-writable, once --
        #         the pursuit moves past Pre-BH ---------------------------
        print("\n=== 3. Investment becomes editable (server-side "
              "PATCH-writable) once the pursuit reaches Post-BH ===")
        r = safe(A.patch, f"/api/pursuits/{PURSUIT_ID}",
                 json={"pipeline_stage_code": "POST_BH"})
        check("phase change to Post-BH succeeds",
              r.status_code == 200, f"got {r.status_code}: {r.text}")

        r = safe(A.patch, f"/api/pursuits/{PURSUIT_ID}",
                 json={"planned_investment": 250000})
        check("PATCHing planned_investment at Post-BH is now accepted",
              r.status_code == 200, f"got {r.status_code}: {r.text}")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            after_patch = db.execute(
                "SELECT planned_investment FROM pursuit WHERE id = %s",
                (PURSUIT_ID,)).fetchone()
        check("the write actually landed",
              after_patch and abs(float(after_patch["planned_investment"]) - 250000) < 1,
              f"got {after_patch}")

        # ---- 4. submit_black_hat keeps planned_investment in sync -------
        print("\n=== 4. submitting a Black Hat assessment keeps "
              "pursuit.planned_investment in sync, the same way it "
              "already keeps planned_fee_rate in sync ===")
        p1 = None
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            p1 = db.execute("""
                SELECT o.code FROM question_option o
                  JOIN question q ON q.id = o.question_id
                 WHERE q.code = 'P1' AND o.label_text = '1% above normal'""").fetchone()
        r = safe(A.post, f"/api/pursuits/{PURSUIT_ID}/blackhat", json={
            "scenario": "BASE",
            "aggressiveness_option_code": p1["code"],
            "investment": 500000,
            "base_pwin": 0.30,
        })
        check("Black Hat submit succeeds", r.status_code == 200,
              f"got {r.status_code}: {r.text}")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            after_bh = db.execute(
                "SELECT planned_investment FROM pursuit WHERE id = %s",
                (PURSUIT_ID,)).fetchone()
        check("pursuit.planned_investment now reflects the Black Hat "
              "submission's own investment value ($500,000)",
              after_bh and abs(float(after_bh["planned_investment"]) - 500000) < 1,
              f"got {after_bh}")

    finally:
        # Restore the fixture pursuit exactly as found.
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            db.execute("""
                UPDATE pursuit SET planned_investment = %s,
                       pipeline_stage_id = (SELECT id FROM pipeline_stage WHERE code = %s)
                 WHERE id = %s""",
                (before["planned_investment"], before["stage"], PURSUIT_ID))
            db.execute("""
                DELETE FROM pwin_answer WHERE pwin_assessment_id IN (
                    SELECT id FROM pwin_assessment
                     WHERE pursuit_id = %s AND assessment_type = 'BLACK_HAT')""",
                (PURSUIT_ID,))
            db.execute("""
                DELETE FROM pwin_assessment
                 WHERE pursuit_id = %s AND assessment_type = 'BLACK_HAT'""",
                (PURSUIT_ID,))
            # A BASE questionnaire assessment must stay current -- restore
            # is_current on the most recent QUESTIONNAIRE row.
            db.execute("""
                UPDATE pwin_assessment SET is_current = TRUE
                 WHERE id = (SELECT id FROM pwin_assessment
                              WHERE pursuit_id = %s AND scenario = 'BASE'
                                AND assessment_type = 'QUESTIONNAIRE'
                              ORDER BY calculated_at DESC LIMIT 1)""",
                (PURSUIT_ID,))
            db.execute("UPDATE pursuit SET black_hat_ptw_complete = FALSE WHERE id = %s",
                      (PURSUIT_ID,))
            db.commit()

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("BH/PTW phase-change fixes verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
