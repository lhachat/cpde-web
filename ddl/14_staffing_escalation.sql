-- =====================================================================
-- 14_staffing_escalation.sql -- labor_category.is_static + per-client
-- escalation rate overrides
--
-- Goes in ddl/.
--
-- WHY: the same B&P dollar budget buys fewer labor hours as rates rise,
-- so FTE demand in later years should be divided by a cumulative
-- escalation factor -- but only for VARIABLE labor categories. Five
-- categories are STATIC (their own cost basis does not inflate the same
-- way): CM, Tech Lead, Proposal Mgr, Volume Leads, Pricing Lead.
--
-- is_static values below are PORTED, not decided from category names --
-- read directly from cda_engine/models/staffing/staffing_config.py's
-- LABOR_CATEGORIES (LaborCategory.is_static per entry). The generic
-- escalation rate table (ESCALATION_BASE_YEAR, GENERIC_ESCALATION_RATES)
-- is ported as a Python constant in api/app/staffing_escalation.py, not
-- duplicated here -- it changes with the engine, not with tenant data.
--
-- client_escalation_rate lets one tenant override the generic table for
-- a specific calendar year, mirroring
-- cda_engine.staffing_escalation.resolve_escalation_rate's priority:
-- an exact-year client rate wins for that year only; every other year
-- falls back to the generic table. No write endpoint ships with this
-- migration -- setting a client's override rate is an operational
-- action (direct INSERT) until a client asks for a self-service one,
-- same posture as set_engine_identity.sql today.
-- =====================================================================

BEGIN;

ALTER TABLE labor_category
    ADD COLUMN IF NOT EXISTS is_static BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN labor_category.is_static IS
    'Ported from cda_engine LaborCategory.is_static (staffing_config.py) '
    '-- not guessed from the category name. Static categories are exempt '
    'from escalation; variable categories have their FTE divided by the '
    'cumulative escalation factor for the calendar year the work lands in.';

UPDATE labor_category SET is_static = TRUE
 WHERE code IN ('CM','TECHLEAD','PROPMGR','VOLLEADS','PRICELEAD');
UPDATE labor_category SET is_static = FALSE
 WHERE code NOT IN ('CM','TECHLEAD','PROPMGR','VOLLEADS','PRICELEAD');


CREATE TABLE IF NOT EXISTS client_escalation_rate (
    client_id       UUID NOT NULL REFERENCES client(id) ON DELETE CASCADE,
    calendar_year   INT NOT NULL,
    rate            NUMERIC(9,6) NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (client_id, calendar_year)
);

COMMENT ON TABLE client_escalation_rate IS
    'Per-tenant override of the generic escalation rate for one calendar '
    'year. A year with no row here uses the generic table. Mirrors '
    'cda_engine.staffing_escalation.resolve_escalation_rate exactly -- '
    'keep the fallback logic in api/app/staffing_escalation.py in sync '
    'with that function if it ever changes upstream.';

ALTER TABLE client_escalation_rate ENABLE ROW LEVEL SECURITY;
ALTER TABLE client_escalation_rate FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON client_escalation_rate;
CREATE POLICY tenant_isolation ON client_escalation_rate
    USING (client_id = current_tenant())
    WITH CHECK (client_id = current_tenant());

GRANT SELECT, INSERT, UPDATE, DELETE ON client_escalation_rate TO cpde_app;

-- Deliberately NOT audited via fn_audit -- it is operational configuration,
-- not pursuit data; changed_fields on a rate table adds noise, not signal.

COMMIT;

-- =====================================================================
-- VERIFY
--   SELECT code, label, is_static FROM labor_category ORDER BY display_order;
--   -- expect exactly 5 TRUE: CM, Tech Lead, Proposal Mgr, Volume Leads,
--   -- Pricing Lead -- and 13 FALSE.
-- =====================================================================
