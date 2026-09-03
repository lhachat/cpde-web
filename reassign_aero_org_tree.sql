-- =====================================================================
-- reassign_aero_org_tree.sql -- Give AERO a real, testable org structure
--
-- Current tree:
--   Business (Demo Aerospace)
--     BU (Advanced Systems) -> Division (Sensors Division / DIV1)
--     BU2 (Space Systems)                       <- currently empty
--
-- Target tree:
--   Business (Demo Aerospace)
--     BU (Advanced Systems)
--       DIV1 Sensors   <- GSS, ACP
--       DIV2 Services  <- SUS, TRN
--       DIV3 Radios    <- MSN
--     BU2 (Space Systems)                       <- SPC, directly (no division)
--
-- Reassignment is by pursuit.market_id only. Nothing else changes --
-- pursuit_staffing, pursuit_year_projection, pwin_assessment/answer all
-- key off pursuit_id, which is untouched, so nothing cascades incorrectly.
--
-- This is DATA, matching how one real client's structure happens to work
-- today. It is deliberately NOT a schema constraint -- a market spanning
-- multiple business units (the more common real case) must stay possible.
-- Nothing in this file adds a market->org_node rule at the schema level.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Create the two new divisions under Advanced Systems (BU).
--    Idempotent: ON CONFLICT DO NOTHING keyed on (client_id, code).
-- ---------------------------------------------------------------------
INSERT INTO org_node (client_id, parent_id, node_type, code, name, is_active)
SELECT c.id, bu.id, 'division', 'DIV2', 'Services', TRUE
  FROM client c
  JOIN org_node bu ON bu.client_id = c.id AND bu.code = 'BU'
 WHERE c.code = 'AERO'
ON CONFLICT (client_id, code) DO NOTHING;

INSERT INTO org_node (client_id, parent_id, node_type, code, name, is_active)
SELECT c.id, bu.id, 'division', 'DIV3', 'Radios', TRUE
  FROM client c
  JOIN org_node bu ON bu.client_id = c.id AND bu.code = 'BU'
 WHERE c.code = 'AERO'
ON CONFLICT (client_id, code) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. Reassign every AERO pursuit's org_node_id by its market code.
-- ---------------------------------------------------------------------
WITH aero AS (SELECT id FROM client WHERE code = 'AERO'),
     nodes AS (
       SELECT code, id FROM org_node
        WHERE client_id = (SELECT id FROM aero)
     ),
     mkt AS (
       SELECT code, id FROM market
        WHERE client_id = (SELECT id FROM aero)
     )
UPDATE pursuit p
   SET org_node_id = CASE m.code
         WHEN 'GSS' THEN (SELECT id FROM nodes WHERE code = 'DIV1')
         WHEN 'ACP' THEN (SELECT id FROM nodes WHERE code = 'DIV1')
         WHEN 'SUS' THEN (SELECT id FROM nodes WHERE code = 'DIV2')
         WHEN 'TRN' THEN (SELECT id FROM nodes WHERE code = 'DIV2')
         WHEN 'MSN' THEN (SELECT id FROM nodes WHERE code = 'DIV3')
         WHEN 'SPC' THEN (SELECT id FROM nodes WHERE code = 'BU2')
       END
  FROM mkt m
 WHERE p.client_id = (SELECT id FROM aero)
   AND p.market_id = m.id
   AND m.code IN ('GSS','ACP','SUS','TRN','MSN','SPC');

COMMIT;

-- =====================================================================
-- VERIFY
-- =====================================================================
SELECT o.code AS org_node, o.name, m.code AS market, count(*) AS pursuits,
       sum(p.planned_total_award_value) AS value
  FROM pursuit p
  JOIN org_node o ON o.id = p.org_node_id
  JOIN market m ON m.id = p.market_id
  JOIN client c ON c.id = p.client_id
 WHERE c.code = 'AERO'
 GROUP BY o.code, o.name, m.code
 ORDER BY o.code, m.code;

-- Sanity check: every pursuit should now have landed somewhere. Any row
-- here means a market code didn't match the CASE above -- investigate
-- before trusting the reassignment.
SELECT p.external_opportunity_id, p.name, m.code AS unmapped_market
  FROM pursuit p
  JOIN client c ON c.id = p.client_id
  JOIN market m ON m.id = p.market_id
 WHERE c.code = 'AERO' AND p.org_node_id IS NULL;
