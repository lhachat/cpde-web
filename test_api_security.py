#!/usr/bin/env python3
"""
test_api_security.py -- Security assertions at the API layer.

DIFFERENT FROM THE DATABASE SUITES. test_isolation.py and test_scope.py prove
Postgres enforces isolation. They cannot prove the API asks the right
question. RLS has no defence against being told the wrong tenant, and the
scope predicate has no effect on an endpoint that forgets to apply it.

The vulnerability class here:
  - tenant taken from something the caller controls
  - an id in a URL path that is not scope-checked (IDOR)
  - a write that accepts client_id or org_node_id from the payload
  - a filter parameter that widens the result set instead of narrowing it
  - an endpoint reachable without a session
  - a role check missing on a privileged action

    python test_api_security.py --base http://localhost:8001 ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Requires two tenants loaded and the API running. Exit 0 = all passed.
"""
from __future__ import annotations

import argparse
import sys

import httpx
import psycopg
from psycopg.rows import dict_row

PASS, FAIL = [], []


def safe(fn, *a, **kw):
    """A crashed server must fail an assertion, not abort the suite."""
    try:
        return fn(*a, **kw)
    except Exception as e:          # noqa: BLE001 -- deliberately broad
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
    ap.add_argument("--user-a", default="aero.admin@demoaero.test")
    ap.add_argument("--user-b", default="demo.admin@democlient.test")
    ap.add_argument("--user-narrow", default="aero.bu2@demoaero.test")
    args = ap.parse_args()

    # Facts about the data, read directly so the tests do not depend on the
    # API being correct to know what correct looks like.
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        rows = db.execute("""
            SELECT c.code, p.id, p.external_opportunity_id, p.name
              FROM pursuit p JOIN client c ON c.id = p.client_id
             WHERE p.outcome IS NULL
             ORDER BY c.code, p.planned_total_award_value DESC""").fetchall()
        # NOTE: row_factory=dict_row yields dicts, so dict(rows) would give
        # {'code': 'count'}. Build it explicitly.
        counts = {r["code"]: r["n"] for r in db.execute("""
            SELECT c.code, count(*) AS n FROM pursuit p
              JOIN client c ON c.id = p.client_id GROUP BY c.code""").fetchall()}
    a_pursuit = next(r for r in rows if r["code"] == "AERO")
    b_pursuit = next(r for r in rows if r["code"] == "DEMO")
    print(f"Tenants: {counts}\n")

    # A BU-scoped fixture user, same pattern test_scope.py already uses for
    # aero.div1 -- AERO's BU (Advanced Systems) has DIV1 beneath it, so this
    # is a real BU-scoped user with a real division in their own subtree,
    # needed to test the Dashboard scope selector's "BU-scoped: rollup or a
    # specific division" tier. Idempotent (ON CONFLICT DO NOTHING), so safe
    # to run standalone or as part of the full suite.
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        db.execute("""
            INSERT INTO app_user (client_id, email, display_name)
            SELECT c.id, 'aero.bu1@demoaero.test', 'Aero BU1 Capture Mgr'
              FROM client c WHERE c.code = 'AERO'
            ON CONFLICT (client_id, email) DO NOTHING""")
        db.execute("""
            INSERT INTO user_scope_assignment (user_id, org_node_id, role_id)
            SELECT u.id, o.id, r.id
              FROM app_user u
              JOIN org_node o ON o.client_id = u.client_id AND o.code = 'BU'
              JOIN role r ON r.code = 'capture_manager'
             WHERE u.email = 'aero.bu1@demoaero.test'
            ON CONFLICT (user_id, org_node_id, role_id) DO NOTHING""")
        # A genuinely empty org node -- BU2, DIV1/2/3 all hold real
        # pursuits now (AERO's org structure grew real content), so none
        # of them can prove "narrow scope excludes" any more. A fixture
        # BU, sibling of BU/BU2 directly under the root -- not a child of
        # either, since BU has exactly three real divisions and BU2
        # deliberately has none (the Dashboard picker's one-level-branch
        # test relies on that). Same fixture test_scope.py creates --
        # idempotent, safe if both run.
        db.execute("""
            INSERT INTO org_node (client_id, parent_id, node_type, code,
                                  name, is_license_boundary)
            SELECT c.id, o.id, 'business_unit', 'BUZ', 'Zero-Pursuit Test BU', true
              FROM client c JOIN org_node o ON o.client_id = c.id AND o.code = 'BUSINESS'
             WHERE c.code = 'AERO'
            ON CONFLICT (client_id, code) DO NOTHING""")
        db.execute("""
            INSERT INTO app_user (client_id, email, display_name)
            SELECT c.id, 'aero.buz@demoaero.test', 'Aero Empty-BU Capture Mgr'
              FROM client c WHERE c.code = 'AERO'
            ON CONFLICT (client_id, email) DO NOTHING""")
        db.execute("""
            INSERT INTO user_scope_assignment (user_id, org_node_id, role_id)
            SELECT u.id, o.id, r.id
              FROM app_user u
              JOIN org_node o ON o.client_id = u.client_id AND o.code = 'BUZ'
              JOIN role r ON r.code = 'capture_manager'
             WHERE u.email = 'aero.buz@demoaero.test'
            ON CONFLICT (user_id, org_node_id, role_id) DO NOTHING""")
        db.commit()

    A = login(args.base, args.user_a)          # AERO admin
    B = login(args.base, args.user_b)          # DEMO admin
    # BU2 now holds 27 real pursuits (AERO's org structure grew real
    # content -- see plan_scope's dashboard rollup round), so N is no
    # longer an EMPTY scope, just a narrow one. It still correctly
    # excludes any pursuit outside BU2, which is all the tests below it
    # actually need -- only the "sees literally nothing" check needs a
    # genuinely empty scope, which DZ (the empty test-fixture BU)
    # provides instead.
    N = login(args.base, args.user_narrow)     # AERO, scoped to BU2 (27 real pursuits)
    DV = login(args.base, "aero.div1@demoaero.test")  # AERO, scoped to DIV1
    U1 = login(args.base, "aero.bu1@demoaero.test")   # AERO, scoped to BU
    DZ = login(args.base, "aero.buz@demoaero.test")   # AERO, scoped to a genuinely empty BU

    # ---- 1. nothing is reachable without a session --------------------
    print("=== 1. authentication required ===")
    anon = httpx.Client(base_url=args.base, timeout=30)
    for path in ("/api/bootstrap", "/api/pursuits", "/api/dashboard",
                 "/api/plan-years", "/api/markets", "/api/staffing/demand",
                 "/api/staffing/summary", "/api/audit",
                 f"/api/pursuits/{a_pursuit['id']}"):
        r = safe(anon.get, path)
        check(f"GET {path} without a session", r.status_code == 401,
              f"got {r.status_code}")
    r = safe(anon.patch, f"/api/pursuits/{a_pursuit['id']}/bid", json={"bid": False})
    check("PATCH bid without a session", r.status_code == 401,
          f"got {r.status_code}")

    # ---- 2. cross-tenant reads ---------------------------------------
    print("\n=== 2. cross-tenant read is a 404, not a 403 or a record ===")
    r = safe(A.get, f"/api/pursuits/{b_pursuit['id']}")
    check("AERO cannot GET a DEMO pursuit by id", r.status_code == 404,
          f"got {r.status_code}: {r.text[:120]}")
    r = safe(B.get, f"/api/pursuits/{a_pursuit['id']}")
    check("DEMO cannot GET an AERO pursuit by id", r.status_code == 404,
          f"got {r.status_code}")

    a_boot = safe(A.get, "/api/bootstrap").json()
    b_boot = safe(B.get, "/api/bootstrap").json()
    a_ids = {p["opp_id"] for p in a_boot["pursuits"]}
    b_ids = {p["opp_id"] for p in b_boot["pursuits"]}
    check("bootstrap payloads report different clients",
          a_boot["client"]["code"] != b_boot["client"]["code"],
          f"{a_boot['client']} vs {b_boot['client']}")
    check("AERO sees the expected pursuit count",
          len(a_boot["pursuits"]) == counts.get("AERO"),
          f"{len(a_boot['pursuits'])} vs {counts.get('AERO')}")
    check("DEMO sees the expected pursuit count",
          len(b_boot["pursuits"]) == counts.get("DEMO"),
          f"{len(b_boot['pursuits'])} vs {counts.get('DEMO')}")
    check("no pursuit name appears in both payloads",
          not ({p["name"] for p in a_boot["pursuits"]} &
               {p["name"] for p in b_boot["pursuits"]}),
          "overlapping names -- verify manually, could be coincidence")

    # ---- 3. the caller cannot choose their tenant ---------------------
    print("\n=== 3. tenant cannot be influenced by the caller ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        demo_cid = db.execute(
            "SELECT id FROM client WHERE code='DEMO'").fetchone()["id"]
    for attempt, kwargs in [
        ("query string", {"params": {"client_id": str(demo_cid)}}),
        ("header", {"headers": {"X-Client-Id": str(demo_cid)}}),
        ("header (alt)", {"headers": {"X-Tenant": "DEMO"}}),
    ]:
        r = safe(A.get, "/api/bootstrap", **kwargs)
        got = r.json().get("client", {}).get("code") if r.status_code == 200 else None
        check(f"AERO stays AERO despite a forged tenant in the {attempt}",
              got == "AERO", f"became {got}")

    # ---- 4. scope, not just tenancy ----------------------------------
    print("\n=== 4. business-unit scope is enforced on reads ===")
    dz_boot = safe(DZ.get, "/api/bootstrap").json()
    check("a genuinely empty scope sees no pursuits",
          len(dz_boot["pursuits"]) == 0,
          f"saw {len(dz_boot['pursuits'])} from a division that holds none")
    n_boot = safe(N.get, "/api/bootstrap").json()
    check("narrow-scope (BU2) user sees strictly fewer pursuits than the "
          "tenant total (BU2's own 27, not the whole AERO tenant's)",
          0 < len(n_boot["pursuits"]) < counts["AERO"],
          f"saw {len(n_boot['pursuits'])} of {counts['AERO']} total AERO pursuits")
    r = safe(N.get, f"/api/pursuits/{a_pursuit['id']}")
    check("narrow-scope user cannot GET an out-of-scope pursuit in the same tenant",
          r.status_code == 404, f"got {r.status_code}")

    # ---- 5. writes ---------------------------------------------------
    print("\n=== 5. writes respect tenancy and scope ===")
    r = safe(A.patch, f"/api/pursuits/{b_pursuit['id']}/bid", json={"bid": False})
    check("AERO cannot flip a DEMO pursuit's bid decision", r.status_code == 404,
          f"got {r.status_code}")
    r = safe(A.patch, f"/api/pursuits/{b_pursuit['id']}", json={"name": "hijacked"})
    check("AERO cannot PATCH a DEMO pursuit", r.status_code == 404,
          f"got {r.status_code}")
    r = safe(N.patch, f"/api/pursuits/{a_pursuit['id']}/bid", json={"bid": False})
    check("narrow-scope user cannot flip an out-of-scope pursuit",
          r.status_code == 404, f"got {r.status_code}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        before = db.execute(
            "SELECT name, bid_decision FROM pursuit WHERE id=%s",
            (b_pursuit["id"],)).fetchone()
    check("the DEMO pursuit was not modified by any of the above",
          before["name"] == b_pursuit["name"],
          f"name is now {before['name']!r}")

    # ---- 6. payload cannot smuggle a tenant or a scope move -----------
    print("\n=== 6. payload cannot rewrite ownership ===")
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}",
                json={"name": a_pursuit["name"], "client_id": str(demo_cid)})
    ok = r.status_code in (200, 400, 422)
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        still = db.execute("""SELECT c.code FROM pursuit p
                              JOIN client c ON c.id=p.client_id
                             WHERE p.id=%s""", (a_pursuit["id"],)).fetchone()
    check("client_id in the payload is ignored", ok and still["code"] == "AERO",
          f"status {r.status_code}, tenant now {still['code']}")

    # ---- 7. validation is enforced, not advisory ---------------------
    print("\n=== 7. business rules hold on write ===")
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}",
                json={"is_sole_source": True, "bidders": 4})
    check("sole source with 4 bidders is rejected", r.status_code == 400,
          f"got {r.status_code}")
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}",
                json={"proposal_due_date": "2020-01-01",
                      "bp_start_date": "2029-01-01"})
    check("out-of-order dates are rejected", r.status_code == 400,
          f"got {r.status_code}")
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}", json={"bidders": 0})
    check("zero bidders is rejected", r.status_code == 422,
          f"got {r.status_code}")
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}", json={"bid_decision": "MAYBE"})
    check("an invalid bid decision is rejected", r.status_code == 422,
          f"got {r.status_code}")

    # ---- 8. closed pursuits are history ------------------------------
    print("\n=== 8. closed pursuits cannot be rewritten ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        closed = db.execute("""
            SELECT p.id FROM pursuit p JOIN client c ON c.id=p.client_id
             WHERE c.code='AERO' AND p.outcome IS NOT NULL LIMIT 1""").fetchone()
    if closed:
        r = safe(A.patch, f"/api/pursuits/{closed['id']}", json={"name": "rewrite"})
        check("a closed pursuit rejects edits", r.status_code == 409,
              f"got {r.status_code}")
        r = safe(A.patch, f"/api/pursuits/{closed['id']}/bid", json={"bid": False})
        # 409, not 404: the pursuit exists and is in scope, it is simply
        # closed. 404 would be wrong here -- the caller is entitled to know
        # the difference between "no such pursuit" and "that one is history".
        check("a closed pursuit rejects a bid change", r.status_code == 409,
              f"got {r.status_code}")

    # ---- 9. role checks ----------------------------------------------
    print("\n=== 9. privileged actions require a role ===")
    r = safe(N.put, "/api/plan-years/2027", json={"revenue_target": 1})
    check("a capture manager cannot set targets", r.status_code == 403,
          f"got {r.status_code}")
    r = safe(N.get, "/api/audit")
    check("a capture manager cannot read the audit log", r.status_code == 403,
          f"got {r.status_code}")

    # ---- 9b. plan-year writes persist and are audited ------------------
    # Uses B (DEMO admin) with an explicit org_node_id. Every admin in
    # this system is scope-assigned at their tenant's root "BUSINESS"
    # node (confirmed directly against user_scope_assignment, not
    # assumed), so root-scope inclusion (9d) means EVERY admin -- DEMO's
    # included -- now sees at least two candidates (the whole business
    # plus their one BU) and a bare PUT with no org_node_id correctly
    # 409s as ambiguous. That is the endpoint working as designed, not a
    # bug -- it is the same "choose the entire business" capability
    # applying uniformly, not something AERO-specific. This section only
    # cares about persistence/audit behavior, so it targets DEMO's BU
    # explicitly rather than relying on implicit single-candidate
    # resolution that no longer exists for any admin.
    print("\n=== 9b. plan-year writes persist and are audited ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        demo_bu_for_9b = db.execute("""
            SELECT o.id FROM org_node o JOIN client c ON c.id = o.client_id
             WHERE c.code = 'DEMO' AND o.is_license_boundary LIMIT 1""").fetchone()
    test_year = 2099   # implausible enough to never collide with real data
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        n_before = db.execute("SELECT count(*) AS n FROM audit_log").fetchone()["n"]
    r = safe(B.put, f"/api/plan-years/{test_year}?org_node_id={demo_bu_for_9b['id']}",
             json={"revenue_target": 12345678})
    check("admin can PUT a plan-year", r.status_code == 200,
          f"got {r.status_code}: {r.text[:150]}")
    r2 = safe(B.get, f"/api/plan-years?org_node_id={demo_bu_for_9b['id']}")
    found = None
    if r2.status_code == 200:
        body2 = r2.json()
        years_list = body2.get("years", []) if isinstance(body2, dict) else body2
        found = next((row for row in years_list
                     if row.get("calendar_year") == test_year), None)
    check("the written value reads back via GET /api/plan-years",
          found is not None and float(found.get("revenue_target") or 0) == 12345678,
          f"got {found}")
    # The row was just created, so THAT write's audit entry logs the whole
    # new row under "new" (there is no "before" to diff against) -- correct
    # trigger behavior, not what we're checking. A second write to the
    # SAME (now-existing) row is a genuine UPDATE and should show a
    # proper before/after diff for the changed field.
    r3 = safe(B.put, f"/api/plan-years/{test_year}?org_node_id={demo_bu_for_9b['id']}",
              json={"revenue_target": 87654321})
    check("a second write to the same year succeeds", r3.status_code == 200,
          f"got {r3.status_code}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        n_after = db.execute("SELECT count(*) AS n FROM audit_log").fetchone()["n"]
        last = db.execute("""
            SELECT action, changed_fields FROM audit_log
             WHERE table_name = 'plan_year' ORDER BY occurred_at DESC LIMIT 1
        """).fetchone()
    check("the plan-year write was audited", n_after > n_before,
          f"{n_before} -> {n_after}")
    check("the update's audit row shows a before/after diff for revenue_target",
          bool(last and last["action"] == "UPDATE"
               and (last["changed_fields"] or {}).get("revenue_target", {}).get("from") == 12345678
               and (last["changed_fields"] or {}).get("revenue_target", {}).get("to") == 87654321),
          f"recorded {last}")
    # Clean up -- this test year must never linger and pollute the real plan.
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        db.execute("DELETE FROM plan_year WHERE calendar_year = %s", (test_year,))
        db.commit()

    # ---- 9c. plan-year multi-BU disambiguation -------------------------
    # A is AERO admin -- two license-boundary BUs (BU, BU2) visible.
    print("\n=== 9c. plan-year multi-BU disambiguation ===")

    r = safe(A.get, "/api/plan-years")
    body = r.json() if r.status_code == 200 else {}
    check("GET /api/plan-years for a multi-BU user is not a bare, "
          "unmarked list -- it signals ambiguity explicitly",
          r.status_code == 200 and isinstance(body, dict) and body.get("ambiguous") is True,
          f"got {r.status_code}: {r.text[:200]}")
    get_candidates = body.get("candidates") if isinstance(body, dict) else None
    check("the ambiguous GET response lists the real candidate BUs",
          isinstance(get_candidates, list) and len(get_candidates) >= 2
          and all({"id", "code", "name"} <= set(c) for c in get_candidates),
          f"got {get_candidates}")

    test_year2 = 2098   # a second implausible year, distinct from 9b's
    r = safe(A.put, f"/api/plan-years/{test_year2}", json={"revenue_target": 1})
    detail = r.json().get("detail") if r.status_code == 409 else None
    put_candidates = detail.get("candidates") if isinstance(detail, dict) else None
    check("PUT with no org_node_id for a multi-BU user 409s with a "
          "candidate list, not just a plain error string",
          r.status_code == 409 and isinstance(put_candidates, list)
          and len(put_candidates) >= 2
          and all({"id", "code", "name"} <= set(c) for c in put_candidates),
          f"got {r.status_code}: {r.text[:300]}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        aero_bu = db.execute("""
            SELECT o.id FROM org_node o JOIN client c ON c.id = o.client_id
             WHERE c.code = 'AERO' AND o.code = 'BU'""").fetchone()
        demo_bu = db.execute("""
            SELECT o.id FROM org_node o JOIN client c ON c.id = o.client_id
             WHERE c.code = 'DEMO' AND o.is_license_boundary LIMIT 1""").fetchone()

    r = safe(A.put, f"/api/plan-years/{test_year2}?org_node_id={aero_bu['id']}",
             json={"revenue_target": 11111111})
    check("PUT with a valid org_node_id from the candidate set succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text[:200]}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        written = db.execute("""
            SELECT org_node_id, revenue_target FROM plan_year
             WHERE calendar_year = %s AND org_node_id = %s""",
            (test_year2, aero_bu["id"])).fetchone()
    check("the write landed on the SPECIFIED business unit's plan_year "
          "row, not an arbitrary one",
          written is not None and float(written["revenue_target"]) == 11111111,
          f"got {written}")

    r = safe(A.put, f"/api/plan-years/{test_year2}?org_node_id={demo_bu['id']}",
             json={"revenue_target": 99999})
    check("PUT with an org_node_id outside the user's scope is rejected, "
          "not silently accepted", r.status_code in (403, 404),
          f"got {r.status_code}: {r.text[:200]}")

    r = safe(B.get, f"/api/plan-years?org_node_id={aero_bu['id']}")
    check("GET with an org_node_id outside the caller's scope is "
          "rejected, not silently accepted (DEMO admin, AERO's BU id)",
          r.status_code in (403, 404), f"got {r.status_code}: {r.text[:200]}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        db.execute("DELETE FROM plan_year WHERE calendar_year = %s", (test_year2,))
        db.commit()

    # ---- 9d. whole-business (root org node) scope ----------------------
    # A (aero.admin) is scoped directly to AERO's root "BUSINESS" node,
    # not just to a license-boundary BU beneath it -- picking the whole
    # business, not just a sub-BU, must be a valid target scope too.
    print("\n=== 9d. whole-business scope is a valid target ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        aero_root = db.execute("""
            SELECT o.id, o.code FROM org_node o JOIN client c ON c.id = o.client_id
             WHERE c.code = 'AERO' AND o.parent_id IS NULL""").fetchone()
        demo_root = db.execute("""
            SELECT o.id FROM org_node o JOIN client c ON c.id = o.client_id
             WHERE c.code = 'DEMO' AND o.parent_id IS NULL""").fetchone()

    r = safe(A.get, "/api/plan-years")
    root_candidates = (r.json() or {}).get("candidates") if r.status_code == 200 else None
    check("the tenant's root (whole-business) org node is offered as a "
          "candidate alongside the license-boundary BUs",
          isinstance(root_candidates, list)
          and any(c.get("id") == str(aero_root["id"]) for c in root_candidates),
          f"got {root_candidates}")

    test_year3 = 2097
    r = safe(A.put, f"/api/plan-years/{test_year3}?org_node_id={aero_root['id']}",
             json={"revenue_target": 22222222})
    check("PUT with the root org_node_id succeeds (nothing structurally "
          "requires a license-boundary node)",
          r.status_code == 200, f"got {r.status_code}: {r.text[:200]}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        written = db.execute("""
            SELECT org_node_id, revenue_target FROM plan_year
             WHERE calendar_year = %s AND org_node_id = %s""",
            (test_year3, aero_root["id"])).fetchone()
    check("the write landed on a plan_year row keyed to the ROOT node's "
          "org_node_id, not a license-boundary BU",
          written is not None and float(written["revenue_target"]) == 22222222,
          f"got {written}")

    # NOTE: demo.admin is ALSO scope-assigned directly to DEMO's root
    # "BUSINESS" node (confirmed via user_scope_assignment, same pattern
    # as AERO's admin) -- there is no admin in this system scoped only to
    # a single BU beneath the root. So "whole business" selectability is
    # not AERO-specific: it now correctly applies to DEMO's admin too.
    r = safe(B.get, "/api/plan-years")
    b_body = r.json() if r.status_code == 200 else {}
    b_candidates = b_body.get("candidates") if isinstance(b_body, dict) else None
    check("DEMO's admin also gets the whole-business option now, "
          "consistent with AERO -- not a single-BU-only exception",
          r.status_code == 200 and b_body.get("ambiguous") is True
          and isinstance(b_candidates, list)
          and any(c.get("id") == str(demo_root["id"]) for c in b_candidates),
          f"got {r.status_code}: {r.text[:250]}")
    r = safe(B.get, f"/api/plan-years?org_node_id={demo_root['id']}")
    check("DEMO's admin can explicitly select their own root node",
          r.status_code == 200 and (r.json() or {}).get("org_node_id") == str(demo_root["id"]),
          f"got {r.status_code}: {r.text[:200]}")
    r = safe(A.get, f"/api/plan-years?org_node_id={demo_root['id']}")
    check("AERO's admin still cannot use DEMO's root node -- cross-tenant "
          "root access is still rejected",
          r.status_code in (403, 404), f"got {r.status_code}: {r.text[:200]}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        db.execute("DELETE FROM plan_year WHERE calendar_year = %s", (test_year3,))
        db.commit()

    # ---- 10. the audit trail actually records ------------------------
    print("\n=== 10. writes are audited ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        n_before = db.execute("SELECT count(*) AS n FROM audit_log").fetchone()["n"]
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}/bid", json={"bid": False})
    ok_write = r.status_code == 200
    safe(A.patch, f"/api/pursuits/{a_pursuit['id']}/bid", json={"bid": True})  # restore
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        n_after = db.execute("SELECT count(*) AS n FROM audit_log").fetchone()["n"]
        last = db.execute("""
            SELECT a.action, a.table_name, a.changed_fields, a.user_id
              FROM audit_log a ORDER BY a.occurred_at DESC LIMIT 1""").fetchone()
    check("the bid change succeeded", ok_write, f"got {r.status_code}")
    check("audit rows were written", n_after > n_before,
          f"{n_before} -> {n_after}")
    check("the change is attributed to a user",
          bool(last and last["user_id"]), "actor is null")
    check("the audit row names the changed field",
          bool(last and "bid_decision" in (last["changed_fields"] or {})),
          f"recorded {list((last or {}).get('changed_fields') or {})}")

    # ---- 11b. Black Hat / PTW endpoints -------------------------------
    print("\n=== 11b. Black Hat / PTW respect tenancy, scope and rules ===")
    r = safe(anon.post, f"/api/pursuits/{a_pursuit['id']}/blackhat",
             json={"aggressiveness_option_code": "NORMAL", "base_pwin": 0.5})
    check("POST blackhat without a session", r.status_code == 401,
          f"got {r.status_code}")
    r = safe(anon.post, f"/api/pursuits/{a_pursuit['id']}/ptw",
             json={"margin_rate": 0.1, "bid_price": 1, "base_pwin": 0.5})
    check("POST ptw without a session", r.status_code == 401,
          f"got {r.status_code}")

    r = safe(A.post, f"/api/pursuits/{b_pursuit['id']}/blackhat",
             json={"aggressiveness_option_code": "NORMAL", "base_pwin": 0.5})
    check("AERO cannot POST blackhat for a DEMO pursuit", r.status_code == 404,
          f"got {r.status_code}")
    r = safe(A.post, f"/api/pursuits/{b_pursuit['id']}/ptw",
             json={"margin_rate": 0.1, "bid_price": 1, "base_pwin": 0.5})
    check("AERO cannot POST ptw for a DEMO pursuit", r.status_code == 404,
          f"got {r.status_code}")

    r = safe(N.post, f"/api/pursuits/{a_pursuit['id']}/blackhat",
             json={"aggressiveness_option_code": "NORMAL", "base_pwin": 0.5})
    check("narrow-scope user cannot POST blackhat for an out-of-scope pursuit",
          r.status_code == 404, f"got {r.status_code}")

    r = safe(A.post, f"/api/pursuits/{a_pursuit['id']}/ptw",
             json={"margin_rate": 0.5, "bid_price": 1, "base_pwin": 0.5})
    check("PTW margin above 30% is rejected", r.status_code == 422,
          f"got {r.status_code}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        no_q = db.execute("""
            SELECT p.id FROM pursuit p JOIN client c ON c.id=p.client_id
             WHERE c.code='AERO' AND p.outcome IS NULL
               AND NOT EXISTS (SELECT 1 FROM pwin_assessment a
                                 WHERE a.pursuit_id=p.id
                                   AND a.assessment_type='QUESTIONNAIRE')
             LIMIT 1""").fetchone()
    if no_q:
        r = safe(A.post, f"/api/pursuits/{no_q['id']}/ptw",
                 json={"margin_rate": 0.1, "bid_price": 1, "base_pwin": 0.5})
        check("PTW refuses a pursuit with no prior questionnaire assessment",
              r.status_code == 400, f"got {r.status_code}")

    if closed:
        r = safe(A.post, f"/api/pursuits/{closed['id']}/ptw",
                 json={"margin_rate": 0.1, "bid_price": 1, "base_pwin": 0.5})
        check("a closed pursuit rejects a PTW submission", r.status_code == 409,
              f"got {r.status_code}")

    # ---- 11c. Recalculate Pwin respects tenancy, scope and rules -----
    print("\n=== 11c. Recalculate Pwin respects tenancy, scope and rules ===")
    r = safe(anon.post, f"/api/pursuits/{a_pursuit['id']}/recalculate")
    check("POST recalculate without a session", r.status_code == 401,
          f"got {r.status_code}")
    r = safe(anon.post, f"/api/pursuits/{a_pursuit['id']}/recalculate/preview",
             json={"answers": {}})
    check("POST recalculate/preview without a session", r.status_code == 401,
          f"got {r.status_code}")

    r = safe(A.post, f"/api/pursuits/{b_pursuit['id']}/recalculate")
    check("AERO cannot POST recalculate for a DEMO pursuit", r.status_code == 404,
          f"got {r.status_code}")
    r = safe(N.post, f"/api/pursuits/{a_pursuit['id']}/recalculate")
    check("narrow-scope user cannot POST recalculate for an out-of-scope pursuit",
          r.status_code == 404, f"got {r.status_code}")
    r = safe(N.post, f"/api/pursuits/{a_pursuit['id']}/recalculate/preview",
             json={"answers": {}})
    check("narrow-scope user cannot POST recalculate/preview for an "
          "out-of-scope pursuit", r.status_code == 404, f"got {r.status_code}")

    r = safe(A.post, f"/api/pursuits/{a_pursuit['id']}/recalculate/preview",
             json={"answers": {"NOT_A_REAL_CODE": "x"}})
    check("recalculate/preview rejects an unscored question code",
          r.status_code == 422, f"got {r.status_code}")

    if closed:
        r = safe(A.post, f"/api/pursuits/{closed['id']}/recalculate")
        check("a closed pursuit rejects recalculate", r.status_code == 409,
              f"got {r.status_code}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        sole = db.execute("""
            SELECT p.id FROM pursuit p JOIN client c ON c.id=p.client_id
             WHERE c.code='AERO' AND p.outcome IS NULL
               AND p.is_sole_source LIMIT 1""").fetchone()
        post_bh = db.execute("""
            SELECT p.id FROM pursuit p
              JOIN client c ON c.id=p.client_id
              JOIN pipeline_stage ps ON ps.id=p.pipeline_stage_id
             WHERE c.code='AERO' AND p.outcome IS NULL
               AND NOT p.is_sole_source AND ps.code <> 'PRE_BH'
             LIMIT 1""").fetchone()
    if sole:
        r = safe(A.post, f"/api/pursuits/{sole['id']}/recalculate")
        check("a sole source pursuit rejects recalculate", r.status_code == 400,
              f"got {r.status_code}")
    if post_bh:
        r = safe(A.post, f"/api/pursuits/{post_bh['id']}/recalculate")
        check("a Post-BH/PTW pursuit rejects recalculate "
              "(would regress its assessment_type)", r.status_code == 400,
              f"got {r.status_code}")

    # ---- 11d. pursuit_history resolves every FK_LOOKUP column type ---
    # Regression test for a real bug: _resolve_fk_labels once assumed
    # every FK_LOOKUP column was a UUID (id = ANY(%s::uuid[])), which
    # 500'd for the SMALLSERIAL-keyed lookup tables (contract_type,
    # opportunity_type, pipeline_stage). Fixed by casting the COLUMN to
    # text instead of the parameter to uuid[] -- a single shared query
    # template, so the fix is type-agnostic across every FK_LOOKUP
    # column. This changes all four PATCHable ref codes in ONE call so a
    # single audit row carries both a uuid-keyed FK (market_id) and three
    # smallint-keyed ones (opportunity_type_id, contract_type_id,
    # pipeline_stage_id) simultaneously -- exactly the code path that
    # broke, not one column tested in isolation.
    print("\n=== 11d. pursuit_history resolves every FK column type ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        before_row = db.execute("""
            SELECT p.external_opportunity_id, m.code AS market,
                   ot.code AS otype, ct.code AS ctype, ps.code AS stage
              FROM pursuit p
              LEFT JOIN market m ON m.id = p.market_id
              LEFT JOIN opportunity_type ot ON ot.id = p.opportunity_type_id
              LEFT JOIN contract_type ct ON ct.id = p.contract_type_id
              LEFT JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
             WHERE p.id = %s""", (a_pursuit["id"],)).fetchone()
        other_market = db.execute("""
            SELECT code FROM market
             WHERE client_id = (SELECT client_id FROM pursuit WHERE id = %s)
               AND code <> %s AND is_active LIMIT 1""",
            (a_pursuit["id"], before_row["market"])).fetchone()
        other_otype = db.execute("""
            SELECT code FROM opportunity_type
             WHERE code <> %s AND is_active LIMIT 1""",
            (before_row["otype"],)).fetchone()
        other_ctype = db.execute("""
            SELECT code FROM contract_type
             WHERE code <> %s AND is_active LIMIT 1""",
            (before_row["ctype"],)).fetchone()
        other_stage = db.execute("""
            SELECT code FROM pipeline_stage
             WHERE code <> %s AND is_active LIMIT 1""",
            (before_row["stage"],)).fetchone()

    flip = {"market_code": other_market["code"],
            "opportunity_type_code": other_otype["code"],
            "contract_type_code": other_ctype["code"],
            "pipeline_stage_code": other_stage["code"]}
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}", json=flip)
    ok_flip = r.status_code == 200
    check("PATCH changing four ref codes at once succeeds", ok_flip,
          f"got {r.status_code}: {r.text[:150]}")

    r = safe(A.get, f"/api/pursuits/{a_pursuit['id']}/history")
    check("history does not 500 when a uuid-keyed and three "
          "smallint-keyed FKs change together", r.status_code == 200,
          f"got {r.status_code}: {r.text[:150]}")
    if r.status_code == 200:
        latest = r.json()[0] if r.json() else {}
        cf = latest.get("changed_fields") or {}
        resolved_ok = True
        for col in ("market_id", "opportunity_type_id", "contract_type_id",
                    "pipeline_stage_id"):
            diff = cf.get(col)
            if not diff:
                continue
            for side in ("from", "to"):
                v = diff.get(side)
                # An unresolved id looks like a UUID (36 chars, hyphens);
                # a resolved label does not.
                if v and len(str(v)) == 36 and str(v).count("-") == 4:
                    resolved_ok = False
        check("changed FK ids resolved to labels, not left as raw ids",
              resolved_ok, f"changed_fields: {cf}")

    # Restore, regardless of outcome above.
    safe(A.patch, f"/api/pursuits/{a_pursuit['id']}", json={
        "market_code": before_row["market"],
        "opportunity_type_code": before_row["otype"],
        "contract_type_code": before_row["ctype"],
        "pipeline_stage_code": before_row["stage"]})

    # ---- 11. no scoring IP in any response ---------------------------
    print("\n=== 11. engine IP does not leak through the API ===")
    blob = safe(A.get, "/api/bootstrap").text + safe(A.get, "/api/dashboard").text
    for token in ("price_position", "score_tech", "base_score",
                  "differential", "engine_secret", "api-key", "x-api-key"):
        check(f"no '{token}' in API responses", token not in blob.lower(),
              "present in payload")

    # ---- 12. Dashboard hierarchical scope selector --------------------
    print("\n=== 12. Dashboard hierarchical scope selector ===")

    # 12a. A Division-scoped user gets no meaningful choice -- one node,
    # no selector, matching the Targets picker's own "single candidate,
    # no picker" convention.
    r = safe(DV.get, "/api/bootstrap")
    dv_body = r.json() if r.status_code == 200 else {}
    dv_scope = dv_body.get("scope") or {}
    dv_opts = dv_scope.get("options")
    check("a Division-scoped user's scope selector has exactly one "
          "option -- itself -- so no selector is offered",
          r.status_code == 200 and isinstance(dv_opts, list) and len(dv_opts) == 1,
          f"got {dv_opts}")

    # 12b. A BU-scoped user (AERO's BU, which now has three real
    # divisions -- DIV1/DIV2/DIV3 -- beneath it) gets the BU's own
    # rollup plus each specific division: four options total.
    r = safe(U1.get, "/api/bootstrap")
    u1_body = r.json() if r.status_code == 200 else {}
    u1_opts = (u1_body.get("scope") or {}).get("options") or []
    u1_codes = {o["code"]: o["kind"] for o in u1_opts}
    check("a BU-scoped user with three divisions beneath gets rollup + "
          "each specific division, matching the real tree beneath that BU",
          len(u1_opts) == 4 and u1_codes.get("BU") == "rollup"
          and u1_codes.get("DIV1") == "leaf" and u1_codes.get("DIV2") == "leaf"
          and u1_codes.get("DIV3") == "leaf",
          f"got {u1_codes}")

    # 12c. A Business-scoped user (aero.admin) gets all three tiers:
    # whole-business rollup, each BU's own rollup, and each division
    # directly (flattened, not nested under its BU).
    r = safe(A.get, "/api/bootstrap")
    a_body = r.json() if r.status_code == 200 else {}
    a_scope = a_body.get("scope") or {}
    a_opts = a_scope.get("options") or []
    a_opt_codes = {o["code"]: o["kind"] for o in a_opts}
    check("a Business-scoped user's options cover all three tiers: "
          "the business itself, both BUs, and the division beneath BU",
          a_opt_codes.get("BUSINESS") == "rollup"
          and a_opt_codes.get("BU") == "rollup"
          and a_opt_codes.get("BU2") == "rollup"
          and a_opt_codes.get("DIV1") == "leaf",
          f"got {a_opt_codes}")
    root_default_id = next((o["id"] for o in a_opts if o["code"] == "BUSINESS"), None)
    check("the Business-scoped user's default selection (no scope_node_id "
          "given) is their own full assigned scope -- the whole business",
          a_scope.get("current_org_node_id") == root_default_id,
          f"got {a_scope.get('current_org_node_id')}, expected {root_default_id}")

    # 12d. A Business-level rollup sums every descendant's OWN plan_year
    # row for that year -- not zero, not just one BU's number. Give BU2
    # a real target for a throwaway year so the sum is provably a sum,
    # not a coincidence of BU2 already being empty.
    root_id = next(o["id"] for o in a_opts if o["code"] == "BUSINESS")
    bu_id = next(o["id"] for o in a_opts if o["code"] == "BU")
    bu2_id = next(o["id"] for o in a_opts if o["code"] == "BU2")
    test_year4 = 2096
    safe(A.put, f"/api/plan-years/{test_year4}?org_node_id={bu_id}",
         json={"revenue_target": 10000000})
    safe(A.put, f"/api/plan-years/{test_year4}?org_node_id={bu2_id}",
         json={"revenue_target": 3000000})
    r = safe(A.get, f"/api/bootstrap?scope_node_id={root_id}")
    body = r.json() if r.status_code == 200 else {}
    row = next((t for t in (body.get("scope_targets") or [])
               if t.get("year") == test_year4), None)
    check("a whole-business rollup's target is the SUM of every "
          "descendant's own plan_year row for that year",
          row is not None and float(row.get("rev_target") or 0) == 13000000,
          f"got {row}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        db.execute("DELETE FROM plan_year WHERE calendar_year = %s", (test_year4,))
        db.commit()

    # 12d2. Same reconciliation, but against AERO's real 2026 plan --
    # BU and BU2 now both have real, DIFFERENT (not equal, not
    # arbitrary) revenue targets split by actual probabilistic revenue
    # share. This is the first real proof the rollup sums genuinely
    # different addends, not a case that would also pass if it just
    # returned one BU's number twice or dropped one of them silently.
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        # DEMO's own org tree also has a node coded 'BU' -- code is only
        # unique per client, not globally -- so this must filter by
        # client too, or it can silently pick up DEMO's row instead.
        real_bu_2026 = db.execute("""
            SELECT y.revenue_target FROM plan_year y JOIN org_node o ON o.id = y.org_node_id
              JOIN client c ON c.id = o.client_id
             WHERE c.code = 'AERO' AND o.code = 'BU' AND y.calendar_year = 2026""").fetchone()
        real_bu2_2026 = db.execute("""
            SELECT y.revenue_target FROM plan_year y JOIN org_node o ON o.id = y.org_node_id
              JOIN client c ON c.id = o.client_id
             WHERE c.code = 'AERO' AND o.code = 'BU2' AND y.calendar_year = 2026""").fetchone()
    r = safe(A.get, f"/api/bootstrap?scope_node_id={root_id}")
    body = r.json() if r.status_code == 200 else {}
    row_2026 = next((t for t in (body.get("scope_targets") or [])
                     if t.get("year") == 2026), None)
    expected_2026 = float(real_bu_2026["revenue_target"]) + float(real_bu2_2026["revenue_target"])
    check("the whole-business rollup for real 2026 data equals BU's real "
          "row plus BU2's real row exactly -- two genuinely different, "
          "non-trivial addends, not a single-value coincidence",
          row_2026 is not None and float(row_2026["rev_target"]) == expected_2026
          and real_bu_2026["revenue_target"] != real_bu2_2026["revenue_target"],
          f"got {row_2026}, expected BU({real_bu_2026['revenue_target']}) + "
          f"BU2({real_bu2_2026['revenue_target']}) = {expected_2026}")

    # 12e. Picking a specific BU or division scopes pursuits (and, by the
    # same query, revenue/staffing) to that node and its descendants
    # only -- not the caller's whole visible scope. AERO's real tree now
    # has genuinely different content at every branch (BU holds nothing
    # directly -- its 123 pursuits live under DIV1/DIV2/DIV3; BU2 holds
    # 27 of its own, no divisions beneath it), so this is a real
    # narrowing check against non-trivial data, not a tautology against
    # empty siblings.
    div1_id = next(o["id"] for o in a_opts if o["code"] == "DIV1")
    div2_id = next(o["id"] for o in a_opts if o["code"] == "DIV2")
    div3_id = next(o["id"] for o in a_opts if o["code"] == "DIV3")
    r_root = safe(A.get, f"/api/bootstrap?scope_node_id={root_id}")
    r_bu = safe(A.get, f"/api/bootstrap?scope_node_id={bu_id}")
    r_bu2 = safe(A.get, f"/api/bootstrap?scope_node_id={bu2_id}")
    r_div1 = safe(A.get, f"/api/bootstrap?scope_node_id={div1_id}")
    n_root = len((r_root.json() or {}).get("pursuits") or []) if r_root.status_code == 200 else -1
    n_bu = len((r_bu.json() or {}).get("pursuits") or []) if r_bu.status_code == 200 else -1
    n_bu2 = len((r_bu2.json() or {}).get("pursuits") or []) if r_bu2.status_code == 200 else -1
    n_div1 = len((r_div1.json() or {}).get("pursuits") or []) if r_div1.status_code == 200 else -1
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        real_counts = {r["code"]: r["n"] for r in db.execute("""
            SELECT o.code, count(p.id) AS n FROM org_node o
              LEFT JOIN pursuit p ON p.org_node_id = o.id AND p.is_active
             WHERE o.client_id = (SELECT id FROM client WHERE code = 'AERO')
             GROUP BY o.code""").fetchall()}
    real_bu_rollup = real_counts.get("DIV1", 0) + real_counts.get("DIV2", 0) + real_counts.get("DIV3", 0)
    check("selecting BU2 narrows the pursuit list to exactly BU2's own "
          "real 27 pursuits, not the whole business's 150",
          n_root == 150 and n_bu2 == real_counts.get("BU2", -1) and n_bu2 not in (0, 150),
          f"root={n_root} bu2={n_bu2} (DB has {real_counts.get('BU2')} under BU2)")
    check("BU's own rollup equals the SUM of its three divisions' real "
          "pursuits (DIV1+DIV2+DIV3) -- BU holds none directly, so this "
          "is genuinely a sum, not a single value that happens to match",
          n_bu == real_bu_rollup and n_bu == 123,
          f"got {n_bu}, expected DIV1({real_counts.get('DIV1')}) + "
          f"DIV2({real_counts.get('DIV2')}) + DIV3({real_counts.get('DIV3')}) = {real_bu_rollup}")
    check("selecting DIV1 alone shows only Sensors' own pursuits, not "
          "Services' or Radios' (its siblings under the same BU)",
          n_div1 == real_counts.get("DIV1", -1) and n_div1 != n_bu,
          f"got {n_div1}, DB has {real_counts.get('DIV1')} under DIV1 alone")

    # A malformed or out-of-scope scope_node_id must be rejected, not
    # silently widened or narrowed to something arbitrary. demo_root was
    # resolved back in section 9d.
    r_bad = safe(A.get, f"/api/bootstrap?scope_node_id={demo_root['id']}")
    check("an out-of-scope scope_node_id is rejected, not silently accepted",
          r_bad.status_code in (403, 404), f"got {r_bad.status_code}: {r_bad.text[:150]}")

    # ---- 13. pursuit org-unit picker -----------------------------------
    print("\n=== 13. pursuit org-unit picker ===")

    # 13a. The option list matches the CALLER's own visible scope -- a
    # narrow-scoped user sees strictly fewer options than the full admin.
    r = safe(A.get, "/api/bootstrap")
    a_units = (r.json() or {}).get("org_units") or []
    r = safe(N.get, "/api/bootstrap")
    n_units = (r.json() or {}).get("org_units") or []
    check("a narrow-scoped user's org-unit picker has fewer options than "
          "a full-scope admin's, matching their own visible scope",
          0 < len(n_units) < len(a_units),
          f"admin={len(a_units)} narrow={len(n_units)}")
    check("a BU with real divisions beneath it (BU) is never itself an "
          "option -- only its divisions and leaf BUs are assignable",
          not any(u["code"] == "BU" for u in a_units)
          and any(u["code"] == "DIV1" for u in a_units)
          and any(u["code"] == "BU2" for u in a_units),
          f"got codes {[u['code'] for u in a_units]}")

    # 13b. Submitting an org-unit code outside the caller's own
    # ASSIGNABLE set is rejected, not silently accepted -- even a code
    # that is visible to the caller in some other sense (AERO's own BU
    # is in aero.admin's visible scope, but it has real divisions
    # beneath it, so it is deliberately excluded from what's assignable).
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}",
             json={"org_unit_code": "BU"})
    check("a code for a BU that has real divisions beneath it (not "
          "assignable, even though visible) is rejected",
          r.status_code in (400, 404), f"got {r.status_code}: {r.text[:150]}")
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}",
             json={"org_unit_code": "NO_SUCH_CODE_AT_ALL"})
    check("an unknown org-unit code is rejected",
          r.status_code in (400, 404), f"got {r.status_code}: {r.text[:150]}")

    # 13c. A successful reassignment writes pursuit.org_node_id, is
    # audited by the normal trigger (no special-casing), and the pursuit
    # subsequently shows up under its new scope and not its old one.
    # a_pursuit currently lives under DIV3; DV (aero.div1) is scoped to
    # DIV1 and should NOT see it yet.
    r = safe(DV.get, f"/api/pursuits/{a_pursuit['id']}")
    check("before reassignment, a DIV1-scoped user cannot see a DIV3 pursuit",
          r.status_code == 404, f"got {r.status_code}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        n_audit_before = db.execute(
            "SELECT count(*) AS n FROM audit_log").fetchone()["n"]

    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}", json={"org_unit_code": "DIV1"})
    check("reassigning to a code within the caller's own scope succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text[:200]}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        div1_id = db.execute("""
            SELECT o.id FROM org_node o JOIN client c ON c.id = o.client_id
             WHERE c.code = 'AERO' AND o.code = 'DIV1'""").fetchone()["id"]
        written = db.execute(
            "SELECT org_node_id FROM pursuit WHERE id = %s", (a_pursuit["id"],)).fetchone()
        n_audit_after = db.execute(
            "SELECT count(*) AS n FROM audit_log").fetchone()["n"]
        last_audit = db.execute("""
            SELECT changed_fields FROM audit_log
             WHERE table_name = 'pursuit' AND record_id = %s
             ORDER BY occurred_at DESC LIMIT 1""", (a_pursuit["id"],)).fetchone()
    check("the write landed on pursuit.org_node_id, DIV1's real id",
          written is not None and str(written["org_node_id"]) == str(div1_id),
          f"got {written}")
    check("the reassignment is audited by the same trigger as any other "
          "field -- no special-casing", n_audit_after > n_audit_before,
          f"{n_audit_before} -> {n_audit_after}")
    check("the audit row names org_node_id as a changed field",
          bool(last_audit and "org_node_id" in (last_audit["changed_fields"] or {})),
          f"recorded {list((last_audit or {}).get('changed_fields') or {})}")

    r = safe(DV.get, f"/api/pursuits/{a_pursuit['id']}")
    check("after reassignment, the DIV1-scoped user now sees it",
          r.status_code == 200, f"got {r.status_code}")
    r = safe(N.get, f"/api/pursuits/{a_pursuit['id']}")
    check("a user scoped elsewhere (BU2) still cannot see it -- narrowing "
          "did not accidentally widen anyone else's scope",
          r.status_code == 404, f"got {r.status_code}")

    # Restore via the real write path, per this project's standing
    # discipline for any temporary test mutation to live data.
    r = safe(A.patch, f"/api/pursuits/{a_pursuit['id']}", json={"org_unit_code": "DIV3"})
    check("restoring the pursuit to its original org unit succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text[:200]}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        restored = db.execute(
            "SELECT org_node_id FROM pursuit WHERE id = %s", (a_pursuit["id"],)).fetchone()
        div3_id = db.execute("""
            SELECT o.id FROM org_node o JOIN client c ON c.id = o.client_id
             WHERE c.code = 'AERO' AND o.code = 'DIV3'""").fetchone()["id"]
    check("restore landed back on DIV3, the original org unit",
          str(restored["org_node_id"]) == str(div3_id), f"got {restored}")

    # ---- 14. test-fixture org nodes are hidden from pickers -----------
    # BUZ ("Zero-Pursuit Test BU") exists ONLY to give the scope test
    # suite a genuinely empty node. It must never appear as a choice in
    # a real user's picker, but a user actually scoped to it (DZ) must
    # still resolve correctly -- the flag hides it from being CHOSEN, it
    # does not remove it from access control.
    print("\n=== 14. test-fixture org nodes are hidden from pickers ===")

    r = safe(A.get, "/api/bootstrap")
    a_body = r.json() if r.status_code == 200 else {}
    a_org_units = a_body.get("org_units") or []
    a_scope_opts = (a_body.get("scope") or {}).get("options") or []
    check("BUZ does not appear in the pursuit form's org-unit picker, "
          "even though it is within aero.admin's visible scope",
          not any(u.get("code") == "BUZ" for u in a_org_units),
          f"got codes {[u.get('code') for u in a_org_units]}")
    check("BUZ does not appear in the Dashboard's rollup selector",
          not any(o.get("code") == "BUZ" for o in a_scope_opts),
          f"got codes {[o.get('code') for o in a_scope_opts]}")

    r = safe(A.get, "/api/plan-years")
    py_body = r.json() if r.status_code == 200 else {}
    py_candidates = py_body.get("candidates") or []
    check("BUZ does not appear in the Targets & Budgets picker's "
          "candidate list either",
          not any(c.get("code") == "BUZ" for c in py_candidates),
          f"got codes {[c.get('code') for c in py_candidates]}")

    # A user actually scoped to BUZ (DZ = aero.buz) must still resolve
    # correctly -- the flag is display-only, never an access-control
    # mechanism. If this broke, DZ would see a 403/empty-scope error
    # instead of a normal (empty-of-pursuits) bootstrap payload.
    r = safe(DZ.get, "/api/bootstrap")
    check("a user actually scoped to the test-fixture node still "
          "resolves normally through the real scope machinery",
          r.status_code == 200, f"got {r.status_code}: {r.text[:150]}")
    dz_body = r.json() if r.status_code == 200 else {}
    check("that user's own bootstrap still correctly reflects their real "
          "scope (zero pursuits, since BUZ genuinely holds none)",
          dz_body.get("pursuits") == [], f"got {dz_body.get('pursuits')}")

    # ---- 15. client_escalation_rate write endpoint ---------------------
    print("\n=== 15. client_escalation_rate write endpoint ===")
    test_year5 = 2095   # implausible enough to never collide with real data

    r = safe(N.put, f"/api/staffing/escalation-rates/{test_year5}", json={"rate": 0.05})
    check("PUT as an unauthorized role (capture_manager) is rejected, "
          "matching PUT /api/plan-years' own admin/executive gate",
          r.status_code == 403, f"got {r.status_code}: {r.text[:150]}")

    r = safe(A.put, f"/api/staffing/escalation-rates/{test_year5}", json={"rate": 0.07})
    check("PUT as an authorized role (admin) succeeds",
          r.status_code == 200, f"got {r.status_code}: {r.text[:150]}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        aero_row = db.execute("""
            SELECT ce.client_id, ce.rate FROM client_escalation_rate ce
              JOIN client c ON c.id = ce.client_id
             WHERE c.code = 'AERO' AND ce.calendar_year = %s""", (test_year5,)).fetchone()
        demo_row = db.execute("""
            SELECT ce.client_id FROM client_escalation_rate ce
              JOIN client c ON c.id = ce.client_id
             WHERE c.code = 'DEMO' AND ce.calendar_year = %s""", (test_year5,)).fetchone()
    check("the write landed on AERO's own client_escalation_rate row",
          aero_row is not None and abs(float(aero_row["rate"]) - 0.07) < 1e-6,
          f"got {aero_row}")
    check("DEMO's tenant was not touched by AERO's write (tenant isolation)",
          demo_row is None, f"got {demo_row}")

    r = safe(B.get, "/api/staffing/escalation-rates")
    b_rates = (r.json() or {}).get("rates") or []
    check("DEMO's own GET does not see AERO's override for the test year "
          "(RLS-scoped, same as every other tenant-scoped table)",
          not any(row.get("calendar_year") == test_year5 for row in b_rates),
          f"got {b_rates}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        db.execute("""
            DELETE FROM client_escalation_rate
             WHERE calendar_year = %s""", (test_year5,))
        db.commit()

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("API security verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
