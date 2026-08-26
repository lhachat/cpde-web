#!/usr/bin/env python3
"""
test_isolation.py -- Prove tenant isolation actually works.

Connects TWICE: once as the superuser to resolve client ids, then as the
restricted application role to run every assertion. That second connection
is the whole point -- the superuser bypasses RLS, so tests run as `cpde`
pass vacuously and prove nothing.

    pip install "psycopg[binary]"

    python test_isolation.py ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde" ^
      --app-dsn   "postgresql://cpde_api:localdev_api@localhost:5433/cpde"

Exit code 0 = all passed. Non-zero = at least one isolation failure.
This is the artifact to put in CI and to hand a security reviewer.
"""

import argparse
import sys

import psycopg

PASS, FAIL = [], []


def check(name, condition, detail=""):
    (PASS if condition else FAIL).append((name, detail))
    print(f"  {'PASS' if condition else 'FAIL'}  {name}"
          f"{'  -- ' + detail if detail and not condition else ''}")


def as_tenant(conn, client_id):
    """Open a transaction with tenant context set, exactly as the app must."""
    cur = conn.cursor()
    cur.execute("BEGIN")
    cur.execute("SELECT set_tenant(%s)", (client_id,))
    return cur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--admin-dsn", required=True)
    ap.add_argument("--app-dsn", required=True)
    args = ap.parse_args()

    # --- resolve ids as superuser (RLS covers the client table too) ------
    with psycopg.connect(args.admin_dsn) as admin:
        rows = admin.execute(
            "SELECT code, id FROM client ORDER BY code").fetchall()
    ids = {c: i for c, i in rows}
    if len(ids) < 2:
        print("Need at least two tenants loaded. Found:", list(ids))
        return 2
    print(f"Tenants: {', '.join(ids)}\n")

    a_code, b_code = sorted(ids)[:2]
    A, B = ids[a_code], ids[b_code]

    with psycopg.connect(args.app_dsn, autocommit=True) as app:
        # --- the test harness must not be able to cheat ------------------
        print("=== harness sanity ===")
        role, superuser, bypass = app.execute(
            "SELECT current_user, "
            "(SELECT rolsuper FROM pg_roles WHERE rolname=current_user), "
            "(SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user)"
        ).fetchone()
        check(f"connected as restricted role ({role})",
              not superuser and not bypass,
              "this role bypasses RLS -- every test below would pass vacuously")
        if superuser or bypass:
            print("\nABORTING: run as the application role, not the superuser.")
            return 2

        # --- 1. no context means no rows ---------------------------------
        print("\n=== 1. fails closed without tenant context ===")
        for tbl in ("pursuit", "market", "pwin_assessment", "pursuit_staffing",
                    "plan_year", "app_user"):
            n = app.execute(f"SELECT count(*) FROM {tbl}").fetchone()[0]
            check(f"{tbl}: 0 rows with no context", n == 0, f"saw {n}")

        # --- 2. each tenant sees only itself ------------------------------
        print(f"\n=== 2. {a_code} context ===")
        cur = as_tenant(app, A)
        a_pursuits = cur.execute("SELECT count(*) FROM pursuit").fetchone()[0]
        a_clients = cur.execute("SELECT count(*) FROM client").fetchone()[0]
        a_foreign = cur.execute(
            "SELECT count(*) FROM pursuit WHERE client_id = %s", (B,)).fetchone()[0]
        cur.execute("COMMIT")
        check(f"{a_code} sees its own pursuits", a_pursuits > 0, "saw none")
        check(f"{a_code} sees exactly one client row", a_clients == 1, f"saw {a_clients}")
        check(f"{a_code} cannot see {b_code} pursuits", a_foreign == 0,
              f"LEAKED {a_foreign} rows")

        print(f"\n=== 3. {b_code} context ===")
        cur = as_tenant(app, B)
        b_pursuits = cur.execute("SELECT count(*) FROM pursuit").fetchone()[0]
        b_foreign = cur.execute(
            "SELECT count(*) FROM pursuit WHERE client_id = %s", (A,)).fetchone()[0]
        cur.execute("COMMIT")
        check(f"{b_code} sees its own pursuits", b_pursuits > 0, "saw none")
        check(f"{b_code} cannot see {a_code} pursuits", b_foreign == 0,
              f"LEAKED {b_foreign} rows")
        check("tenants see different row counts",
              a_pursuits != b_pursuits or a_pursuits == 0,
              "same count -- suspicious, verify manually")

        # --- 4. every tenant-scoped table, not just pursuit ---------------
        print(f"\n=== 4. cross-tenant read on every scoped table ===")
        tables = ("pursuit", "market", "org_node", "app_user",
                  "user_scope_assignment", "pursuit_year_projection",
                  "pursuit_staffing", "pursuit_phase_duration",
                  "pwin_assessment", "pwin_answer", "plan_year")
        cur = as_tenant(app, A)
        for tbl in tables:
            n = cur.execute(
                f"SELECT count(*) FROM {tbl} WHERE client_id = %s", (B,)).fetchone()[0]
            check(f"{tbl}: no {b_code} rows visible from {a_code}", n == 0,
                  f"LEAKED {n} rows")
        cur.execute("COMMIT")

        # --- 5. write isolation ------------------------------------------
        print("\n=== 5. cannot write into another tenant ===")
        cur = as_tenant(app, A)
        try:
            cur.execute(
                "INSERT INTO market (client_id, code, name) VALUES (%s,'XTEST','x')",
                (B,))
            cur.execute("ROLLBACK")
            check(f"insert tagged {b_code} from {a_code} context is rejected",
                  False, "INSERT SUCCEEDED -- WITH CHECK is missing")
        except psycopg.errors.Error as e:
            cur.execute("ROLLBACK")
            check(f"insert tagged {b_code} from {a_code} context is rejected",
                  "row-level security" in str(e).lower(),
                  f"rejected, but for the wrong reason: {str(e)[:70]}")

        # --- 6. context must not survive the transaction ------------------
        print("\n=== 6. context does not leak across transactions ===")
        cur = as_tenant(app, A)
        cur.execute("COMMIT")
        n = app.execute("SELECT count(*) FROM pursuit").fetchone()[0]
        check("context cleared after COMMIT", n == 0,
              f"saw {n} rows -- SET LOCAL is not being used; "
              f"a pooled connection will leak tenants")

        # --- 7. the app role cannot disable its own policies ---------------
        print("\n=== 7. application role cannot escalate ===")
        try:
            app.execute("ALTER TABLE pursuit DISABLE ROW LEVEL SECURITY")
            check("cannot disable RLS", False, "IT DISABLED RLS")
        except psycopg.errors.Error:
            check("cannot disable RLS", True)
        try:
            app.execute("DROP POLICY tenant_isolation ON pursuit")
            check("cannot drop policies", False, "IT DROPPED THE POLICY")
        except psycopg.errors.Error:
            check("cannot drop policies", True)
        try:
            app.execute("CREATE TABLE rls_escape (x int)")
            app.execute("DROP TABLE rls_escape")
            check("cannot create tables", False, "IT CREATED A TABLE")
        except psycopg.errors.Error:
            check("cannot create tables", True)

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, detail in FAIL:
            print(f"  - {name}: {detail}")
        print("\nDo not ship until these pass.")
        return 1
    print("Tenant isolation verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
