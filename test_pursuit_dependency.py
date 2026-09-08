#!/usr/bin/env python3
"""
test_pursuit_dependency.py -- the "Depends on" picker.

pursuit.depends_on_pursuit_id previously had NO edit path at all -- only
migrate_workbook.py's own import-time write direct to the column (see
this round's own investigation: write.py's PATCH endpoint flatly listed
it under "NOT writable here", and the frontend's "Depends on" field was
a fieldRow() misuse that produced an unescaped <b>...</b> string inside
an <input value="..."> attribute, which is why it rendered as literal
tags rather than bold text -- a broken DISPLAY, not a broken picker,
because no picker existed to break).

Candidates and validation are scoped to the CALLER's own real scope
(fn_user_pursuits), NOT the target pursuit's org node like Owner/POC --
a dependency can reasonably cross business units (plan_scope.py's own
note explains why). A self-dependency or a cycle is a 400, resolved by
resolve_pursuit_dependency.

Fixtures reused from test_scope.py / test_api_security.py's own
established set (idempotent, safe standalone or as part of the suite):
  aero.admin@demoaero.test  -- BUSINESS root, admin role (full scope)
  aero.bu2@demoaero.test    -- BU2, capture_manager (narrow, real pursuits)
  aero.div1@demoaero.test   -- DIV1, a DIFFERENT branch than BU2 -- used
                                to prove an out-of-scope target is rejected

    python test_pursuit_dependency.py --base http://localhost:8001 ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Requires the API running (real HTTP calls, same reasoning as
test_api_security.py / test_pursuit_owner.py: only the endpoint proves
scope is actually CHECKED, not just representable in the schema).
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    args = ap.parse_args()

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        aero = db.execute("SELECT id FROM client WHERE code='AERO'").fetchone()["id"]
        # Independent (no existing dependency) real pursuits, one per BU,
        # so this suite's own writes have a clean, known starting state
        # to restore -- same discipline as test_pursuit_owner.py's own
        # fixture selection.
        bu2_pursuit = db.execute("""
            SELECT p.id, p.external_opportunity_id AS uid FROM pursuit p
              JOIN org_node o ON o.id = p.org_node_id
             WHERE o.code = 'BU2' AND p.client_id = %s AND p.is_active
               AND p.outcome IS NULL AND p.depends_on_pursuit_id IS NULL
             LIMIT 1""", (aero,)).fetchone()
        bu2_pursuit2 = db.execute("""
            SELECT p.id, p.external_opportunity_id AS uid FROM pursuit p
              JOIN org_node o ON o.id = p.org_node_id
             WHERE o.code = 'BU2' AND p.client_id = %s AND p.is_active
               AND p.outcome IS NULL AND p.depends_on_pursuit_id IS NULL
               AND p.id != %s
             LIMIT 1""", (aero, bu2_pursuit["id"] if bu2_pursuit else None)).fetchone()
        div1_pursuit = db.execute("""
            SELECT p.id, p.external_opportunity_id AS uid FROM pursuit p
              JOIN org_node o ON o.id = p.org_node_id
             WHERE o.code = 'DIV1' AND p.client_id = %s AND p.is_active
               AND p.outcome IS NULL AND p.depends_on_pursuit_id IS NULL
             LIMIT 1""", (aero,)).fetchone()
        # Deliberately NOT filtered by outcome -- this is the baseline
        # "every active pursuit, open or closed" count, to prove
        # dependency_candidates' own open-only filter actually excludes
        # something real.
        n_active_all = db.execute("""
            SELECT count(*) AS n FROM pursuit
             WHERE client_id = %s AND is_active""",
            (aero,)).fetchone()["n"]

    if not bu2_pursuit or not bu2_pursuit2 or not div1_pursuit:
        check("two independent BU2 pursuits and one independent DIV1 "
              "pursuit exist to test against", False,
              f"bu2={bu2_pursuit}, bu2_2={bu2_pursuit2}, div1={div1_pursuit}")
        print(f"\n{'='*58}\n{len(PASS)} passed, {len(FAIL)} failed")
        return 1

    A = login(args.base, "aero.admin@demoaero.test")   # full scope
    N = login(args.base, "aero.bu2@demoaero.test")      # narrow: BU2 only

    # ---- 1. candidate list is scoped to the CALLER's own real scope ----
    print("=== 1. dependency candidate list is scoped correctly ===")
    n_boot = safe(N.get, "/api/bootstrap").json()
    a_boot = safe(A.get, "/api/bootstrap").json()
    n_cands = {c["uid"] for c in (n_boot.get("dependency_candidates") or [])}
    a_cands = {c["uid"] for c in (a_boot.get("dependency_candidates") or [])}
    check("BU2-scoped user's candidate list is non-empty",
          len(n_cands) > 0, f"got {len(n_cands)}")
    check("BU2-scoped user's candidate list includes their own BU2 "
          "pursuit", bu2_pursuit["uid"] in n_cands, f"got {len(n_cands)} candidates")
    check("BU2-scoped user's candidate list does NOT include a "
          "DIV1-only pursuit -- a different, unrelated branch",
          div1_pursuit["uid"] not in n_cands, f"got {len(n_cands)} candidates")
    check("the full-scope admin's candidate list is strictly larger "
          "than the narrow-scoped user's",
          len(a_cands) > len(n_cands),
          f"admin {len(a_cands)}, BU2-only {len(n_cands)}")
    check("candidates are OPEN pursuits only, not just 'every pursuit "
          "in scope' -- admin's candidate count is strictly less than "
          "every active pursuit in the tenant (closed ones excluded)",
          len(a_cands) < n_active_all, f"got {len(a_cands)} of {n_active_all}")

    # ---- 2. self-dependency is rejected -------------------------------
    print("\n=== 2. a pursuit cannot depend on itself ===")
    r = safe(N.patch, f"/api/pursuits/{bu2_pursuit['id']}",
             json={"depends_on_opp_id": bu2_pursuit["uid"]})
    check("PATCH with the pursuit's own opportunity id is rejected",
          r.status_code == 400, f"got {r.status_code}: {r.text}")

    # ---- 3. an out-of-scope target is rejected, not silently accepted -
    print("\n=== 3. an out-of-scope dependency target is rejected ===")
    r = safe(N.patch, f"/api/pursuits/{bu2_pursuit['id']}",
             json={"depends_on_opp_id": div1_pursuit["uid"]})
    check("PATCH with a DIV1 pursuit (outside N's BU2 scope) as the "
          "dependency target is rejected", r.status_code == 404,
          f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        after = db.execute("SELECT depends_on_pursuit_id FROM pursuit WHERE id=%s",
                           (bu2_pursuit["id"],)).fetchone()
    check("the rejected assignment was never written",
          after["depends_on_pursuit_id"] is None, f"got {after}")

    # ---- 4. a successful assignment writes, audits, and displays ------
    print("\n=== 4. a successful assignment writes correctly, shows in "
          "audit history, and displays in bootstrap ===")
    r = safe(N.patch, f"/api/pursuits/{bu2_pursuit['id']}",
             json={"depends_on_opp_id": bu2_pursuit2["uid"]})
    check("PATCH with an in-scope BU2 pursuit as the dependency target "
          "succeeds", r.status_code == 200, f"got {r.status_code}: {r.text}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        row = db.execute("SELECT depends_on_pursuit_id FROM pursuit WHERE id=%s",
                         (bu2_pursuit["id"],)).fetchone()
    check("the write actually landed in the database, pointing at the "
          "right pursuit",
          row and str(row["depends_on_pursuit_id"]) == str(bu2_pursuit2["id"]),
          f"got {row}")

    hist = safe(N.get, f"/api/pursuits/{bu2_pursuit['id']}/history").json()
    dep_entry = next((h for h in hist
                      if "depends_on_pursuit_id" in (h.get("changed_fields") or {})), None)
    check("the change appears in audit history", dep_entry is not None,
          f"got {[h.get('changed_fields') for h in hist[:3]]}")

    boot_after = safe(N.get, "/api/bootstrap").json()
    row2 = next((x for x in boot_after["pursuits"]
                if x["id"] == str(bu2_pursuit["id"])), None)
    check("the pursuit's dependency now shows in the bootstrap payload "
          "(pursuit detail view's data source), pointing at the right "
          "opportunity id",
          row2 is not None and row2.get("dep") == bu2_pursuit2["uid"],
          f"got {row2.get('dep') if row2 else None}")
    check("the dependency target's own DEPENDENT_WON questionnaire "
          "answers key is present (empty is fine -- never assessed yet "
          "-- but the key itself must exist for the frontend's scenario "
          "toggle to render without erroring)",
          row2 is not None and "dependent_won_answers" in row2,
          f"got {row2.keys() if row2 else None}")

    # ---- 5. a cycle is rejected, not silently accepted -----------------
    print("\n=== 5. a dependency cycle is rejected ===")
    r = safe(N.patch, f"/api/pursuits/{bu2_pursuit2['id']}",
             json={"depends_on_opp_id": bu2_pursuit["uid"]})
    check(f"{bu2_pursuit['uid']} now depends on {bu2_pursuit2['uid']} -- "
          f"setting {bu2_pursuit2['uid']} to depend back on "
          f"{bu2_pursuit['uid']} (a 2-cycle) is rejected",
          r.status_code == 400, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        after2 = db.execute("SELECT depends_on_pursuit_id FROM pursuit WHERE id=%s",
                            (bu2_pursuit2["id"],)).fetchone()
    check("the rejected cyclic assignment was never written",
          after2["depends_on_pursuit_id"] is None, f"got {after2}")

    # ---- 6. clearing an existing dependency (explicit null) succeeds --
    print("\n=== 6. clearing a dependency (explicit null) succeeds and "
          "is audited ===")
    r = safe(N.patch, f"/api/pursuits/{bu2_pursuit['id']}",
             json={"depends_on_opp_id": None})
    check("PATCH with depends_on_opp_id: null succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        cleared = db.execute("SELECT depends_on_pursuit_id FROM pursuit WHERE id=%s",
                             (bu2_pursuit["id"],)).fetchone()
    check("the dependency was actually cleared in the database",
          cleared["depends_on_pursuit_id"] is None, f"got {cleared}")
    hist2 = safe(N.get, f"/api/pursuits/{bu2_pursuit['id']}/history").json()
    clear_entries = [h for h in hist2
                     if "depends_on_pursuit_id" in (h.get("changed_fields") or {})]
    check("both the set and the clear appear in audit history",
          len(clear_entries) >= 2, f"got {len(clear_entries)} entries")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Pursuit Depends-on field verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
