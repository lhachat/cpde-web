-- =====================================================================
-- rebalance_plan_targets.sql -- Split company-wide targets across BU/BU2
--
-- WHY: the single existing plan_year row (under "Advanced Systems"/BU)
-- was set when that node implicitly held every AERO pursuit. Now that
-- pursuits are split across BU (via DIV1/2/3) and BU2 (Space Systems),
-- that row still holds 100% of the company's target dollars while only
-- representing part of the actual pipeline. BU2 has no plan_year row
-- at all -- picking it in the Dashboard or Targets & Budgets shows zero,
-- correctly, but uselessly for testing.
--
-- WHAT THIS DOES:
--   1. Computes each license-boundary node's share of total probabilistic
--      revenue (award value x Pwin, open + bid pursuits only, rolled up
--      through any divisions beneath it).
--   2. Copies BU's current escalation_rate UNCHANGED into new BU2 rows,
--      per year -- escalation is not something to split, it is the same
--      economic assumption regardless of which org is being measured.
--   3. Splits revenue_target, fee_target, budgeted_bp, budgeted_investment
--      proportionally to that revenue share, for both BU and BU2.
--
-- NOT touched: current_contract_revenue / current_contract_fee. Those
-- are manual, already-under-contract entries with no natural way to
-- split by pipeline share. Left as-is on BU's row, NULL (not entered)
-- on BU2's new rows -- distinct from zero, same convention as the
-- original migration.
--
-- Order matters: BU2's rows are inserted FIRST, reading BU's still-
-- unmodified (company-wide) values. BU's rows are reduced SECOND. This
-- avoids needing a snapshot/temp table -- each statement reads exactly
-- the data it should.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Each AERO pursuit's nearest LICENSE-BOUNDARY ancestor (inclusive).
-- Written as a walk-up rather than hardcoded to "division's parent is
-- always the boundary" -- correct regardless of how deep a client's
-- tree happens to be.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE _pursuit_boundary AS
WITH RECURSIVE up(pursuit_id, node_id, is_boundary) AS (
    SELECT p.id, p.org_node_id, o.is_license_boundary
      FROM pursuit p
      JOIN org_node o ON o.id = p.org_node_id
      JOIN client c ON c.id = p.client_id
     WHERE c.code = 'AERO' AND p.is_active
    UNION ALL
    SELECT up.pursuit_id, o.parent_id, o.is_license_boundary
      FROM up
      JOIN org_node o ON o.id = up.node_id
     WHERE NOT up.is_boundary AND o.parent_id IS NOT NULL
)
SELECT DISTINCT ON (pursuit_id) pursuit_id, node_id AS boundary_node_id
  FROM up
 WHERE is_boundary
 ORDER BY pursuit_id, node_id;  -- first boundary hit walking upward

-- ---------------------------------------------------------------------
-- Probabilistic revenue share per boundary node. Open, bid pursuits
-- only -- matches the "bid pursuits, cancelled excluded" convention
-- already used on the Dashboard.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE _share AS
WITH prob AS (
    SELECT pb.boundary_node_id,
           sum(p.planned_total_award_value * COALESCE(a.pwin, 0)) AS prob_rev
      FROM _pursuit_boundary pb
      JOIN pursuit p ON p.id = pb.pursuit_id
      LEFT JOIN pwin_assessment a
             ON a.pursuit_id = p.id AND a.scenario = 'BASE' AND a.is_current
     WHERE p.bid_decision = 'BID' AND p.outcome IS NULL
     GROUP BY pb.boundary_node_id
)
SELECT boundary_node_id,
       prob_rev,
       prob_rev / NULLIF(sum(prob_rev) OVER (), 0) AS share
  FROM prob;

-- Sanity check before writing anything: shares should sum to ~1.0.
DO $$
DECLARE total NUMERIC;
BEGIN
    SELECT sum(share) INTO total FROM _share;
    IF total IS NULL OR abs(total - 1.0) > 0.0001 THEN
        RAISE EXCEPTION 'Revenue shares do not sum to 1.0 (got %) -- '
                        'aborting rather than write a wrong split', total;
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- Step 1: insert BU2's rows FIRST, from BU's still-original values.
-- ---------------------------------------------------------------------
INSERT INTO plan_year (org_node_id, calendar_year, escalation_rate,
                       revenue_target, fee_target, budgeted_bp,
                       budgeted_investment)
SELECT bu2.id, py.calendar_year, py.escalation_rate,
       round(py.revenue_target      * s2.share),
       round(py.fee_target          * s2.share),
       round(py.budgeted_bp         * s2.share),
       round(py.budgeted_investment * s2.share)
  FROM plan_year py
  JOIN org_node bu ON bu.id = py.org_node_id AND bu.code = 'BU'
  JOIN client c ON c.id = bu.client_id AND c.code = 'AERO'
  JOIN org_node bu2 ON bu2.client_id = c.id AND bu2.code = 'BU2'
  JOIN _share s2 ON s2.boundary_node_id = bu2.id
ON CONFLICT (org_node_id, calendar_year) DO UPDATE SET
    escalation_rate     = EXCLUDED.escalation_rate,
    revenue_target      = EXCLUDED.revenue_target,
    fee_target          = EXCLUDED.fee_target,
    budgeted_bp         = EXCLUDED.budgeted_bp,
    budgeted_investment = EXCLUDED.budgeted_investment;

-- ---------------------------------------------------------------------
-- Step 2: reduce BU's rows to its own share, second, so step 1 above
-- already captured the pre-reduction values.
-- ---------------------------------------------------------------------
UPDATE plan_year py
   SET revenue_target      = round(py.revenue_target      * s.share),
       fee_target          = round(py.fee_target          * s.share),
       budgeted_bp         = round(py.budgeted_bp         * s.share),
       budgeted_investment = round(py.budgeted_investment * s.share)
  FROM org_node bu
  JOIN client c ON c.id = bu.client_id AND c.code = 'AERO'
  JOIN _share s ON s.boundary_node_id = bu.id
 WHERE py.org_node_id = bu.id AND bu.code = 'BU';

DROP TABLE _pursuit_boundary;
DROP TABLE _share;

COMMIT;

-- =====================================================================
-- VERIFY
-- =====================================================================
SELECT o.code, o.name, py.calendar_year, py.escalation_rate,
       py.revenue_target, py.fee_target, py.budgeted_bp,
       py.budgeted_investment
  FROM plan_year py
  JOIN org_node o ON o.id = py.org_node_id
  JOIN client c ON c.id = o.client_id
 WHERE c.code = 'AERO'
 ORDER BY o.code, py.calendar_year;

-- The two nodes' revenue_target columns should now sum, year by year,
-- to what the single BU row used to show before this ran.
