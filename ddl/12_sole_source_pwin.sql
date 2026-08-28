-- =====================================================================
-- 12_sole_source_pwin.sql -- Persist the sole-source 95% Pwin for real
--
-- Goes in ddl/.
--
-- WHY: sole source Pwin was a DISPLAY override only (effectivePwin() in
-- the browser) -- the stored value never changed, so the table and the
-- detail view could show different numbers for the same pursuit, and
-- nothing else that reads Pwin from the database (a report, an export,
-- the API directly) ever saw 95%. That is now a real, persisted
-- pwin_assessment row.
--
-- is_sole_source_pwin marks WHY the number is what it is: business rule,
-- not the questionnaire or the engine. That is what lets the UI warn
-- correctly when sole source is later unchecked -- the flag says whether
-- the currently-stored Pwin is still trustworthy for a competitive
-- pursuit, which a raw pwin value alone cannot tell you.
-- =====================================================================

BEGIN;

ALTER TABLE pwin_assessment
    ADD COLUMN IF NOT EXISTS is_sole_source_pwin BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN pwin_assessment.is_sole_source_pwin IS
    'TRUE when this Pwin came from the sole-source business rule (95%, the '
    'residual being the customer not awarding at all) rather than the '
    'questionnaire or an engine calculation. If a pursuit stops being sole '
    'source, a row carrying this flag is STALE -- it no longer reflects a '
    'competitive assessment and must be recalculated before it can be '
    'trusted for that pursuit.';

CREATE INDEX IF NOT EXISTS ix_pwa_sole_stale
    ON pwin_assessment(pursuit_id) WHERE is_sole_source_pwin AND is_current;

COMMIT;

-- Verify:
--   SELECT p.external_opportunity_id, p.is_sole_source, a.pwin,
--          a.is_sole_source_pwin
--     FROM pursuit p JOIN pwin_assessment a ON a.pursuit_id=p.id
--    WHERE a.is_current AND a.scenario='BASE' AND a.is_sole_source_pwin;
