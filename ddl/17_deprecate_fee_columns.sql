-- =====================================================================
-- 17_deprecate_fee_columns.sql -- deprecate the DB-seeded fee columns
--
-- Goes in ddl/.
--
-- WHY: fee.py's resolve_fee() (Black Hat + Recalculate Pwin) now reads
-- BOTH halves of the fee computation from the engine's live
-- GET /v1/scoring-tables response (fee_rates for the contract-type
-- rate, the SAME p1 table scoring.py already fetches for the P1 delta
-- -- see fee.py/scoring.py's own docstrings). That retired a real,
-- three-deep duplication of the same fee data that had accumulated
-- across this project: an old hardcoded scoring.py copy (removed in
-- the prior scoring-table migration), this file's DB-seeded copy, and
-- now the live table -- the one remaining source of truth.
--
-- contract_type.base_fee_rate and question_option.price_delta are
-- therefore no longer read by ANY application code, confirmed by
-- checking every call site directly (fee.py was the only consumer of
-- either column, and it no longer touches them).
--
-- NOT DROPPED. Same posture as every other cleanup this project has
-- flagged rather than immediately acted on (e.g. 06_plan_year.sql,
-- still carried as a Known Gap) -- dropping a column is destructive and
-- hard to reverse; deprecating it in place costs nothing and keeps the
-- historical values around in case anything (a report, an export, a
-- future audit) still wants to see what was seeded. Actually dropping
-- these is a separate, deliberate decision for later, not bundled in
-- here.
-- =====================================================================

BEGIN;

COMMENT ON COLUMN contract_type.base_fee_rate IS
    'DEPRECATED as of ddl/17_deprecate_fee_columns.sql -- no longer '
    'read by any application code. fee.py now reads the live-fetched '
    'fee_rates table instead (GET /v1/scoring-tables via scoring.py). '
    'Kept for historical reference, not dropped -- see this file''s own '
    'header note for why.';

COMMENT ON COLUMN question_option.price_delta IS
    'DEPRECATED as of ddl/17_deprecate_fee_columns.sql -- no longer '
    'read by any application code. fee.py now reads the P1 delta from '
    'the live-fetched p1 table (scoring.lookup("p1", ...), the SAME '
    'table Pwin scoring already uses -- not a separate copy). Kept for '
    'historical reference, not dropped -- see this file''s own header '
    'note for why.';

COMMIT;

-- =====================================================================
-- VERIFY
--   SELECT col_description('contract_type'::regclass::oid,
--     (SELECT attnum FROM pg_attribute WHERE attrelid='contract_type'::regclass
--       AND attname='base_fee_rate'));
--   -- expect the DEPRECATED comment above
-- =====================================================================
