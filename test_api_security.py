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

    A = login(args.base, args.user_a)          # AERO admin
    B = login(args.base, args.user_b)          # DEMO admin
    N = login(args.base, args.user_narrow)     # AERO, scoped to an empty BU

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
    n_boot = safe(N.get, "/api/bootstrap").json()
    check("narrow-scope user sees no pursuits",
          len(n_boot["pursuits"]) == 0,
          f"saw {len(n_boot['pursuits'])} from a BU that holds none")
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
    # Uses B (DEMO admin), not A (AERO admin): AERO's org tree has two
    # license-boundary business units (BU, BU2) both visible to the
    # top-scoped AERO admin, so a bare PUT correctly 409s there as
    # ambiguous ("specify which plan to edit") -- that is the endpoint
    # working as designed, not a bug. DEMO has exactly one, so its admin
    # resolves unambiguously.
    print("\n=== 9b. plan-year writes persist and are audited ===")
    test_year = 2099   # implausible enough to never collide with real data
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        n_before = db.execute("SELECT count(*) AS n FROM audit_log").fetchone()["n"]
    r = safe(B.put, f"/api/plan-years/{test_year}", json={"revenue_target": 12345678})
    check("admin can PUT a plan-year", r.status_code == 200,
          f"got {r.status_code}: {r.text[:150]}")
    r2 = safe(B.get, "/api/plan-years")
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
    r3 = safe(B.put, f"/api/plan-years/{test_year}", json={"revenue_target": 87654321})
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
