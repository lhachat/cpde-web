-- =====================================================================
-- 04_schema_patch_scenario.sql
--
-- WHY: 'Pursuits Pwins Dependent' is NOT a duplicate of 'Pursuits Pwins'.
--      It is a SECOND, INDEPENDENT questionnaire assessment of the same
--      pursuit, answered under the scenario "the pursuit we depend on is
--      won." Verified against workbook v2.15:
--
--        UID 37 (Opp 53): TM2 main='Yes, us'  dep='No'
--                         Fee  main=0.11      dep=0.08
--                         Tech main=87.5      dep=85
--        UID 36 (Opp 36): base_pwin=0.4645
--                         dependent-conditional=0.718975
--                         final blended Pwin=0.506518912
--
--      The original schema's "one current assessment per pursuit" unique
--      index cannot represent this. Corrected here.
-- =====================================================================

ALTER TABLE pwin_assessment
    ADD COLUMN scenario TEXT NOT NULL DEFAULT 'BASE'
    CHECK (scenario IN ('BASE','DEPENDENT_WON'));

COMMENT ON COLUMN pwin_assessment.scenario IS
    'BASE           = standalone assessment (Pursuits Pwins sheet). '
    'DEPENDENT_WON  = assessment assuming pursuit.depends_on_pursuit_id '
    '                 is won (Pursuits Pwins Dependent sheet). '
    'Only pursuits with a dependency have a DEPENDENT_WON row.';

-- Replace the old one-current-per-pursuit constraint.
DROP INDEX IF EXISTS uq_pwin_current;
CREATE UNIQUE INDEX uq_pwin_current
    ON pwin_assessment(pursuit_id, scenario)
    WHERE is_current;

-- The blended/final Pwin the engine produces from BASE + DEPENDENT_WON.
-- Lives on the BASE row; NULL when the pursuit has no dependency.
ALTER TABLE pwin_assessment
    ADD COLUMN blended_pwin pct_prob;

COMMENT ON COLUMN pwin_assessment.blended_pwin IS
    'Engine output combining BASE and DEPENDENT_WON weighted by the '
    'depended-on pursuit''s own Pwin. Recorded on the BASE row. NULL for '
    'pursuits with no dependency -- in that case pwin IS the final value.';

-- A DEPENDENT_WON assessment only makes sense if the pursuit has a
-- dependency. Enforced at application level rather than by constraint,
-- because depends_on_pursuit_id can be cleared after the fact.
