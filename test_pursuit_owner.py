#!/usr/bin/env python3
"""
test_pursuit_owner.py -- backlog item 3g, Owner/POC field on pursuit.

pursuit.owner_user_id (ddl/18_pursuit_owner.sql), nullable FK to
app_user, same PATCH/audit discipline as every other pursuit field.
The picker is scoped to the PURSUIT'S OWN org node's visible-user set
(plan_scope.owner_candidates_by_org_node / resolve_pursuit_owner),
NOT the caller's own scope and NOT every user in the tenant -- a
full-scope admin editing a narrow BU's pursuit should only be offered
that BU's own people.

Fixtures reused from test_scope.py / test_api_security.py's own
established set (idempotent, safe standalone or as part of the suite):
  aero.admin@demoaero.test  -- BUSINESS root, admin role (full scope)
  aero.bu2@demoaero.test    -- BU2, capture_manager (narrow, real pursuits)
  aero.div1@demoaero.test   -- DIV1, a DIFFERENT branch than BU2 -- used
                                to prove an out-of-scope owner is rejected

    python test_pursuit_owner.py --base http://localhost:8001 ^
      --admin-dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Requires the API running (real HTTP calls, same reasoning as
test_api_security.py: only the endpoint proves scope is actually
CHECKED, not just representable in the schema). Exit 0 = all passed.
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
        users = {r["email"]: r["id"] for r in db.execute(
            "SELECT email, id FROM app_user WHERE client_id = %s", (aero,)).fetchall()}
        n_active_users = db.execute(
            "SELECT count(*) AS n FROM app_user WHERE client_id = %s AND is_active",
            (aero,)).fetchone()["n"]
        bu2_pursuit = db.execute("""
            SELECT p.id, p.owner_user_id FROM pursuit p
              JOIN org_node o ON o.id = p.org_node_id
             WHERE o.code = 'BU2' AND p.client_id = %s AND p.is_active
               AND p.outcome IS NULL LIMIT 1""", (aero,)).fetchone()
        div1_pursuit = db.execute("""
            SELECT p.id FROM pursuit p
              JOIN org_node o ON o.id = p.org_node_id
             WHERE o.code = 'DIV1' AND p.client_id = %s AND p.is_active
               AND p.outcome IS NULL LIMIT 1""", (aero,)).fetchone()

    admin_u, bu2_u, div_u = (users["aero.admin@demoaero.test"],
                             users["aero.bu2@demoaero.test"],
                             users["aero.div1@demoaero.test"])

    A = login(args.base, "aero.admin@demoaero.test")   # full scope
    N = login(args.base, "aero.bu2@demoaero.test")      # narrow: BU2 only

    # ---- 1. candidate list is scoped to the PURSUIT's own org node, --
    #         not the caller's scope and not every user in the tenant --
    print("=== 1. owner candidate list is scoped correctly ===")
    n_boot = safe(N.get, "/api/bootstrap").json()
    a_boot = safe(A.get, "/api/bootstrap").json()
    n_cands = (n_boot.get("owner_candidates") or {}).get("BU2", [])
    n_cand_emails = {c["email"] for c in n_cands}
    check("BU2's own candidate list exists and is non-empty",
          len(n_cands) > 0, f"got {n_cands}")
    check("BU2's candidate list includes the BU2-scoped user",
          "aero.bu2@demoaero.test" in n_cand_emails, f"got {n_cand_emails}")
    check("BU2's candidate list includes the full-scope admin (BUSINESS "
          "root covers BU2 downward)",
          "aero.admin@demoaero.test" in n_cand_emails, f"got {n_cand_emails}")
    check("BU2's candidate list does NOT include the DIV1-scoped user "
          "-- a different, unrelated branch of the tree",
          "aero.div1@demoaero.test" not in n_cand_emails, f"got {n_cand_emails}")
    check("BU2's candidate list is strictly smaller than every active "
          "user in the tenant -- not just 'every user'",
          0 < len(n_cands) < n_active_users,
          f"got {len(n_cands)} of {n_active_users} active users")

    a_all_cands = {c["email"] for lst in (a_boot.get("owner_candidates") or {}).values()
                  for c in lst}
    check("the full-scope admin's aggregate candidate pool (across every "
          "org node their own pursuits span) is strictly larger than the "
          "narrow-scoped user's",
          len(a_all_cands) > len(n_cand_emails),
          f"admin pool {len(a_all_cands)}, BU2-only pool {len(n_cand_emails)}")

    if not bu2_pursuit or not div1_pursuit:
        check("a real BU2 pursuit and a real DIV1 pursuit exist to test "
              "against", False, "none found -- cannot run sections 2/3")
        print(f"\n{'='*58}\n{len(PASS)} passed, {len(FAIL)} failed")
        return 1

    # ---- 2. assigning an owner outside scope is rejected --------------
    print("\n=== 2. assigning an out-of-scope owner is rejected, not "
          "silently accepted ===")
    r = safe(N.patch, f"/api/pursuits/{bu2_pursuit['id']}",
             json={"owner_user_id": str(div_u)})
    check("PATCH with an out-of-scope owner (DIV1 user, on a BU2 "
          "pursuit) is rejected", r.status_code == 404,
          f"got {r.status_code}: {r.text}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        after = db.execute("SELECT owner_user_id FROM pursuit WHERE id=%s",
                           (bu2_pursuit["id"],)).fetchone()
    check("the rejected assignment was never written",
          after["owner_user_id"] == bu2_pursuit["owner_user_id"],
          f"owner_user_id changed to {after['owner_user_id']}")

    # ---- 3. a successful assignment writes, audits, and displays ------
    print("\n=== 3. a successful assignment writes correctly, shows in "
          "audit history, and displays on the pursuit detail view ===")
    r = safe(N.patch, f"/api/pursuits/{bu2_pursuit['id']}",
             json={"owner_user_id": str(bu2_u)})
    check("PATCH with an in-scope owner (BU2 user, on a BU2 pursuit) "
          "succeeds", r.status_code == 200, f"got {r.status_code}: {r.text}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        row = db.execute("SELECT owner_user_id FROM pursuit WHERE id=%s",
                         (bu2_pursuit["id"],)).fetchone()
    check("the write actually landed in the database",
          row and str(row["owner_user_id"]) == str(bu2_u),
          f"got {row}")

    hist = safe(N.get, f"/api/pursuits/{bu2_pursuit['id']}/history").json()
    owner_entry = next((h for h in hist
                        if "owner_user_id" in (h.get("changed_fields") or {})), None)
    check("the change appears in audit history", owner_entry is not None,
          f"got {[h.get('changed_fields') for h in hist[:3]]}")
    if owner_entry:
        to_val = owner_entry["changed_fields"]["owner_user_id"].get("to")
        check("audit history shows a resolved display name, not a raw uuid",
              to_val and "-" not in str(to_val)[:8],
              f"got {to_val!r}")

    boot_after = safe(N.get, "/api/bootstrap").json()
    # bootstrap's JSON ids are strings; bu2_pursuit["id"] is a psycopg
    # UUID object -- compare as strings, or this silently never matches.
    row2 = next((x for x in boot_after["pursuits"]
                if x["id"] == str(bu2_pursuit["id"])), None)
    check("the pursuit's owner name now displays in the bootstrap "
          "payload (pursuit detail view's data source)",
          row2 is not None and row2.get("owner_name") is not None,
          f"got {row2.get('owner_name') if row2 else None}")

    # ---- cleanup: restore the original owner_user_id -------------------
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        db.execute("UPDATE pursuit SET owner_user_id = %s WHERE id = %s",
                  (bu2_pursuit["owner_user_id"], bu2_pursuit["id"]))
        db.commit()
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        restored = db.execute("SELECT owner_user_id FROM pursuit WHERE id=%s",
                              (bu2_pursuit["id"],)).fetchone()
    check("test fixture restored to its original owner_user_id",
          restored["owner_user_id"] == bu2_pursuit["owner_user_id"],
          f"got {restored}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("\nFAILURES:")
        for name, d in FAIL:
            print(f"  - {name}: {d}")
        return 1
    print("Pursuit Owner/POC field verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
