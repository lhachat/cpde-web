#!/usr/bin/env python3
"""
test_scope.py -- Prove business-unit scope filtering works.

This is a DIFFERENT control from tenant isolation:

    RLS              separates COMPANIES
    fn_user_pursuits separates BUSINESS UNITS within a company

test_isolation.py covers the first. This covers the second. Both must pass.

Runs entirely as the restricted application role, with tenant context set
per transaction -- the same way the API will.

    python test_scope.py ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde" ^
      --app-dsn   "postgresql://cpde_api:localdev_api@localhost:5433/cpde"

Exit 0 = all passed.
"""

import argparse
import sys

import psycopg

PASS, FAIL = [], []


def check(name, ok, detail=""):
    (PASS if ok else FAIL).append((name, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}"
          f"{'  -- ' + detail if detail and not ok else ''}")


def tenant_cur(conn, client_id):
    cur = conn.cursor()
    cur.execute("BEGIN")
    cur.execute("SELECT set_tenant(%s)", (client_id,))
    return cur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--admin-dsn", required=True)
    ap.add_argument("--app-dsn", required=True)
    args = ap.parse_args()

    # ---- fixtures, as superuser --------------------------------------
    with psycopg.connect(args.admin_dsn) as admin:
        clients = dict(admin.execute("SELECT code, id FROM client").fetchall())
        if "AERO" not in clients:
            print("AERO tenant not loaded.")
            return 2
        aero = clients["AERO"]

        # A user scoped to the DIVISION, to test that scope narrows as well
        # as inherits. test_setup.sql created DIV1 under AERO's BU.
        admin.execute("""
            INSERT INTO app_user (client_id, email, display_name)
            SELECT %s, 'aero.div1@demoaero.test', 'Aero Division Capture Mgr'
            ON CONFLICT (client_id, email) DO NOTHING""", (aero,))
        admin.execute("""
            INSERT INTO user_scope_assignment (user_id, org_node_id, role_id)
            SELECT u.id, o.id, r.id
              FROM app_user u
              JOIN org_node o ON o.client_id = u.client_id AND o.code = 'DIV1'
              JOIN role r ON r.code = 'capture_manager'
             WHERE u.email = 'aero.div1@demoaero.test'
            ON CONFLICT (user_id, org_node_id, role_id) DO NOTHING""")

        # DIV1/DIV2/DIV3 and BU2 all now hold real pursuits (AERO's org
        # structure grew real content -- 46/47/30/27 respectively), so
        # none of them can stand in for "an org node that genuinely holds
        # nothing" any more. A fixture BU, sibling of BU/BU2 directly
        # under the root, never assigned any pursuit or division -- so
        # "narrow scope excludes" is proven against a node that is
        # provably empty by construction, not by coincidence of today's
        # data. Deliberately NOT a child of BU or BU2: BU already has
        # exactly three real divisions and BU2 deliberately has none (a
        # later Dashboard-picker test relies on that exact shape), and a
        # test-only child under either would corrupt those real counts.
        admin.execute("""
            INSERT INTO org_node (client_id, parent_id, node_type, code,
                                  name, is_license_boundary)
            SELECT %s, o.id, 'business_unit', 'BUZ', 'Zero-Pursuit Test BU', true
              FROM org_node o WHERE o.client_id = %s AND o.code = 'BUSINESS'
            ON CONFLICT (client_id, code) DO NOTHING""", (aero, aero))
        admin.execute("""
            INSERT INTO app_user (client_id, email, display_name)
            SELECT %s, 'aero.buz@demoaero.test', 'Aero Empty-BU Capture Mgr'
            ON CONFLICT (client_id, email) DO NOTHING""", (aero,))
        admin.execute("""
            INSERT INTO user_scope_assignment (user_id, org_node_id, role_id)
            SELECT u.id, o.id, r.id
              FROM app_user u
              JOIN org_node o ON o.client_id = u.client_id AND o.code = 'BUZ'
              JOIN role r ON r.code = 'capture_manager'
             WHERE u.email = 'aero.buz@demoaero.test'
            ON CONFLICT (user_id, org_node_id, role_id) DO NOTHING""")

        users = dict(admin.execute("""
            SELECT email, id FROM app_user WHERE client_id = %s""", (aero,)).fetchall())
        nodes = dict(admin.execute("""
            SELECT code, id FROM org_node WHERE client_id = %s""", (aero,)).fetchall())
        demo_nodes = dict(admin.execute("""
            SELECT o.code, o.id FROM org_node o JOIN client c ON c.id=o.client_id
             WHERE c.code = 'DEMO'""").fetchall())
        demo_user = admin.execute("""
            SELECT u.id FROM app_user u JOIN client c ON c.id=u.client_id
             WHERE c.code='DEMO' LIMIT 1""").fetchone()[0]
        admin.commit()

    admin_u = users["aero.admin@demoaero.test"]     # scoped at BUSINESS
    bu2_u = users["aero.bu2@demoaero.test"]         # scoped at BU2 (27 real pursuits)
    div_u = users["aero.div1@demoaero.test"]        # scoped at DIV1 (46 real pursuits)
    buz_u = users["aero.buz@demoaero.test"]         # scoped at BUZ (genuinely empty)

    with psycopg.connect(args.app_dsn, autocommit=True) as app:
        role, sup, byp = app.execute(
            "SELECT current_user,"
            "(SELECT rolsuper FROM pg_roles WHERE rolname=current_user),"
            "(SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user)").fetchone()
        print("=== harness sanity ===")
        check(f"restricted role ({role})", not sup and not byp,
              "bypasses RLS -- results meaningless")
        if sup or byp:
            return 2

        # ---- 1. inheritance downward ---------------------------------
        print("\n=== 1. scope inherits downward ===")
        cur = tenant_cur(app, aero)
        total = cur.execute("SELECT count(*) FROM pursuit").fetchone()[0]
        admin_nodes = cur.execute(
            "SELECT count(*) FROM fn_user_visible_org_nodes(%s)", (admin_u,)).fetchone()[0]
        admin_p = cur.execute(
            "SELECT count(*) FROM fn_user_pursuits(%s)", (admin_u,)).fetchone()[0]
        cur.execute("COMMIT")
        check("business-level user sees every org node",
              admin_nodes >= 3, f"saw {admin_nodes}, expected business + 2 BUs + division")
        check("business-level user sees all pursuits in the tenant",
              admin_p == total, f"saw {admin_p} of {total}")

        # ---- 2. scope narrows ----------------------------------------
        print("\n=== 2. narrow scope excludes ===")
        cur = tenant_cur(app, aero)
        bu2_nodes = cur.execute(
            "SELECT count(*) FROM fn_user_visible_org_nodes(%s)", (bu2_u,)).fetchone()[0]
        bu2_p = cur.execute(
            "SELECT count(*) FROM fn_user_pursuits(%s)", (bu2_u,)).fetchone()[0]
        div_p = cur.execute(
            "SELECT count(*) FROM fn_user_pursuits(%s)", (div_u,)).fetchone()[0]
        buz_nodes = cur.execute(
            "SELECT count(*) FROM fn_user_visible_org_nodes(%s)", (buz_u,)).fetchone()[0]
        buz_p = cur.execute(
            "SELECT count(*) FROM fn_user_pursuits(%s)", (buz_u,)).fetchone()[0]
        cur.execute("COMMIT")
        with psycopg.connect(args.admin_dsn) as admin:
            real_bu2 = admin.execute("""
                SELECT count(*) FROM pursuit p JOIN org_node o ON o.id = p.org_node_id
                 WHERE o.code = 'BU2' AND p.is_active""").fetchone()[0]
            real_div1 = admin.execute("""
                SELECT count(*) FROM pursuit p JOIN org_node o ON o.id = p.org_node_id
                 WHERE o.code = 'DIV1' AND p.is_active""").fetchone()[0]
        check("BU2 user sees only its own node", bu2_nodes == 1, f"saw {bu2_nodes}")
        # BU2 and DIV1 now hold real, non-trivial pursuit counts (not the
        # empty case) -- proves scope narrows to EXACTLY that node's own
        # real data, not a coincidental zero.
        check("BU2 user sees exactly BU2's own real pursuits, no more, no less",
              bu2_p == real_bu2 and 0 < bu2_p < admin_p,
              f"saw {bu2_p}, DB has {real_bu2} under BU2, admin sees {admin_p}")
        check("division user sees exactly DIV1's own real pursuits, no more, no less",
              div_p == real_div1 and 0 < div_p < admin_p,
              f"saw {div_p}, DB has {real_div1} under DIV1, admin sees {admin_p}")
        # A genuinely empty fixture BU proves no leak from ANY other
        # business unit -- the case BU2/DIV1 used to (accidentally) cover
        # before they had real content of their own.
        check("a genuinely empty BU sees no pursuits (no leak)",
              buz_p == 0, f"LEAKED {buz_p} pursuits")
        # is_test_fixture hides BUZ from user-facing PICKERS only -- it
        # must never touch actual scope resolution. A user genuinely
        # scoped to BUZ still resolves to exactly their own node here,
        # same as any other single-node scope assignment.
        check("a user scoped to a test-fixture node still resolves "
              "through fn_user_visible_org_nodes exactly as normal -- "
              "is_test_fixture is display-only, not access control",
              buz_nodes == 1, f"saw {buz_nodes}")
        check("narrow scope sees strictly fewer than broad scope",
              bu2_p < admin_p, "narrow scope saw as much as the admin")

        # ---- 3. scope cannot cross tenants ----------------------------
        print("\n=== 3. scope cannot cross tenants ===")
        cur = tenant_cur(app, aero)
        n = cur.execute(
            "SELECT count(*) FROM fn_user_visible_org_nodes(%s)", (demo_user,)).fetchone()[0]
        cross = cur.execute(
            "SELECT count(*) FROM fn_user_pursuits(%s)", (demo_user,)).fetchone()[0]
        cur.execute("COMMIT")
        check("a DEMO user resolves to no nodes under AERO context", n == 0,
              f"saw {n} -- scope is reaching across tenants")
        check("a DEMO user resolves to no pursuits under AERO context", cross == 0,
              f"LEAKED {cross}")

        # ---- 4. a scope assignment pointing at a foreign node is inert -
        print("\n=== 4. foreign scope assignment is inert ===")
        cur = tenant_cur(app, aero)
        foreign_node = list(demo_nodes.values())[0]
        has = cur.execute("SELECT fn_user_has_scope(%s,%s)",
                          (admin_u, foreign_node)).fetchone()[0]
        cur.execute("COMMIT")
        check("AERO admin has no scope over a DEMO node", has is False,
              "returned true -- cross-tenant scope")

        # ---- 5. deactivating a node hides its subtree ------------------
        print("\n=== 5. is_active cuts the subtree ===")
        with psycopg.connect(args.admin_dsn) as admin:
            admin.execute("UPDATE org_node SET is_active=false WHERE id=%s",
                          (nodes["BU"],))
            admin.commit()
        cur = tenant_cur(app, aero)
        after = cur.execute(
            "SELECT count(*) FROM fn_user_pursuits(%s)", (admin_u,)).fetchone()[0]
        cur.execute("COMMIT")
        with psycopg.connect(args.admin_dsn) as admin:
            admin.execute("UPDATE org_node SET is_active=true WHERE id=%s",
                          (nodes["BU"],))
            admin.commit()
        check("deactivating a BU hides its pursuits", after < admin_p,
              f"still saw {after} of {admin_p}")

        # ---- 6. no context, no scope ----------------------------------
        print("\n=== 6. scope still fails closed without tenant context ===")
        n = app.execute(
            "SELECT count(*) FROM fn_user_pursuits(%s)", (admin_u,)).fetchone()[0]
        check("no tenant context returns no pursuits", n == 0, f"saw {n}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Scope filtering verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
