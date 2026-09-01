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

    print(f"\n{'='*58}")
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        return 1
    print("Staffing escalation verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
