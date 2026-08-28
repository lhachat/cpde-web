-- =====================================================================
-- 13_bhptw_fee.sql -- Fee inputs for the Black Hat form
--
-- Goes in ddl/.
--
-- WHY: Black Hat fee = get_fee(contract_type) + P1 aggressiveness delta
-- (see 11_assessment_type.sql). Confirmed against the VBA
-- (CPwinScoringTables.cls / CFeeConfig / PwinForm.CallPwinEngine_) that
-- this is NOT protected IP -- it is computed client-side in the workbook
-- today and is fine to compute here too, in the FastAPI layer. Only the
-- tournament solve behind /v1/run is the protected asset.
--
-- Both rate tables are small and were already visible in the shipped
-- workbook. The P1 side is safe to seed directly: the delta IS the
-- percentage already printed in the option label ("3% above normal" =
-- +0.03). The contract-type side is NOT derivable from its label
-- ("Fixed Price" does not say a number) -- these rates are confirmed
-- against fee_config.py in cda-engine and cross-checked against every
-- Post-BH pursuit in the loaded AERO data, zero exceptions.
-- =====================================================================

BEGIN;

ALTER TABLE contract_type
    ADD COLUMN IF NOT EXISTS base_fee_rate rate_frac;

COMMENT ON COLUMN contract_type.base_fee_rate IS
    'Nominal fee rate for this contract type (CFeeConfig.GetFee() in the '
    'VBA; fee_config.py in cda-engine). Black Hat fee = base_fee_rate + '
    'the chosen P1 option''s price_delta. The /blackhat endpoint refuses '
    'to compute a fee for any contract type where this is NULL, rather '
    'than guess. Not protected IP; see the note at the top of this file.';

ALTER TABLE question_option
    ADD COLUMN IF NOT EXISTS price_delta rate_frac;

COMMENT ON COLUMN question_option.price_delta IS
    'Black Hat fee delta for a P1 (price aggressiveness) option, e.g. '
    '''3% above normal'' = +0.03. Only meaningful for the P1 question; '
    'NULL everywhere else. Not protected IP -- the delta is literally the '
    'percentage already printed in the option label.';

-- Safe to seed directly: the value is the label, not a lookup into any
-- scoring table.
UPDATE question_option o
   SET price_delta = CASE o.code
         WHEN 'ABOVE_3' THEN  0.03
         WHEN 'ABOVE_2' THEN  0.02
         WHEN 'ABOVE_1' THEN  0.01
         WHEN 'NORMAL'  THEN  0.00
         WHEN 'LOWER_1' THEN -0.01
         WHEN 'LOWER_2' THEN -0.02
         WHEN 'LOWER_3' THEN -0.03
         WHEN 'LOWER_4' THEN -0.04
       END
  FROM question q
 WHERE o.question_id = q.id AND q.code = 'P1';

-- Real rates, confirmed against fee_config.py in cda-engine.
UPDATE contract_type SET base_fee_rate = 0.065 WHERE code = 'COST_PLUS';
UPDATE contract_type SET base_fee_rate = 0.08  WHERE code = 'T_AND_M';
UPDATE contract_type SET base_fee_rate = 0.10  WHERE code = 'FIXED_PRICE';

COMMIT;

-- =====================================================================
-- VERIFY
--   SELECT code, label, base_fee_rate FROM contract_type ORDER BY code;
--   SELECT o.code, o.label_text, o.price_delta FROM question_option o
--     JOIN question q ON q.id = o.question_id WHERE q.code = 'P1'
--    ORDER BY o.display_order;
-- =====================================================================
