#!/usr/bin/env python3
"""
test_user_admin.py -- admin user management: create, edit, deactivate a
user without hand-writing SQL.

WHY: before routers/users.py existed there was no endpoint and no UI for
this at all -- adding a user required a direct SQL INSERT as a
superuser, because the application role itself had no write grant on
app_user (21_least_privilege.sql had revoked it after confirming
nothing wrote it; 23_user_admin_grants.sql grants back INSERT/UPDATE --
and deliberately NOT DELETE -- for exactly this feature).

What this asserts, all against the REAL endpoints and the REAL login
path, never a hand-rolled substitute:

  1. The admin gate is SERVER-SIDE. A capture_manager gets 403 from
     every endpoint here, not merely a hidden nav link.
  2. Creating a user with a scope assignment works end to end, is
     audited by the existing generic trigger, and the new user can
     actually LOG IN and is correctly scoped.
  3. Editing (display name, role, org units) works and is audited.
  4. Deactivating blocks login through the REAL fn_lookup_login
     is_active check -- and does NOT delete or orphan the user's
     historical audit rows, which must still resolve to their name.
  5. Out-of-scope org units and duplicate emails are refused.
  6. An admin cannot deactivate their own account (that would lock the
     last admin out of the only screen that could undo it).

FIXTURE: creates its own throwaway user (a dedicated, single-purpose
fixture, same discipline as the rest of this harness) and removes it in
a finally block. The user is hard-DELETEd in cleanup only because this
test created it seconds earlier and nothing real references it -- the
PRODUCT never hard-deletes, which is the whole point of assertion 4.

    python test_user_admin.py --base http://localhost:8001 ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Requires the API running. No AWS session needed (nothing here calls the
engine). Exit 0 = all passed.
"""
from __future__ import annotations

import argparse
import sys
import uuid

import httpx
import psycopg
from psycopg.rows import dict_row

PASS, FAIL = [], []

# Unique per run so a crashed prior run can never collide with this one.
FIXTURE_EMAIL = f"useradmin.test.{uuid.uuid4().hex[:10]}@demoaero.test"


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


