-- =====================================================================
-- 11_assessment_type.sql -- Black Hat and PTW assessments
--
-- Goes in ddl/.
--
-- WHAT THIS CORRECTS: pwin_assessment assumed every assessment came from
-- the questionnaire. It does not. Source: BH_PTW_Form.frm.
--
--   Pre-BH      Pwin computed by the engine from the questionnaire.
--               Accuracy about +/-11%.
--   Post-BH     Analyst enters the Pwin from the Black Hat analysis, and
--               picks a price aggressiveness (P1). Fee is COMPUTED as
--               CFeeConfig.GetFee(contract_type) + P1 clientPrice delta.
--   Post-PTW    Analyst enters the Pwin, the margin and the bid price
--               directly. Fee is NOT computed -- it replaces the formula.
--               Accuracy about +/-1%.
--
-- So the phase is not a label on a pursuit. It records WHERE THE NUMBER
-- CAME FROM, which is the whole basis of the accuracy claim.
--
-- THREE THINGS TO CARRY INTO THE API, all from the VBA:
--   1. The analyst-entered value writes to BASE Pwin, not Pwin. The final
--      value is still derived, including any dependency blend.
--   2. Black Hat fee needs a scoring-table lookup, so it MUST be an engine
--      call. It cannot be computed in the browser without shipping the P1
--      deltas, which is exactly the boundary we hold everywhere else.
--   3. A BH/PTW assessment requires an existing questionnaire assessment.
--      The form refuses to open without one.
-- =====================================================================

BEGIN;

ALTER TABLE pwin_assessment
    ADD COLUMN IF NOT EXISTS assessment_type TEXT NOT NULL DEFAULT 'QUESTIONNAIRE',
    ADD COLUMN IF NOT EXISTS completed_date DATE,
    ADD COLUMN IF NOT EXISTS margin_rate rate_frac,
    ADD COLUMN IF NOT EXISTS bid_price money_amt,
    ADD COLUMN IF NOT EXISTS investment money_amt,
    ADD COLUMN IF NOT EXISTS aggressiveness_option_id UUID
        REFERENCES question_option(id);

ALTER TABLE pwin_assessment
    DROP CONSTRAINT IF EXISTS ck_assessment_type;
ALTER TABLE pwin_assessment
    ADD CONSTRAINT ck_assessment_type
    CHECK (assessment_type IN ('QUESTIONNAIRE', 'BLACK_HAT', 'PTW'));

-- The questionnaire version only means something for a questionnaire.
ALTER TABLE pwin_assessment
    ALTER COLUMN questionnaire_version_id DROP NOT NULL;

COMMENT ON COLUMN pwin_assessment.assessment_type IS
    'Where the Pwin came from. QUESTIONNAIRE = engine-computed from answers. '
    'BLACK_HAT / PTW = analyst-entered from a competitive analysis. This is '
    'what distinguishes a +/-11% number from a +/-1% one -- do not treat the '
    'three as interchangeable in any rollup that quotes accuracy.';

COMMENT ON COLUMN pwin_assessment.bid_price IS
    'PTW bid price. NOTE: the VBA form validates this field but never writes '
    'it -- an analyst enters a bid price and it is discarded. Being fixed '
    'separately in the workbook. The web version must write it.';

COMMENT ON COLUMN pwin_assessment.margin_rate IS
    'PTW only. Analyst-entered, capped at 30% by the form. Replaces the AOP '
    'fee formula. Black Hat instead COMPUTES fee from contract type plus the '
    'P1 aggressiveness delta, which requires the engine.';

COMMENT ON COLUMN pwin_assessment.aggressiveness_option_id IS
    'Black Hat only. The P1 price-aggressiveness option. Its scoring delta '
    'is engine-side; only the choice is stored here.';


-- ---------------------------------------------------------------------
-- Shape rules per type. A QUESTIONNAIRE assessment must name its version;
-- BH and PTW must not, because there are no answers behind them.
-- ---------------------------------------------------------------------
ALTER TABLE pwin_assessment DROP CONSTRAINT IF EXISTS ck_assessment_shape;
ALTER TABLE pwin_assessment ADD CONSTRAINT ck_assessment_shape CHECK (
    (assessment_type = 'QUESTIONNAIRE' AND questionnaire_version_id IS NOT NULL)
 OR (assessment_type IN ('BLACK_HAT', 'PTW'))
);

-- PTW carries a margin and a bid price; Black Hat carries an aggressiveness.
-- Enforced in the application rather than as a CHECK, because a partially
-- entered assessment should be correctable, not rejected outright.


-- ---------------------------------------------------------------------
-- Pipeline stage and assessment type must agree. A pursuit sitting at
-- Post-PTW whose current assessment is a questionnaire is telling the
-- dashboard it has +/-1% precision that it does not have.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_expected_assessment_type(p_stage TEXT)
RETURNS TEXT AS $$
    SELECT CASE p_stage
             WHEN 'PRE_BH'   THEN 'QUESTIONNAIRE'
             WHEN 'POST_BH'  THEN 'BLACK_HAT'
             WHEN 'POST_PTW' THEN 'PTW'
           END;
$$ LANGUAGE sql IMMUTABLE;


CREATE INDEX IF NOT EXISTS ix_pwa_type
    ON pwin_assessment(pursuit_id, assessment_type) WHERE is_current;

-- Existing rows all came from the workbook's questionnaire columns, so the
-- default is correct for them. Where a pursuit is already past Pre-BH, the
-- workbook's BHPTWComplete flag is the evidence -- but the underlying
-- assessment_type cannot be recovered retroactively, so it stays
-- QUESTIONNAIRE and the integrity check reports the mismatch rather than
-- guessing.

COMMIT;

-- =====================================================================
-- VERIFY
--   SELECT assessment_type, count(*) FROM pwin_assessment GROUP BY 1;
--
--   SELECT ps.code AS stage, a.assessment_type, count(*)
--     FROM pursuit p
--     JOIN pipeline_stage ps ON ps.id = p.pipeline_stage_id
--     JOIN pwin_assessment a ON a.pursuit_id = p.id AND a.is_current
--    GROUP BY 1,2 ORDER BY 1,2;
-- =====================================================================
