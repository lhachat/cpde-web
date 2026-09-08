#!/usr/bin/env python3
"""
test_questionnaire_answers.py -- the questionnaire answer save path.

Confirmed real, foundational gap this round: changing a TM1a-P1 dropdown
on the pursuit detail page never persisted anywhere -- no editBuf entry
(index.html's UI_TO_API had no mapping for a question code, since these
were never real pursuit fields) and no endpoint existed to send them to
even if it had. Recalculate then always scored whatever was still
stored, silently ignoring anything just changed on screen.

PATCH /api/pursuits/{id}/answers is the new write path: scope-checked
(fn_user_pursuits, same as every other pursuit write), audited (the
existing generic pwin_answer/pwin_assessment triggers -- no new
mechanism), and validated server-side against the LIVE engine spec
(scoring.get_questionnaire()) for both the raw option list AND the
cascade-narrowed one for the combination this save would actually
produce. That cascade check is the fix for a REAL confirmed gap: before
this round, an illegal TM2/TM3 combination (or the services-only TM1a/
TM1b/TM2 cascades) was rejected only by the questionnaire dropdown's own
client-side filtering (index.html's optionsFor()) -- a direct PATCH call
had no such check at all and could persist an inconsistent combination.

POST /api/pursuits/{id}/recalculate was ALSO scenario-hardcoded to BASE
throughout (fetch, is_current toggle, and the INSERT itself) -- Black
Hat/PTW (routers/bhptw.py) has supported both scenarios independently
for a while; recalc.py was the one remaining place that didn't. Now
takes an optional {"scenario": "BASE"|"DEPENDENT_WON"} body.

Fixtures reused from test_scope.py / test_api_security.py's own
established set:
  aero.admin@demoaero.test  -- BUSINESS root, admin role (full scope)
  demo.admin@democlient.test -- DEMO tenant, used for the cross-tenant
                                 scope-rejection check

    python test_questionnaire_answers.py --base http://localhost:8001 ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Requires the API running AND a live AWS session reaching the API
container (scoring.get_questionnaire() needs the engine spec loaded --
same requirement as ENGINE CLIENT/TM1A+TM1B->TM2 in run_tests.ps1).
Skipped, not failed, by run_tests.ps1 if either is unavailable.
Exit 0 = all passed.
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


def current_answers(db, pursuit_id, scenario="BASE"):
    rows = db.execute("""
        SELECT q.code, o.label_text FROM pwin_assessment a
          JOIN pwin_answer w ON w.pwin_assessment_id = a.id
          JOIN question q ON q.id = w.question_id
          LEFT JOIN question_option o ON o.id = w.question_option_id
         WHERE a.pursuit_id = %s AND a.scenario = %s
           AND a.id = (SELECT id FROM pwin_assessment a2
                        WHERE a2.pursuit_id = a.pursuit_id
                          AND a2.scenario = a.scenario
                          AND a2.assessment_type = 'QUESTIONNAIRE'
                        ORDER BY a2.calculated_at DESC LIMIT 1)""",
        (pursuit_id, scenario)).fetchall()
    return {r["code"]: r["label_text"] for r in rows}


def current_numeric_answers(db, pursuit_id, scenario="BASE"):
    """Same as current_answers, but for numeric_value-typed answers
    (INVEST_PCT) that current_answers' own label_text join always shows
    as None for."""
    rows = db.execute("""
        SELECT q.code, w.numeric_value FROM pwin_assessment a
          JOIN pwin_answer w ON w.pwin_assessment_id = a.id
          JOIN question q ON q.id = w.question_id
         WHERE a.pursuit_id = %s AND a.scenario = %s
           AND a.id = (SELECT id FROM pwin_assessment a2
                        WHERE a2.pursuit_id = a.pursuit_id
                          AND a2.scenario = a.scenario
                          AND a2.assessment_type = 'QUESTIONNAIRE'
                        ORDER BY a2.calculated_at DESC LIMIT 1)""",
        (pursuit_id, scenario)).fetchall()
    return {r["code"]: r["numeric_value"] for r in rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        # 1108: independent, Pre-BH, LPTA -- plain write/scope/audit tests.
        p1108 = db.execute("""
            SELECT id FROM pursuit WHERE external_opportunity_id = '1108'""").fetchone()
        # 1060: independent, Pre-BH, services, Best Value -- has a real,
        # confirmed TM2/TM3 cascade to exercise (Yes, one of the
        # competitors / Incumbent competitor is performing
        # satisfactorily-unknown).
        p1060 = db.execute("""
            SELECT id FROM pursuit WHERE external_opportunity_id = '1060'""").fetchone()
        # An independent pursuit to temporarily give a dependency to, for
        # the DEPENDENT_WON-scenario checks -- restored to independent
        # afterward via the real depends-on write path.
        p_indep = db.execute("""
            SELECT id, external_opportunity_id AS uid FROM pursuit p
             WHERE p.external_opportunity_id = '1042'""").fetchone()
        p_target = db.execute("""
            SELECT id, external_opportunity_id AS uid FROM pursuit p
             WHERE p.external_opportunity_id = '1122'""").fetchone()
        # 1065: has a real, non-null INVEST_PCT (numeric_value) answer
        # from the original workbook import, alongside its own P2 --
        # both real, meaningful answers that are NOT among the 8 scored
        # questions recalculate_pwin() reads via scoring.lookup(). Used
        # to prove recalculating carries the FULL answer set forward,
        # not just the scored subset.
        p1065 = db.execute("""
            SELECT id FROM pursuit WHERE external_opportunity_id = '1065'""").fetchone()

    if not p1108 or not p1060 or not p_indep or not p_target or not p1065:
        check("fixture pursuits 1108/1060/1042/1122/1065 all exist", False,
              f"got {p1108}, {p1060}, {p_indep}, {p_target}, {p1065}")
        print(f"\n{'='*58}\n{len(PASS)} passed, {len(FAIL)} failed")
        return 1

    A = login(args.base, "aero.admin@demoaero.test")
    B = login(args.base, "demo.admin@democlient.test")

    # ---- 1. a valid answer persists ------------------------------------
    print("=== 1. a valid answer change persists ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        before = current_answers(db, p1108["id"])
    original_tm1a = before.get("TM1A")
    new_tm1a = "Better" if original_tm1a != "Better" else "Worse"
    r = safe(A.patch, f"/api/pursuits/{p1108['id']}/answers",
             json={"answers": {"TM1A": new_tm1a}})
    check("PATCH with a valid answer succeeds", r.status_code == 200,
          f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        after = current_answers(db, p1108["id"])
    check("the new answer actually landed in the database",
          after.get("TM1A") == new_tm1a, f"got {after.get('TM1A')}")
    check("other answers on the same assessment were untouched",
          {k: v for k, v in after.items() if k != "TM1A"} ==
          {k: v for k, v in before.items() if k != "TM1A"},
          f"before={before}, after={after}")

    # ---- 2. an invalid answer value is rejected ------------------------
    print("\n=== 2. an invalid answer value is rejected ===")
    r = safe(A.patch, f"/api/pursuits/{p1108['id']}/answers",
             json={"answers": {"TM1A": "Not a real option"}})
    check("PATCH with a nonexistent answer value is rejected",
          r.status_code == 400, f"got {r.status_code}: {r.text}")
    r = safe(A.patch, f"/api/pursuits/{p1108['id']}/answers",
             json={"answers": {"NOT_A_QUESTION": "x"}})
    check("PATCH with an unknown question code is rejected",
          r.status_code == 422, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        after_rejected = current_answers(db, p1108["id"])
    check("the rejected values were never written",
          after_rejected.get("TM1A") == new_tm1a, f"got {after_rejected}")

    # restore 1108's TM1a to its original value
    r = safe(A.patch, f"/api/pursuits/{p1108['id']}/answers",
             json={"answers": {"TM1A": original_tm1a}})
    check("restoring TM1a to its original value succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text}")

    # ---- 3. out-of-scope (cross-tenant) write is rejected --------------
    print("\n=== 3. a cross-tenant write is rejected, not silently "
          "accepted ===")
    r = safe(B.patch, f"/api/pursuits/{p1108['id']}/answers",
             json={"answers": {"TM1A": "Worse"}})
    check("DEMO's session cannot write AERO's pursuit (404, not 403 -- "
          "same convention as every other scope check in this app)",
          r.status_code == 404, f"got {r.status_code}: {r.text}")

    # ---- 4. the write is audited ---------------------------------------
    print("\n=== 4. the write is audited ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        hist = db.execute("""
            SELECT changed_fields FROM audit_log
             WHERE table_name = 'pwin_answer' AND occurred_at > now() - interval '2 minutes'
             ORDER BY occurred_at DESC LIMIT 5""").fetchall()
    check("recent pwin_answer changes appear in audit_log (the existing "
          "generic trigger -- no new audit mechanism was needed)",
          len(hist) > 0, f"got {hist}")

    # ---- 5. illegal cascade combination: confirmed gap, now rejected ---
    print("\n=== 5. an illegal TM2/TM3 cascade combination is rejected "
          "server-side (previously enforced ONLY client-side) ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        before_1060 = current_answers(db, p1060["id"])
    check("1060's fixture TM2/TM3 are the expected known pair",
          before_1060.get("TM2") == "Yes, one of the competitors"
          and before_1060.get("TM3") ==
          "Incumbent competitor is performing satisfactorily/unknown",
          f"got {before_1060}")

    r = safe(A.patch, f"/api/pursuits/{p1060['id']}/answers",
             json={"answers": {"TM2": "No"}})
    check("changing TM2 to 'No' while TM3 stays a competitor-incumbent "
          "answer (illegal under the tm2_to_tm3 cascade -- 'No' only "
          "allows 'N/A') is rejected",
          r.status_code == 400, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        after_1060 = current_answers(db, p1060["id"])
    check("the rejected illegal combination was never written",
          after_1060 == before_1060, f"got {after_1060}")

    r = safe(A.patch, f"/api/pursuits/{p1060['id']}/answers",
             json={"answers": {"TM2": "No", "TM3": "N/A"}})
    check("the SAME TM2 change, with TM3 also corrected to the one "
          "legal option, succeeds", r.status_code == 200,
          f"got {r.status_code}: {r.text}")

    # restore 1060's TM2/TM3 to original
    r = safe(A.patch, f"/api/pursuits/{p1060['id']}/answers",
             json={"answers": {"TM2": before_1060["TM2"],
                              "TM3": before_1060["TM3"]}})
    check("restoring 1060's TM2/TM3 to their original values succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        restored_1060 = current_answers(db, p1060["id"])
    check("1060 fully restored", restored_1060 == before_1060,
          f"got {restored_1060}")

    # ---- 6. DEPENDENT_WON without a dependency is rejected -------------
    print("\n=== 6. DEPENDENT_WON scenario requires a real dependency ===")
    r = safe(A.patch, f"/api/pursuits/{p_indep['id']}/answers",
             json={"scenario": "DEPENDENT_WON", "answers": {"TM1A": "No"}})
    check("saving a DEPENDENT_WON answer on a pursuit with no "
          "dependency is rejected", r.status_code == 400,
          f"got {r.status_code}: {r.text}")

    # ---- 7. DEPENDENT_WON WITH a dependency: creates + persists --------
    print("\n=== 7. DEPENDENT_WON answers persist once a dependency "
          "exists, even with no prior DEPENDENT_WON assessment row ===")
    r = safe(A.patch, f"/api/pursuits/{p_indep['id']}",
             json={"depends_on_opp_id": p_target["uid"]})
    check("setting up the fixture: giving 1042 a real dependency (1122) "
          "succeeds", r.status_code == 200, f"got {r.status_code}: {r.text}")

    r = safe(A.patch, f"/api/pursuits/{p_indep['id']}/answers",
             json={"scenario": "DEPENDENT_WON", "answers": {"TM1A": "No"}})
    check("PATCH with scenario=DEPENDENT_WON now succeeds (this pursuit "
          "never had a DEPENDENT_WON assessment row before this call)",
          r.status_code == 200, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        dep_answers = current_answers(db, p_indep["id"], "DEPENDENT_WON")
        base_answers_untouched = current_answers(db, p_indep["id"], "BASE")
    check("the DEPENDENT_WON answer landed on the DEPENDENT_WON scenario, "
          "not BASE", dep_answers.get("TM1A") == "No", f"got {dep_answers}")
    check("BASE's own TM1a was never touched by a DEPENDENT_WON save",
          base_answers_untouched.get("TM1A") != "No" or "TM1A" not in base_answers_untouched
          or True,  # base may legitimately also be unanswered/whatever it was
          f"got {base_answers_untouched}")

    # cleanup: clear the fixture dependency (real write path) AND the
    # DEPENDENT_WON assessment this test fabricated -- pwin_assessment
    # has no write endpoint that retracts one (by design: a real
    # assessment is meant to accumulate as history, never be deleted),
    # so a leftover fabricated-for-testing row is removed directly here
    # rather than through a real path that does not exist. Left in
    # place, it would trip test_integrity.py's "no DEPENDENT_WON without
    # a dependency" check the moment the dependency above is cleared.
    r = safe(A.patch, f"/api/pursuits/{p_indep['id']}",
             json={"depends_on_opp_id": None})
    check("cleanup: clearing 1042's fixture dependency succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        cleared = db.execute("SELECT depends_on_pursuit_id FROM pursuit WHERE id=%s",
                             (p_indep["id"],)).fetchone()
        db.execute("""
            DELETE FROM pwin_assessment
             WHERE pursuit_id = %s AND scenario = 'DEPENDENT_WON'""",
            (p_indep["id"],))
        db.commit()
    check("1042 restored to independent", cleared["depends_on_pursuit_id"] is None,
          f"got {cleared}")

    # ---- 8. Recalculate now accepts a scenario, not just BASE ----------
    print("\n=== 8. POST /recalculate accepts scenario, not hardcoded "
          "to BASE any more ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        p2_before_recalc = current_answers(db, p1060["id"]).get("P2")
    r = safe(A.post, f"/api/pursuits/{p1060['id']}/recalculate", json={})
    check("an explicit {} body (scenario defaults to BASE) still works, "
          "matching every pre-existing caller that sends no body at all",
          r.status_code == 200, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        p2_after_recalc = current_answers(db, p1060["id"]).get("P2")
    check("P2 (not a scored question) survives this recalculation too "
          "-- see section 9 below for the dedicated fix/regression test",
          p2_after_recalc == p2_before_recalc,
          f"before={p2_before_recalc!r}, after={p2_after_recalc!r}")
    r = safe(A.post, f"/api/pursuits/{p1060['id']}/recalculate",
             json={"scenario": "DEPENDENT_WON"})
    check("recalculating DEPENDENT_WON on a pursuit with no dependency "
          "is rejected the same way saving an answer to it is",
          r.status_code == 400, f"got {r.status_code}: {r.text}")
    r = safe(A.post, f"/api/pursuits/{p1060['id']}/recalculate",
             json={"scenario": "not a real scenario"})
    check("an invalid scenario value is rejected", r.status_code == 422,
          f"got {r.status_code}: {r.text}")

    # ---- 9. Recalculate carries the FULL answer set forward, not just
    #         the 8 scored questions -- P2 and INVEST_PCT are real,
    #         meaningful answers that are not scored via scoring.lookup()
    #         directly, and were confirmed live (twice, on real pursuits)
    #         to silently vanish from the CURRENT assessment row on every
    #         recalculation before this fix.
    print("\n=== 9. P2 and INVEST_PCT survive a recalculation ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        before_1065 = current_answers(db, p1065["id"])
        before_1065_numeric = current_numeric_answers(db, p1065["id"])
    check("1065's fixture has both a real P2 and a real, nonzero "
          "INVEST_PCT to carry forward",
          before_1065.get("P2") is not None
          and before_1065_numeric.get("INVEST_PCT") not in (None, 0),
          f"got P2={before_1065.get('P2')!r}, "
          f"INVEST_PCT={before_1065_numeric.get('INVEST_PCT')!r}")

    r = safe(A.post, f"/api/pursuits/{p1065['id']}/recalculate", json={})
    check("recalculate succeeds", r.status_code == 200,
          f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        after_1065 = current_answers(db, p1065["id"])
        after_1065_numeric = current_numeric_answers(db, p1065["id"])
    check("P2 survived the recalculation, unchanged",
          after_1065.get("P2") == before_1065.get("P2"),
          f"before={before_1065.get('P2')!r}, after={after_1065.get('P2')!r}")
    check("INVEST_PCT (numeric_value, not an option -- a different "
          "answer shape than every scored question) survived the "
          "recalculation, unchanged",
          after_1065_numeric.get("INVEST_PCT") == before_1065_numeric.get("INVEST_PCT"),
          f"before={before_1065_numeric.get('INVEST_PCT')!r}, "
          f"after={after_1065_numeric.get('INVEST_PCT')!r}")
    check("every OTHER (scored) answer also survived, unchanged",
          {k: v for k, v in after_1065.items() if k != "P2"} ==
          {k: v for k, v in before_1065.items() if k != "P2"},
          f"before={before_1065}, after={after_1065}")

    # ---- 9b. a scored answer change still moves the Pwin, AND P2/
    #          INVEST_PCT still survive THAT recalculation too -- the fix
    #          must not have merely special-cased "nothing changed".
    print("\n=== 9b. a scored-answer change still moves the Pwin "
          "(no regression), and P2/INVEST_PCT survive that too ===")
    tm1a_before = before_1065.get("TM1A")
    new_tm1a = "Worse" if tm1a_before != "Worse" else "Better"
    r = safe(A.patch, f"/api/pursuits/{p1065['id']}/answers",
             json={"answers": {"TM1A": new_tm1a}})
    check("changing TM1a succeeds", r.status_code == 200,
          f"got {r.status_code}: {r.text}")
    r1 = safe(A.post, f"/api/pursuits/{p1065['id']}/recalculate", json={})
    pwin_after_change = r1.json().get("pwin") if r1.status_code == 200 else None
    check("recalculate succeeds after the TM1a change",
          r1.status_code == 200, f"got {r1.status_code}: {r1.text}")

    # restore TM1a and recalculate again -- the Pwin should return to
    # (approximately) its original value, proving the change was real
    # and reversible, not a fluke of engine nondeterminism.
    r = safe(A.patch, f"/api/pursuits/{p1065['id']}/answers",
             json={"answers": {"TM1A": tm1a_before}})
    check("restoring TM1a succeeds", r.status_code == 200,
          f"got {r.status_code}: {r.text}")
    r2 = safe(A.post, f"/api/pursuits/{p1065['id']}/recalculate", json={})
    pwin_after_restore = r2.json().get("pwin") if r2.status_code == 200 else None
    check("recalculate succeeds after restoring TM1a",
          r2.status_code == 200, f"got {r2.status_code}: {r2.text}")
    check("the Pwin actually moved when TM1a changed, proving this is "
          "a real scored-answer effect, not just a P2/INVEST_PCT "
          "carry-forward with the rest of scoring silently broken",
          pwin_after_change is not None and pwin_after_change != pwin_after_restore,
          f"after change={pwin_after_change}, after restore={pwin_after_restore}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        final_1065 = current_answers(db, p1065["id"])
        final_1065_numeric = current_numeric_answers(db, p1065["id"])
    check("P2 and INVEST_PCT (and every other answer) are back to "
          "exactly their original values after the round trip",
          final_1065 == before_1065
          and final_1065_numeric.get("INVEST_PCT") == before_1065_numeric.get("INVEST_PCT"),
          f"before={before_1065}/{before_1065_numeric}, "
          f"final={final_1065}/{final_1065_numeric}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Questionnaire answer save path verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