def login(base, email):
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

    A = login(args.base, "aero.admin@demoaero.test")
    created_id = None

    try:
        print("=== 1. the admin gate is server-side, not just a hidden nav link ===")
        N = login(args.base, "aero.bu2@demoaero.test")
        r = safe(N.get, "/api/users")
        check("a non-admin (capture_manager) gets 403 from GET /api/users",
              r.status_code == 403, f"got {r.status_code}: {r.text}")
        r = safe(N.post, "/api/users", json={
            "email": "should.never.exist@demoaero.test",
            "display_name": "Nope", "role_code": "read_only",
            "org_unit_codes": ["BU2"]})
        check("a non-admin gets 403 from POST /api/users",
              r.status_code == 403, f"got {r.status_code}: {r.text}")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            leaked = db.execute(
                "SELECT 1 FROM app_user WHERE email = %s",
                ("should.never.exist@demoaero.test",)).fetchone()
        check("the non-admin's rejected create wrote nothing", leaked is None)

        anon = httpx.Client(base_url=args.base, timeout=30)
        r = safe(anon.get, "/api/users")
        check("GET /api/users without a session is 401",
              r.status_code == 401, f"got {r.status_code}")

        print("\n=== 2. an admin can list users in their own scope ===")
        r = safe(A.get, "/api/users")
        check("GET /api/users succeeds for an admin", r.status_code == 200,
              f"got {r.status_code}: {r.text}")
        listing = r.json() if r.status_code == 200 else {}
        check("the listing carries the option lists the form needs "
              "(roles + org units)",
              bool(listing.get("roles")) and bool(listing.get("org_units")),
              f"got roles={len(listing.get('roles', []))} "
              f"units={len(listing.get('org_units', []))}")
        check("test-fixture org nodes are not offered as assignable units "
              "(same picker discipline as every other org-unit picker)",
              all(o["code"] != "BUZ" for o in listing.get("org_units", [])),
              f"got {[o['code'] for o in listing.get('org_units', [])]}")

        print("\n=== 3. create: a real user, with scope, audited ===")
        r = safe(A.post, "/api/users", json={
            "email": FIXTURE_EMAIL, "display_name": "User Admin Fixture",
            "role_code": "capture_manager", "org_unit_codes": ["BU2"]})
        check("POST /api/users creates the user", r.status_code == 200,
              f"got {r.status_code}: {r.text}")
        created = r.json() if r.status_code == 200 else {}
        created_id = created.get("id")
        check("the response carries the new user's scope assignment",
              any(a["org_unit_code"] == "BU2"
                  and a["role_code"] == "capture_manager"
                  for a in created.get("assignments", [])),
              f"got {created.get('assignments')}")

        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            row = db.execute("""
                SELECT u.id, u.is_active, u.display_name
                  FROM app_user u WHERE u.email = %s""",
                (FIXTURE_EMAIL,)).fetchone()
            audit = db.execute("""
                SELECT count(*) AS n FROM audit_log
                 WHERE table_name = 'app_user' AND record_id = %s
                   AND action = 'INSERT'""", (row["id"],)).fetchone()
            scope_audit = db.execute("""
                SELECT count(*) AS n FROM audit_log
                 WHERE table_name = 'user_scope_assignment'
                   AND occurred_at > now() - interval '2 minutes'""").fetchone()
        check("the user really landed in the database, active",
              row is not None and row["is_active"] is True, f"got {row}")
        check("the create is audited by the existing generic trigger "
              "(no new audit mechanism)",
              audit["n"] >= 1, f"got {audit['n']} app_user INSERT audit rows")
        check("the scope assignment is audited too",
              scope_audit["n"] >= 1, f"got {scope_audit['n']}")

        print("\n=== 4. the new user can actually log in, correctly scoped ===")
        F = login(args.base, FIXTURE_EMAIL)
        r = safe(F.get, "/api/bootstrap")
        check("the newly created user can log in and load their portfolio",
              r.status_code == 200, f"got {r.status_code}: {r.text}")
        boot = r.json() if r.status_code == 200 else {}
        check("their session reports the role they were created with",
              "capture_manager" in (boot.get("user", {}).get("roles") or []),
              f"got {boot.get('user', {}).get('roles')}")
        n_new = len(boot.get("pursuits", []))
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            bu2 = db.execute("""
                SELECT count(*) AS n FROM pursuit p
                  JOIN org_node o ON o.id = p.org_node_id
                 WHERE o.code = 'BU2'""").fetchone()["n"]
        check("they see exactly BU2's own pursuits -- the scope assignment "
              "genuinely resolved through the real scope machinery",
              n_new == bu2, f"saw {n_new}, BU2 really holds {bu2}")

        # The new user performs a REAL audited write of their own, so that
        # assertion 8 has genuine historical audit rows ATTRIBUTED TO THEM
        # to check survive deactivation. audit_log.user_id records the
        # ACTOR, not the subject -- a user who never acted has no such
        # rows, which is exactly what an earlier draft of this test got
        # wrong. Chosen deliberately: user_dashboard_layout is audited
        # (trg_audit) and is per-user state, so this touches no shared
        # data and cannot interfere with any other suite.
        r = safe(F.put, "/api/dashboard-layout",
                 json={"card_order": ["kpis", "pipeline"], "card_settings": {}})
        check("the new user can make a real audited write of their own "
              "(per-user dashboard layout)",
              r.status_code == 200, f"got {r.status_code}: {r.text}")

        print("\n=== 5. edit: name, role and scope all change, audited ===")
        r = safe(A.patch, f"/api/users/{created_id}", json={
            "display_name": "User Admin Fixture (edited)",
            "role_code": "read_only", "org_unit_codes": ["DIV1"]})
        check("PATCH /api/users/{id} succeeds", r.status_code == 200,
              f"got {r.status_code}: {r.text}")
        edited = r.json() if r.status_code == 200 else {}
        check("the role and org unit were both replaced",
              any(a["org_unit_code"] == "DIV1" and a["role_code"] == "read_only"
                  for a in edited.get("assignments", []))
              and len(edited.get("assignments", [])) == 1,
              f"got {edited.get('assignments')}")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            nm = db.execute("SELECT display_name FROM app_user WHERE id = %s",
                            (created_id,)).fetchone()
            upd = db.execute("""
                SELECT count(*) AS n FROM audit_log
                 WHERE table_name = 'app_user' AND record_id = %s
                   AND action = 'UPDATE'""", (created_id,)).fetchone()
        check("the display name change persisted",
              nm["display_name"] == "User Admin Fixture (edited)", f"got {nm}")
        check("the edit is audited", upd["n"] >= 1, f"got {upd['n']}")

        print("\n=== 6. validation: out-of-scope unit and duplicate email refused ===")
        r = safe(A.post, "/api/users", json={
            "email": f"another.{FIXTURE_EMAIL}", "display_name": "X",
            "role_code": "read_only", "org_unit_codes": ["NOT_A_REAL_UNIT"]})
        check("an unknown/out-of-scope org unit is refused (404)",
              r.status_code == 404, f"got {r.status_code}: {r.text}")
        r = safe(A.post, "/api/users", json={
            "email": FIXTURE_EMAIL, "display_name": "Dupe",
            "role_code": "read_only", "org_unit_codes": ["BU2"]})
        check("a duplicate email is refused (409), not a raw 500",
              r.status_code == 409, f"got {r.status_code}: {r.text}")

        print("\n=== 7. an admin cannot deactivate their own account ===")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            me = db.execute(
                "SELECT id FROM app_user WHERE email = %s",
                ("aero.admin@demoaero.test",)).fetchone()
        r = safe(A.patch, f"/api/users/{me['id']}", json={"is_active": False})
        check("self-deactivation is refused (400)", r.status_code == 400,
              f"got {r.status_code}: {r.text}")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            still = db.execute("SELECT is_active FROM app_user WHERE id = %s",
                               (me["id"],)).fetchone()
        check("the admin is still active after the refused self-deactivation",
              still["is_active"] is True, f"got {still}")

        print("\n=== 8. deactivate: login blocked, history intact ===")
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            audit_before = db.execute("""
                SELECT count(*) AS n FROM audit_log WHERE user_id = %s""",
                (created_id,)).fetchone()["n"]

        r = safe(A.patch, f"/api/users/{created_id}", json={"is_active": False})
        check("PATCH is_active=false succeeds", r.status_code == 200,
              f"got {r.status_code}: {r.text}")

        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            row = db.execute("""
                SELECT is_active FROM app_user WHERE id = %s""",
                (created_id,)).fetchone()
            # The REAL login path, exercised directly -- this is the same
            # SECURITY DEFINER function auth.lookup_user() calls, so a
            # pass here is the real block, not a proxy for it.
            login_row = db.execute("SELECT * FROM fn_lookup_login(%s)",
                                   (FIXTURE_EMAIL,)).fetchone()
            audit_after = db.execute("""
                SELECT count(*) AS n FROM audit_log WHERE user_id = %s""",
                (created_id,)).fetchone()["n"]
            resolves = db.execute("""
                SELECT u.display_name FROM audit_log a
                  JOIN app_user u ON u.id = a.user_id
                 WHERE a.user_id = %s LIMIT 1""", (created_id,)).fetchone()

        check("the user is now inactive", row["is_active"] is False, f"got {row}")
        check("fn_lookup_login refuses the deactivated user -- the REAL "
              "login check, not a UI-level block",
              login_row is None, f"got {login_row}")
        r = safe(httpx.Client(base_url=args.base, timeout=30).post,
                 "/api/login", json={"email": FIXTURE_EMAIL})
        check("POST /api/login is refused for the deactivated user",
              r.status_code in (401, 403), f"got {r.status_code}: {r.text}")
        check("the user was NOT deleted -- the row still exists",
              row is not None)
        check("their historical audit rows (written while they were active, "
              "attributed to them as ACTOR) still exist after deactivation "
              "-- nothing was cascaded away",
              audit_after >= audit_before and audit_after > 0,
              f"before={audit_before} after={audit_after}")
        check("those audit rows still resolve to the user's display name "
              "through the same LEFT JOIN the audit endpoints use -- the "
              "historical trail is not orphaned by deactivation",
              resolves is not None and resolves["display_name"] is not None,
              f"got {resolves}")

        print("\n=== 9. reactivate restores login ===")
        r = safe(A.patch, f"/api/users/{created_id}", json={"is_active": True})
        check("PATCH is_active=true succeeds", r.status_code == 200,
              f"got {r.status_code}: {r.text}")
        r = safe(httpx.Client(base_url=args.base, timeout=30).post,
                 "/api/login", json={"email": FIXTURE_EMAIL})
        check("the reactivated user can log in again", r.status_code == 200,
              f"got {r.status_code}: {r.text}")

    finally:
        # This test created the user seconds ago and nothing real
        # references it, so removing it entirely is safe HERE -- the
        # product itself never hard-deletes (see assertion 8).
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            row = db.execute("SELECT id FROM app_user WHERE email = %s",
                             (FIXTURE_EMAIL,)).fetchone()
            if row:
                db.execute("DELETE FROM user_scope_assignment WHERE user_id = %s",
                           (row["id"],))
                db.execute("UPDATE audit_log SET user_id = NULL WHERE user_id = %s",
                           (row["id"],))
                db.execute("DELETE FROM app_user WHERE id = %s", (row["id"],))
            db.commit()
        with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
            gone = db.execute("SELECT 1 FROM app_user WHERE email = %s",
                              (FIXTURE_EMAIL,)).fetchone()
        check("cleanup: the throwaway fixture user is gone", gone is None)

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Admin user management verified end to end.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
