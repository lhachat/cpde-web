#!/usr/bin/env python3
"""
test_staffing_escalation.py -- Correctness of the staffing FTE escalation
model (backlog 3f).

Ported from cda_engine/models/staffing/staffing_escalation.py and
staffing_config.py -- read directly, not reconstructed from memory. Two
things are verified independently:

  1. labor_category.is_static was PORTED, not guessed from category
     names -- checked against the exact 5 static categories named in
     cda_engine's LABOR_CATEGORIES (CM, Tech Lead, Proposal Mgr,
     Volume Leads, Pricing Lead; the other 13 are variable).
  2. GET /api/staffing/demand actually applies escalation: a known
     variable category/month combination (BDGEN / 2028-01) is checked
     against a hand-computed expected value using the ported
     cumulative-escalation formula, not just "did the number change".

    python test_staffing_escalation.py --base http://localhost:8001 ^
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


def check(name, ok, detail=""):
    (PASS if ok else FAIL).append((name, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}"
          f"{'  -- ' + detail if detail and not ok else ''}")


# Ported verbatim from cda_engine/models/staffing/staffing_config.py.
ESCALATION_BASE_YEAR = 2026
GENERIC_ESCALATION_RATES = {
    2026: 0.0283, 2027: 0.054, 2028: 0.0265,
    2029: 0.0196, 2030: 0.0193, 2031: 0.0203,
}
STATIC_CODES = {"CM", "TECHLEAD", "PROPMGR", "VOLLEADS", "PRICELEAD"}
ALL_CODES = {
    "CM", "TECHLEAD", "BDGEN", "PROPMGR", "VOLLEADS", "WRITERS", "SMEENG",
    "SMEOPS", "SMEPROD", "MATLMGR", "PRICELEAD", "PRICING", "GRAPHICS",
    "COMPLIANCE", "REVBLUE", "REVPINK", "REVRED", "REVGOLD",
}


def cumulative_factor(target_year: int, base_year: int = ESCALATION_BASE_YEAR) -> float:
    """Mirrors compute_cumulative_escalation_factor with client_rates=None."""
    if target_year <= base_year:
        return 1.0
    factor = 1.0
    for yr in range(base_year, target_year):
        factor *= 1.0 + GENERIC_ESCALATION_RATES[yr]
    return factor


def cumulative_factor_with_override(target_year: int, override_year: int,
                                    override_rate: float,
                                    base_year: int = ESCALATION_BASE_YEAR) -> float:
    """Same formula, but one year's rate is a client override -- mirrors
    resolve_escalation_rate's priority (exact-year client rate wins for
    that year only, generic everywhere else)."""
    if target_year <= base_year:
        return 1.0
    factor = 1.0
    for yr in range(base_year, target_year):
        rate = override_rate if yr == override_year else GENERIC_ESCALATION_RATES[yr]
        factor *= 1.0 + rate
    return factor


# Known fixture, captured against the loaded AERO data before this feature
# existed: GET /api/staffing/demand returned BDGEN (variable) at 2028-01 as
# 2.02 (unescalated). This is a real, reproducible aggregate over the
# currently-loaded pursuits -- not invented -- and stable across this run
# because no pursuit/staffing input data changes in this pass, only the
# escalation logic.
KNOWN_CATEGORY = "BDGEN"
KNOWN_MONTH = "2028-01"
KNOWN_UNESCALATED = 2.02
KNOWN_EXPECTED_ESCALATED = round(KNOWN_UNESCALATED / cumulative_factor(2028), 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8001")
    ap.add_argument("--admin-dsn", required=True)
    ap.add_argument("--email", default="aero.admin@demoaero.test")
    args = ap.parse_args()

    print("=== labor_category.is_static ===")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        rows = db.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name='labor_category' AND column_name='is_static'"
        ).fetchall()
        column_exists = bool(rows)
        check("is_static column exists", column_exists)

        by_code = {}
        if column_exists:
            cat_rows = db.execute(
                "SELECT code, is_static FROM labor_category ORDER BY code"
            ).fetchall()
            by_code = {r["code"]: r["is_static"] for r in cat_rows}
            check("covers all 18 known labor category codes",
                  set(by_code) == ALL_CODES,
                  f"got {sorted(set(by_code) ^ ALL_CODES)} mismatched")
            static_now = {c for c, v in by_code.items() if v}
            check("exactly the 5 ported static categories are marked static",
                  static_now == STATIC_CODES,
                  f"got {sorted(static_now)}, expected {sorted(STATIC_CODES)}")

    print(f"\n=== GET /api/staffing/demand -- {KNOWN_CATEGORY} at {KNOWN_MONTH} ===")
    print(f"  unescalated baseline: {KNOWN_UNESCALATED}")
    print(f"  hand-computed expected (cumulative factor "
          f"{cumulative_factor(2028):.6f}): {KNOWN_EXPECTED_ESCALATED}")
    c = httpx.Client(base_url=args.base, timeout=30)
    r = c.post("/api/login", json={"email": args.email})
    if r.status_code != 200:
        print(f"login failed: {r.status_code} {r.text}")
        return 1
    r = c.get("/api/staffing/demand")
    body = r.json()
    months = body.get("months", [])
    demand = body.get("demand", {})
    have_fixture = KNOWN_MONTH in months and KNOWN_CATEGORY in demand
    check(f"{KNOWN_CATEGORY}/{KNOWN_MONTH} present in current response",
          have_fixture, "fixture month/category not in current data")
    if have_fixture:
        idx = months.index(KNOWN_MONTH)
        actual = demand[KNOWN_CATEGORY][idx]
        print(f"  actual API value: {actual}")
        check(f"{KNOWN_CATEGORY} {KNOWN_MONTH} matches the hand-computed "
              f"escalated value ({KNOWN_EXPECTED_ESCALATED})",
              abs(actual - KNOWN_EXPECTED_ESCALATED) < 0.01,
              f"got {actual}")
        check(f"{KNOWN_CATEGORY} {KNOWN_MONTH} phasing note no longer claims "
              "escalation is unapplied",
              "ESCALATION NOT APPLIED" not in (body.get("phasing") or ""),
              body.get("phasing"))

    # ---- client_escalation_rate write endpoint -------------------------
    print(f"\n=== PUT /api/staffing/escalation-rates/{{year}} ===")
    OVERRIDE_YEAR = 2027   # an intermediate year in the 2026->2028 compound
    OVERRIDE_RATE = 0.10   # deliberately far from the generic 0.054 for 2027

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        pre_existing = db.execute("""
            SELECT rate FROM client_escalation_rate ce JOIN client c ON c.id = ce.client_id
             WHERE c.code = 'AERO' AND ce.calendar_year = %s""", (OVERRIDE_YEAR,)).fetchone()
    check("no override exists yet for the test year -- confirms the "
          "BEFORE state really is the plain generic-table baseline",
          pre_existing is None, f"got {pre_existing}")

    # 1. No override -> generic rate table, i.e. the KNOWN_EXPECTED_ESCALATED
    # check already run above IS this proof (ran before any PUT below).

    # 5. An implausible rate is rejected before it ever reaches the table.
    r_bad = c.put(f"/api/staffing/escalation-rates/{OVERRIDE_YEAR}", json={"rate": 5.0})
    check("an implausible rate (5.0 = 500%) is rejected",
          r_bad.status_code in (400, 422), f"got {r_bad.status_code}: {r_bad.text[:150]}")
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        still_none = db.execute("""
            SELECT rate FROM client_escalation_rate ce JOIN client c ON c.id = ce.client_id
             WHERE c.code = 'AERO' AND ce.calendar_year = %s""", (OVERRIDE_YEAR,)).fetchone()
    check("the rejected rate was never written", still_none is None, f"got {still_none}")

    # 2. A real override, PUT as an authorized role, persists AND is
    # actually consumed by the next staffing calculation -- not just
    # stored. Same BDGEN/2028-01 fixture as above, hand-recomputed with
    # 2027 overridden instead of generic.
    r_put = c.put(f"/api/staffing/escalation-rates/{OVERRIDE_YEAR}",
                  json={"rate": OVERRIDE_RATE})
    check("PUT with a plausible rate as an authorized role succeeds",
          r_put.status_code == 200, f"got {r_put.status_code}: {r_put.text[:200]}")

    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        written = db.execute("""
            SELECT rate FROM client_escalation_rate ce JOIN client c ON c.id = ce.client_id
             WHERE c.code = 'AERO' AND ce.calendar_year = %s""", (OVERRIDE_YEAR,)).fetchone()
    check("the override rate was written to client_escalation_rate",
          written is not None and abs(float(written["rate"]) - OVERRIDE_RATE) < 1e-6,
          f"got {written}")

    expected_after_override = round(
        KNOWN_UNESCALATED / cumulative_factor_with_override(
            2028, OVERRIDE_YEAR, OVERRIDE_RATE), 2)
    print(f"  expected AFTER override (2027 -> {OVERRIDE_RATE}): "
          f"{expected_after_override} (was {KNOWN_EXPECTED_ESCALATED})")
    r2 = c.get("/api/staffing/demand")
    body2 = r2.json()
    months2, demand2 = body2.get("months", []), body2.get("demand", {})
    if KNOWN_MONTH in months2 and KNOWN_CATEGORY in demand2:
        idx2 = months2.index(KNOWN_MONTH)
        actual_after = demand2[KNOWN_CATEGORY][idx2]
        print(f"  actual API value AFTER override: {actual_after}")
        # Escalation is applied per-pursuit (each contribution divided by
        # the same cumulative factor) THEN summed, whereas this hand
        # check divides the already-summed 2.02 once -- mathematically
        # equal, but floating-point summation order can land a shared
        # two-decimal rounding a single cent apart. 0.02 still proves
        # real consumption (a wrong/unconsumed override would be off by
        # far more) without being sensitive to that summation-order noise.
        check(f"{KNOWN_CATEGORY} {KNOWN_MONTH} reflects the override -- "
              "the calculation actually CONSUMES it, not just stores it",
              abs(actual_after - expected_after_override) < 0.02,
              f"got {actual_after}, expected {expected_after_override}")
        check("the override genuinely changed the result (not a "
              "coincidental match with the un-overridden value)",
              abs(actual_after - KNOWN_EXPECTED_ESCALATED) > 0.01,
              f"before={KNOWN_EXPECTED_ESCALATED} after={actual_after}")
    else:
        check(f"{KNOWN_CATEGORY}/{KNOWN_MONTH} present after override", False,
              "fixture month/category missing")

    # Clean up -- this row never existed before this test run.
    with psycopg.connect(args.admin_dsn, row_factory=dict_row) as db:
        db.execute("""
            DELETE FROM client_escalation_rate
             WHERE client_id = (SELECT id FROM client WHERE code = 'AERO')
               AND calendar_year = %s""", (OVERRIDE_YEAR,))
        db.commit()
    r3 = c.get("/api/staffing/demand")
    body3 = r3.json()
    months3, demand3 = body3.get("months", []), body3.get("demand", {})
    if KNOWN_MONTH in months3 and KNOWN_CATEGORY in demand3:
        idx3 = months3.index(KNOWN_MONTH)
        restored = demand3[KNOWN_CATEGORY][idx3]
        check("after cleanup, the calculation reverts to the original "
              "un-overridden value",
              abs(restored - KNOWN_EXPECTED_ESCALATED) < 0.01,
              f"got {restored}, expected {KNOWN_EXPECTED_ESCALATED}")

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        return 1
    print("Staffing escalation verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
