#!/usr/bin/env python3
"""
test_integrity.py -- Assertions about the DATA, not the security.

WHY THIS EXISTS: the calendar_year bug returned HTTP 200, ran a valid query,
joined correctly, and matched nothing. The dashboard was empty and nothing
pointed at the cause -- an empty chart looks like "no data yet", not like a
null join key. That class of bug does not announce itself, so it has to be
asserted against.

Rule going forward: every structural assumption the application relies on
gets an assertion here. If a query depends on a column being populated, this
file says so.

    python test_integrity.py --dsn "postgresql://cpde:localdev@localhost:5433/cpde"

Runs as the superuser deliberately: this checks data across ALL tenants,
which is the opposite of what the security suites do.

Exit 0 = clean. 1 = at least one ERROR. WARNs do not fail the run.
"""
from __future__ import annotations

import argparse
import sys

import psycopg
from psycopg.rows import dict_row

ERRORS: list[str] = []
WARNS: list[str] = []


def check(cur, name, sql, params=(), severity="ERROR", expect_zero=True):
    """Run a query that should return no rows. Any row is a finding."""
    cur.execute(sql, params)
    rows = cur.fetchall()
    bad = len(rows) if expect_zero else 0
    if bad:
        sample = "; ".join(str(dict(r)) for r in rows[:3])
        msg = f"{name}: {bad} row(s) -- {sample}"
        (ERRORS if severity == "ERROR" else WARNS).append(msg)
        print(f"  {severity:5} {name}: {bad} row(s)")
        for r in rows[:3]:
            print(f"          {dict(r)}")
        if bad > 3:
            print(f"          ... and {bad - 3} more")
    else:
        print(f"  ok    {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    args = ap.parse_args()

    with psycopg.connect(args.dsn, row_factory=dict_row) as conn:
        cur = conn.cursor()

        print("=== completeness: columns the application joins on ===")
        # This is the bug that prompted the file.
        check(cur, "every year projection is dated", """
            SELECT p.external_opportunity_id, yp.year_offset
              FROM pursuit_year_projection yp
              JOIN pursuit p ON p.id = yp.pursuit_id
             WHERE yp.calendar_year IS NULL LIMIT 20""")

        check(cur, "every pursuit has a market", """
            SELECT external_opportunity_id, name FROM pursuit
             WHERE market_id IS NULL AND is_active LIMIT 20""")

        check(cur, "every pursuit has a bid decision", """
            SELECT external_opportunity_id, name FROM pursuit
             WHERE bid_decision IS NULL AND is_active LIMIT 20""")

        check(cur, "every pursuit has an opportunity type", """
            SELECT external_opportunity_id, name FROM pursuit
             WHERE opportunity_type_id IS NULL AND is_active LIMIT 20""")

        check(cur, "every pursuit has an award value", """
            SELECT external_opportunity_id, name FROM pursuit
             WHERE planned_total_award_value IS NULL AND is_active LIMIT 20""")

        print("\n=== assessments ===")
        check(cur, "every pursuit has a current BASE assessment", """
            SELECT p.external_opportunity_id, p.name
              FROM pursuit p
             WHERE p.is_active AND NOT EXISTS (
                   SELECT 1 FROM pwin_assessment a
                    WHERE a.pursuit_id = p.id
                      AND a.scenario = 'BASE' AND a.is_current) LIMIT 20""")

        # The rule from the workbook: a dependent pursuit is not valid with
        # only one of its two assessments.
        check(cur, "dependent pursuits have BOTH assessments", """
            SELECT p.external_opportunity_id, p.name
              FROM pursuit p
             WHERE p.depends_on_pursuit_id IS NOT NULL AND p.is_active
               AND NOT EXISTS (SELECT 1 FROM pwin_assessment a
                                WHERE a.pursuit_id = p.id
                                  AND a.scenario = 'DEPENDENT_WON'
                                  AND a.is_current) LIMIT 20""")

        check(cur, "no DEPENDENT_WON without a dependency", """
            SELECT p.external_opportunity_id, p.name
              FROM pwin_assessment a
              JOIN pursuit p ON p.id = a.pursuit_id
             WHERE a.scenario = 'DEPENDENT_WON' AND a.is_current
               AND p.depends_on_pursuit_id IS NULL LIMIT 20""")

        check(cur, "at most one current assessment per pursuit+scenario", """
            SELECT pursuit_id, scenario, count(*) AS n
              FROM pwin_assessment WHERE is_current
             GROUP BY pursuit_id, scenario HAVING count(*) > 1 LIMIT 20""")

        check(cur, "pwin is a probability", """
            SELECT p.external_opportunity_id, a.pwin
              FROM pwin_assessment a JOIN pursuit p ON p.id = a.pursuit_id
             WHERE a.pwin IS NOT NULL AND (a.pwin < 0 OR a.pwin > 1) LIMIT 20""")

        # BLACK_HAT/PTW rows are analyst-entered directly onto columns
        # (aggressiveness_option_id, margin_rate, bid_price) -- they never
        # have pwin_answer children, by design. Only a QUESTIONNAIRE
        # assessment is expected to.
        check(cur, "every questionnaire assessment has answers", """
            SELECT p.external_opportunity_id, a.scenario
              FROM pwin_assessment a
              JOIN pursuit p ON p.id = a.pursuit_id
             WHERE a.is_current AND a.assessment_type = 'QUESTIONNAIRE'
               AND NOT EXISTS (
                   SELECT 1 FROM pwin_answer w WHERE w.pwin_assessment_id = a.id)
             LIMIT 20""")

        print("\n=== assessment provenance ===")
        # The phase is not a label. It records where the Pwin came from,
        # which is the basis of the accuracy claim. A Post-PTW pursuit whose
        # current assessment is a questionnaire is quoting +/-1% precision
        # it does not have.
        check(cur, "assessment type matches the pursuit's phase", """
            SELECT p.external_opportunity_id, ps.code AS stage,
                   a.assessment_type
              FROM pursuit p
              JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
              JOIN pwin_assessment a ON a.pursuit_id = p.id AND a.is_current
                                    AND a.scenario = 'BASE'
             WHERE p.is_active
               AND a.assessment_type
                   IS DISTINCT FROM fn_expected_assessment_type(ps.code)
             LIMIT 20""", severity="WARN")

        check(cur, "a questionnaire assessment names its version", """
            SELECT id FROM pwin_assessment
             WHERE assessment_type = 'QUESTIONNAIRE'
               AND questionnaire_version_id IS NULL LIMIT 20""")

        check(cur, "PTW assessments carry a margin and a bid price", """
            SELECT p.external_opportunity_id, a.margin_rate, a.bid_price
              FROM pwin_assessment a JOIN pursuit p ON p.id = a.pursuit_id
             WHERE a.assessment_type = 'PTW' AND a.is_current
               AND (a.margin_rate IS NULL OR a.bid_price IS NULL) LIMIT 20""",
              severity="WARN")

        check(cur, "PTW margin is within the 30% cap", """
            SELECT p.external_opportunity_id, a.margin_rate
              FROM pwin_assessment a JOIN pursuit p ON p.id = a.pursuit_id
             WHERE a.assessment_type = 'PTW'
               AND a.margin_rate > 0.30 LIMIT 20""")

        check(cur, "Black Hat assessments record an aggressiveness", """
            SELECT p.external_opportunity_id
              FROM pwin_assessment a JOIN pursuit p ON p.id = a.pursuit_id
             WHERE a.assessment_type = 'BLACK_HAT' AND a.is_current
               AND a.aggressiveness_option_id IS NULL LIMIT 20""",
              severity="WARN")

        # The form refuses to open without one; the data should reflect that.
        check(cur, "BH/PTW is preceded by a questionnaire assessment", """
            SELECT DISTINCT p.external_opportunity_id
              FROM pwin_assessment a JOIN pursuit p ON p.id = a.pursuit_id
             WHERE a.assessment_type IN ('BLACK_HAT','PTW')
               AND NOT EXISTS (SELECT 1 FROM pwin_assessment q
                                WHERE q.pursuit_id = a.pursuit_id
                                  AND q.assessment_type = 'QUESTIONNAIRE')
             LIMIT 20""")

        check(cur, "a completed BH/PTW is dated on or after B&P start", """
            SELECT p.external_opportunity_id, a.completed_date, p.bp_start_date
              FROM pwin_assessment a JOIN pursuit p ON p.id = a.pursuit_id
             WHERE a.assessment_type IN ('BLACK_HAT','PTW')
               AND a.completed_date IS NOT NULL
               AND p.bp_start_date IS NOT NULL
               AND a.completed_date < p.bp_start_date LIMIT 20""")

        print("\n=== questionnaire rules (PwinForm cascades) ===")
        # TM2 determines the TM3 option list. Stored data must obey it.
        check(cur, "TM3 answer is legal for its TM2 answer", """
            WITH ans AS (
              SELECT a.id, a.pursuit_id,
                     max(o.code) FILTER (WHERE q.code='TM2') AS tm2,
                     max(o.code) FILTER (WHERE q.code='TM3') AS tm3
                FROM pwin_assessment a
                JOIN pwin_answer w ON w.pwin_assessment_id = a.id
                JOIN question q ON q.id = w.question_id
                JOIN question_option o ON o.id = w.question_option_id
               WHERE a.is_current GROUP BY a.id, a.pursuit_id)
            SELECT p.external_opportunity_id, ans.tm2, ans.tm3
              FROM ans JOIN pursuit p ON p.id = ans.pursuit_id
             WHERE ans.tm2 IS NOT NULL AND ans.tm3 IS NOT NULL
               AND NOT (
                 (ans.tm2 = 'YES_US'      AND ans.tm3 IN ('WE_SATISFACTORY','WE_ISSUES'))
              OR (ans.tm2 = 'YES_COMPETITOR' AND ans.tm3 IN ('INCUMBENT_SATISFACTORY','INCUMBENT_ISSUES'))
              OR (ans.tm2 = 'NO'          AND ans.tm3 = 'NA'))
             LIMIT 20""")

        check(cur, "answer options belong to their question", """
            SELECT w.id FROM pwin_answer w
              JOIN question_option o ON o.id = w.question_option_id
             WHERE o.question_id <> w.question_id LIMIT 20""")

        print("\n=== referential and tenancy consistency ===")
        for child, parent, fk in [
            ("pursuit_year_projection", "pursuit", "pursuit_id"),
            ("pursuit_staffing", "pursuit", "pursuit_id"),
            ("pursuit_phase_duration", "pursuit", "pursuit_id"),
            ("pwin_assessment", "pursuit", "pursuit_id"),
        ]:
            check(cur, f"{child}.client_id matches its {parent}", f"""
                SELECT c.id FROM {child} c JOIN {parent} p ON p.id = c.{fk}
                 WHERE c.client_id <> p.client_id LIMIT 20""")

        check(cur, "pwin_answer.client_id matches its assessment", """
            SELECT w.id FROM pwin_answer w
              JOIN pwin_assessment a ON a.id = w.pwin_assessment_id
             WHERE w.client_id <> a.client_id LIMIT 20""")

        check(cur, "pursuit market belongs to the same client", """
            SELECT p.external_opportunity_id FROM pursuit p
              JOIN market m ON m.id = p.market_id
             WHERE m.client_id <> p.client_id LIMIT 20""")

        check(cur, "pursuit org node belongs to the same client", """
            SELECT p.external_opportunity_id FROM pursuit p
              JOIN org_node o ON o.id = p.org_node_id
             WHERE o.client_id <> p.client_id LIMIT 20""")

        check(cur, "dependencies stay within a client", """
            SELECT p.external_opportunity_id FROM pursuit p
              JOIN pursuit d ON d.id = p.depends_on_pursuit_id
             WHERE d.client_id <> p.client_id LIMIT 20""")

        check(cur, "no self-referencing dependency", """
            SELECT external_opportunity_id FROM pursuit
             WHERE depends_on_pursuit_id = id LIMIT 20""")

        print("\n=== planning coverage ===")
        check(cur, "plan_year covers every projected year", """
            SELECT DISTINCT c.code, yp.calendar_year
              FROM pursuit_year_projection yp
              JOIN client c ON c.id = yp.client_id
             WHERE yp.calendar_year IS NOT NULL
               AND NOT EXISTS (
                   SELECT 1 FROM plan_year y
                     JOIN org_node o ON o.id = y.org_node_id
                    WHERE o.client_id = yp.client_id
                      AND y.calendar_year = yp.calendar_year)
             ORDER BY 1,2 LIMIT 20""", severity="WARN")

        check(cur, "every client has plan years", """
            SELECT c.code FROM client c
             WHERE c.is_active AND NOT EXISTS (
                   SELECT 1 FROM plan_year y JOIN org_node o ON o.id = y.org_node_id
                    WHERE o.client_id = c.id) LIMIT 20""")

        print("\n=== business rules ===")
        check(cur, "sole source implies a single bidder", """
            SELECT external_opportunity_id, bidders FROM pursuit
             WHERE is_sole_source AND bidders IS NOT NULL AND bidders <> 1
             LIMIT 20""", severity="WARN")

        check(cur, "dates are in order", """
            SELECT external_opportunity_id, bp_start_date, proposal_due_date,
                   contract_award_date, period_end_date
              FROM pursuit
             WHERE (proposal_due_date < bp_start_date)
                OR (contract_award_date < proposal_due_date)
                OR (period_end_date < contract_award_date) LIMIT 20""")

        check(cur, "no Black Hat or PTW before B&P starts", """
            SELECT p.external_opportunity_id, ps.code, p.bp_start_date
              FROM pursuit p JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
             WHERE ps.code <> 'PRE_BH' AND p.bp_start_date > CURRENT_DATE
             LIMIT 20""", severity="WARN")

        # You cannot win or lose something you did not bid. A cancelled
        # solicitation is different -- it can be cancelled at any point,
        # including before a bid decision was ever made.
        check(cur, "won or lost implies the pursuit was bid", """
            SELECT external_opportunity_id, outcome, bid_decision
              FROM pursuit
             WHERE outcome IN ('WON','LOST')
               AND (bid_decision IS DISTINCT FROM 'BID') LIMIT 20""")

        check(cur, "closed pursuits have an outcome date", """
            SELECT external_opportunity_id, outcome FROM pursuit
             WHERE outcome IS NOT NULL AND outcome_date IS NULL
               AND contract_award_date IS NULL LIMIT 20""", severity="WARN")

        print("\n=== engine wiring ===")
        check(cur, "every client maps to an engine identity", """
            SELECT code FROM client
             WHERE is_active AND (engine_client_code IS NULL
                               OR engine_secret_ref IS NULL) LIMIT 20""")

        # NOTE: %% is required -- psycopg reads a single % as a placeholder.
        check(cur, "no credential stored in the database", """
            SELECT code, engine_secret_ref FROM client
             WHERE engine_secret_ref IS NOT NULL
               AND engine_secret_ref NOT LIKE '/%%'
               AND engine_secret_ref NOT LIKE 'arn:%%' LIMIT 20""")

        print("\n=== security invariants ===")
        # Exactly two are expected and each is justified in its own file:
        #   fn_lookup_login -- authentication must precede tenant resolution
        #   fn_audit        -- an audit row must be writable even when the
        #                      policy it is recording would block it
        # A third appearing is a finding, not a feature.
        check(cur, "no unexpected SECURITY DEFINER function", """
            SELECT p.proname FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.prosecdef
               AND p.proname NOT IN ('fn_lookup_login','fn_audit') LIMIT 20""")

        check(cur, "audit trigger is attached to pursuit", """
            SELECT 'missing' AS problem
             WHERE NOT EXISTS (
                   SELECT 1 FROM pg_trigger t
                     JOIN pg_class c ON c.oid = t.tgrelid
                    WHERE c.relname = 'pursuit' AND t.tgname = 'trg_audit'
                      AND NOT t.tgisinternal)""")

        check(cur, "application role cannot alter the audit log", """
            SELECT 'can_update' AS problem
             WHERE has_table_privilege('cpde_app','audit_log','UPDATE')
                OR has_table_privilege('cpde_app','audit_log','DELETE')""")

        check(cur, "every table with client_id has RLS forced", """
            SELECT c.relname FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND c.relkind = 'r'
               AND EXISTS (SELECT 1 FROM pg_attribute a
                            WHERE a.attrelid = c.oid AND a.attname = 'client_id'
                              AND NOT a.attisdropped)
               AND NOT (c.relrowsecurity AND c.relforcerowsecurity) LIMIT 20""")

        check(cur, "application role cannot bypass RLS", """
            SELECT rolname FROM pg_roles
             WHERE rolname IN ('cpde_app','cpde_api')
               AND (rolsuper OR rolbypassrls) LIMIT 20""")

    print(f"\n{'='*58}")
    print(f"{len(ERRORS)} error(s), {len(WARNS)} warning(s)")
    if WARNS:
        print("\nWARNINGS (not failing):")
        for w in WARNS:
            print(f"  - {w[:150]}")
    if ERRORS:
        print("\nERRORS:")
        for e in ERRORS:
            print(f"  - {e[:150]}")
        return 1
    print("Data integrity verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
