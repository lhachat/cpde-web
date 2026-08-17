-- =====================================================================
-- CPDE v2 -- Client-facing schema (PostgreSQL 16)
-- Competitive Data Analytics, LLC
--
-- SCOPE: This file defines the CLIENT-FACING database only.
--        market_calibration (price differentials) is DELIBERATELY ABSENT.
--        That data lives CDA-side, engine infrastructure only. See NOTE-1.
--
-- STATUS: Draft for review. Assumptions are marked ASSUMPTION-n and
--         listed at the bottom of this file. Do not treat unmarked
--         choices as validated -- they are defaults, not decisions.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()

-- ---------------------------------------------------------------------
-- Domains: consistent numeric precision, declared once.
-- ---------------------------------------------------------------------
-- Money: NUMERIC, never FLOAT. Award values run to 9-10 figures.
CREATE DOMAIN money_amt   AS NUMERIC(18,2);
-- Rates/probabilities stored as FRACTIONS (0.0715 = 7.15%), matching
-- the workbook's convention (Fee 0.025, Pwin 0.71215, Invest% 0.05).
CREATE DOMAIN rate_frac   AS NUMERIC(9,6);
CREATE DOMAIN pct_prob    AS NUMERIC(9,6) CHECK (VALUE >= 0 AND VALUE <= 1);
CREATE DOMAIN fte_amt     AS NUMERIC(7,3) CHECK (VALUE >= 0);


-- =====================================================================
-- 1. TENANCY + ORG
-- =====================================================================

CREATE TABLE client (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code            TEXT NOT NULL UNIQUE,      -- immutable; used in engine calls
    name            TEXT NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON COLUMN client.code IS
    'Immutable after creation. Engine resolves market_calibration by (client.code, market.code).';


-- Org tree. Max depth 3 enforced by trigger (see fn_org_node_depth_check).
-- Division/Product Line is OPTIONAL -- a pursuit may attach at BU or Division.
CREATE TABLE org_node (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID NOT NULL REFERENCES client(id) ON DELETE RESTRICT,
    parent_id           UUID     REFERENCES org_node(id) ON DELETE RESTRICT,
    node_type           TEXT NOT NULL
                        CHECK (node_type IN ('business','business_unit','division')),
    code                TEXT NOT NULL,
    name                TEXT NOT NULL,
    is_license_boundary BOOLEAN NOT NULL DEFAULT FALSE,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_org_node_code UNIQUE (client_id, code),
    -- Root must be a business; non-root must have a parent.
    CONSTRAINT ck_org_root CHECK (
        (parent_id IS NULL AND node_type = 'business') OR
        (parent_id IS NOT NULL AND node_type <> 'business')
    )
);
CREATE INDEX ix_org_node_parent ON org_node(parent_id);
CREATE INDEX ix_org_node_client ON org_node(client_id);

COMMENT ON COLUMN org_node.is_license_boundary IS
    'Marks the business_unit level. FLAG ONLY -- no enforcement logic. '
    'Licensing is deliberately NOT wired into the access path. See NOTE-2.';


-- Enforce: max depth 3, parent in same client, correct type nesting.
CREATE OR REPLACE FUNCTION fn_org_node_validate() RETURNS TRIGGER AS $$
DECLARE
    parent_type   TEXT;
    parent_client UUID;
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT node_type, client_id INTO parent_type, parent_client
      FROM org_node WHERE id = NEW.parent_id;

    IF parent_client <> NEW.client_id THEN
        RAISE EXCEPTION 'org_node % parent belongs to a different client', NEW.code;
    END IF;

    IF NOT ( (NEW.node_type = 'business_unit' AND parent_type = 'business')
          OR (NEW.node_type = 'division'      AND parent_type = 'business_unit') ) THEN
        RAISE EXCEPTION 'invalid org nesting: % under %', NEW.node_type, parent_type;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_org_node_validate
    BEFORE INSERT OR UPDATE ON org_node
    FOR EACH ROW EXECUTE FUNCTION fn_org_node_validate();


-- =====================================================================
-- 2. USERS, ROLES, ACCESS SCOPE
-- =====================================================================

CREATE TABLE app_user (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID NOT NULL REFERENCES client(id) ON DELETE RESTRICT,
    email           TEXT NOT NULL,
    display_name    TEXT NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_app_user_email UNIQUE (client_id, email)
);
-- NOTE: no password/credential columns. ASSUMPTION-1: auth is external
-- (SSO/IdP). Do not add password hashes here without revisiting.

CREATE TABLE role (
    id              SMALLSERIAL PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,   -- 'capture_manager','executive','admin','read_only'
    name            TEXT NOT NULL,
    description     TEXT
);

-- Effective access = assigned node + ALL DESCENDANTS (inherited downward).
CREATE TABLE user_scope_assignment (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    org_node_id     UUID NOT NULL REFERENCES org_node(id) ON DELETE CASCADE,
    role_id         SMALLINT NOT NULL REFERENCES role(id),
    granted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    granted_by      UUID REFERENCES app_user(id),
    CONSTRAINT uq_user_scope UNIQUE (user_id, org_node_id, role_id)
);
CREATE INDEX ix_user_scope_user ON user_scope_assignment(user_id);

-- Access predicate helper. Apply BEFORE any user-supplied filter.
-- Filtering "to specific units below me" is a separate, additive WHERE clause.
CREATE OR REPLACE FUNCTION fn_user_visible_org_nodes(p_user_id UUID)
RETURNS TABLE (org_node_id UUID) AS $$
    WITH RECURSIVE assigned AS (
        SELECT o.id, o.parent_id
          FROM org_node o
          JOIN user_scope_assignment usa ON usa.org_node_id = o.id
         WHERE usa.user_id = p_user_id
           AND o.is_active
        UNION ALL
        SELECT c.id, c.parent_id
          FROM org_node c
          JOIN assigned a ON c.parent_id = a.id
         WHERE c.is_active
    )
    SELECT DISTINCT id FROM assigned;
$$ LANGUAGE sql STABLE;


-- =====================================================================
-- 3. REFERENCE DATA
-- =====================================================================

-- Markets: CDA-PROVISIONED. Client-level (shared across all org nodes).
-- price_differential is ABSENT BY DESIGN -- see NOTE-1.
CREATE TABLE market (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID NOT NULL REFERENCES client(id) ON DELETE RESTRICT,
    code            TEXT NOT NULL,          -- IMMUTABLE after creation
    name            TEXT NOT NULL,          -- editable
    display_order   INT  NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_market_code UNIQUE (client_id, code)
);

-- Enforce code immutability: renaming a market code silently breaks the
-- engine's calibration lookup. Name is freely editable.
CREATE OR REPLACE FUNCTION fn_market_code_immutable() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'market.code is immutable (attempted % -> %)', OLD.code, NEW.code;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_market_code_immutable
    BEFORE UPDATE ON market
    FOR EACH ROW EXECUTE FUNCTION fn_market_code_immutable();


-- Lookup tables. `code` is the engine contract; `label` is display-only.
CREATE TABLE contract_type (
    id              SMALLSERIAL PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,   -- 'COST_PLUS','FFP','T_AND_M',...
    label           TEXT NOT NULL,
    engine_value    TEXT NOT NULL,          -- exact string the engine expects
    display_order   INT NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE opportunity_type (
    id              SMALLSERIAL PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,
    label           TEXT NOT NULL,          -- 'Existing product solution, little modification required'
    engine_value    TEXT NOT NULL,
    display_order   INT NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

-- Capture/proposal phases. Ordered; drives staffing + phase durations.
CREATE TABLE phase (
    id              SMALLSERIAL PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,   -- 'STRAT','SOL','PREPROP','FINAL','EN'
    label           TEXT NOT NULL,
    sequence_no     INT  NOT NULL UNIQUE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

-- Pipeline/gate status (workbook 'Phase' column: 'Pre-BH', etc.)
-- ASSUMPTION-2: this is a DIFFERENT concept from `phase` above (which is a
-- staffing/proposal phase). Kept separate deliberately. Confirm.
CREATE TABLE pipeline_stage (
    id              SMALLSERIAL PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,   -- 'PRE_BH','BH','PTW',...
    label           TEXT NOT NULL,
    sequence_no     INT  NOT NULL UNIQUE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE labor_category (
    id              SMALLSERIAL PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,   -- 'CM','TECHLEAD','BDGEN','PROPMGR',...
    label           TEXT NOT NULL,
    category_group  TEXT,                   -- 'core','sme','review' (RevBlue/Pink/Red/Gold)
    display_order   INT NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);


-- =====================================================================
-- 4. QUESTIONNAIRE (versioned; stable codes; engine_value seam)
-- =====================================================================

CREATE TABLE questionnaire_version (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code                TEXT NOT NULL,          -- 'pwin'
    version_no          INT  NOT NULL,
    engine_version      TEXT,                   -- e.g. '0.23'
    effective_from      DATE NOT NULL,
    is_active           BOOLEAN NOT NULL DEFAULT FALSE,
    notes               TEXT,
    CONSTRAINT uq_qv UNIQUE (code, version_no)
);
-- Only one active version per questionnaire code.
CREATE UNIQUE INDEX uq_qv_active ON questionnaire_version(code)
    WHERE is_active;

CREATE TABLE question (
    id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    questionnaire_version_id  UUID NOT NULL REFERENCES questionnaire_version(id) ON DELETE CASCADE,
    code                      TEXT NOT NULL,    -- 'TM1A','TM1B','TM2','PP1','P1','P2','INVEST_PCT'
    display_order             INT  NOT NULL,
    prompt_text               TEXT NOT NULL,
    help_text                 TEXT,             -- future: questionnaire assistant agent target
    answer_type               TEXT NOT NULL
                              CHECK (answer_type IN ('single_select','numeric','boolean')),
    is_required               BOOLEAN NOT NULL DEFAULT TRUE,
    numeric_min               NUMERIC,
    numeric_max               NUMERIC,
    CONSTRAINT uq_question UNIQUE (questionnaire_version_id, code)
);

CREATE TABLE question_option (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    question_id     UUID NOT NULL REFERENCES question(id) ON DELETE CASCADE,
    code            TEXT NOT NULL,      -- 'SAME','SAME_LEVEL','4PCT_LOWER','BEST_VALUE'
    label_text      TEXT NOT NULL,      -- display; freely editable
    engine_value    TEXT NOT NULL,      -- EXACT string the engine expects today
    display_order   INT NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_question_option UNIQUE (question_id, code)
);
COMMENT ON COLUMN question_option.engine_value IS
    'The seam. Web app stores option codes; engine receives these strings '
    '(e.g. ''4% lower than normal''). Changing the engine contract later '
    'means updating this column only -- not every stored answer.';


-- =====================================================================
-- 5. PURSUIT (core)
-- =====================================================================

CREATE TABLE pursuit (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                   UUID NOT NULL REFERENCES client(id) ON DELETE RESTRICT,
    org_node_id                 UUID NOT NULL REFERENCES org_node(id) ON DELETE RESTRICT,

    -- Identity: surrogate PK is internal. external_opportunity_id is the
    -- CRM/SalesForce key -- DISTINCT concepts, not interchangeable.
    external_opportunity_id     TEXT,
    name                        TEXT NOT NULL,

    market_id                   UUID     REFERENCES market(id) ON DELETE RESTRICT,
    opportunity_type_id         SMALLINT REFERENCES opportunity_type(id),
    contract_type_id            SMALLINT REFERENCES contract_type(id),
    pipeline_stage_id           SMALLINT REFERENCES pipeline_stage(id),

    -- Dependency: replaces the separate Pwin_Dep sheet entirely.
    depends_on_pursuit_id       UUID REFERENCES pursuit(id) ON DELETE SET NULL,

    is_sole_source              BOOLEAN NOT NULL DEFAULT FALSE,
    bidders                     INT CHECK (bidders IS NULL OR bidders >= 1),
    bid_decision                TEXT CHECK (bid_decision IN ('BID','NO_BID','UNDECIDED')),

    planned_total_award_value   money_amt,
    planned_fee_rate            rate_frac,
    investment_pct              rate_frac,

    min_bp                      money_amt,
    max_bp                      money_amt,
    planned_investment          money_amt,

    bp_start_date               DATE,
    proposal_due_date           DATE,
    contract_award_date         DATE,
    period_end_date             DATE,
    stage_completed_date        DATE,
    cancel_date                 DATE,

    -- Outcome. NULL = still open.
    outcome                     TEXT CHECK (outcome IN ('WON','LOST','CANCELLED','NO_BID')),
    outcome_date                DATE,

    crm_pwin                    pct_prob,   -- 'SalesForce Pwin' -- external, informational

    black_hat_ptw_complete      BOOLEAN NOT NULL DEFAULT FALSE,

    is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID REFERENCES app_user(id),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                  UUID REFERENCES app_user(id),

    CONSTRAINT ck_pursuit_no_self_dep CHECK (depends_on_pursuit_id <> id),
    CONSTRAINT ck_pursuit_dates CHECK (
        (proposal_due_date IS NULL OR bp_start_date IS NULL OR proposal_due_date >= bp_start_date)
        AND (contract_award_date IS NULL OR proposal_due_date IS NULL
             OR contract_award_date >= proposal_due_date)
        AND (period_end_date IS NULL OR contract_award_date IS NULL
             OR period_end_date >= contract_award_date)
    )
);

-- External opportunity IDs unique per client, when present.
CREATE UNIQUE INDEX uq_pursuit_ext_opp
    ON pursuit(client_id, external_opportunity_id)
    WHERE external_opportunity_id IS NOT NULL;

CREATE INDEX ix_pursuit_org      ON pursuit(org_node_id);
CREATE INDEX ix_pursuit_market   ON pursuit(market_id);
CREATE INDEX ix_pursuit_dep      ON pursuit(depends_on_pursuit_id);
CREATE INDEX ix_pursuit_open     ON pursuit(client_id) WHERE outcome IS NULL AND is_active;

COMMENT ON COLUMN pursuit.bidders IS
    'Competitor COUNT only. Competitor identity is intentionally NOT stored '
    'client-side -- supplied to CDA during onboarding. See NOTE-3.';


-- =====================================================================
-- 6. PWIN ASSESSMENT (snapshot + answers)
-- =====================================================================

-- One row per engine run. Immutable once written -- new calc = new row.
-- This preserves the audit trail behind the accuracy claims.
CREATE TABLE pwin_assessment (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pursuit_id                  UUID NOT NULL REFERENCES pursuit(id) ON DELETE CASCADE,
    questionnaire_version_id    UUID NOT NULL REFERENCES questionnaire_version(id),

    engine_version              TEXT NOT NULL,
    calculated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    calculated_by               UUID REFERENCES app_user(id),

    -- Engine outputs
    pwin                        pct_prob,
    base_pwin                   pct_prob,       -- pre-dependency adjustment
    score_tech                  NUMERIC(8,3),
    score_mgmt                  NUMERIC(8,3),
    score_past_perf             NUMERIC(8,3),
    price_position              NUMERIC(9,6),   -- signed; e.g. -0.065
    competitor_price_position   NUMERIC(9,6),

    -- Full request/response retained for reproducibility + debugging.
    engine_request              JSONB,
    engine_response             JSONB,

    is_current                  BOOLEAN NOT NULL DEFAULT TRUE
);
-- Exactly one current assessment per pursuit.
CREATE UNIQUE INDEX uq_pwin_current ON pwin_assessment(pursuit_id)
    WHERE is_current;
CREATE INDEX ix_pwin_pursuit ON pwin_assessment(pursuit_id, calculated_at DESC);

COMMENT ON TABLE pwin_assessment IS
    'Append-only. Never UPDATE pwin values in place -- insert a new row and '
    'flip is_current. Accuracy validation depends on knowing which engine '
    'version and questionnaire version produced a given number.';


CREATE TABLE pwin_answer (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pwin_assessment_id  UUID NOT NULL REFERENCES pwin_assessment(id) ON DELETE CASCADE,
    question_id         UUID NOT NULL REFERENCES question(id),
    question_option_id  UUID     REFERENCES question_option(id),
    numeric_value       NUMERIC,
    boolean_value       BOOLEAN,
    CONSTRAINT uq_pwin_answer UNIQUE (pwin_assessment_id, question_id),
    -- Exactly one value form populated.
    CONSTRAINT ck_pwin_answer_one_value CHECK (
        (question_option_id IS NOT NULL)::int
      + (numeric_value      IS NOT NULL)::int
      + (boolean_value      IS NOT NULL)::int = 1
    )
);
CREATE INDEX ix_pwin_answer_assessment ON pwin_answer(pwin_assessment_id);


-- =====================================================================
-- 7. YEAR PROJECTIONS (replaces AOP Year1..Year5 column blocks)
-- =====================================================================

CREATE TABLE pursuit_year_projection (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pursuit_id              UUID NOT NULL REFERENCES pursuit(id) ON DELETE CASCADE,
    year_offset             INT  NOT NULL CHECK (year_offset >= 1),   -- no 5-year ceiling
    calendar_year           INT,

    billable_contract_days  NUMERIC(9,2),
    probabilistic_revenue   money_amt,
    probabilistic_fee       money_amt,
    bp_days                 NUMERIC(9,2),
    bp_required             money_amt,
    planned_investment      money_amt,

    CONSTRAINT uq_pursuit_year UNIQUE (pursuit_id, year_offset)
);
CREATE INDEX ix_pyp_pursuit ON pursuit_year_projection(pursuit_id);

COMMENT ON TABLE pursuit_year_projection IS
    'Derived from engine/AOP calculation. year_offset is relative to the '
    'planning year. Deliberately unbounded -- the workbook''s hard 5-year '
    'limit was a spreadsheet artifact, not a business rule.';


-- =====================================================================
-- 8. STAFFING (replaces 98-column StaffingData sheet)
-- =====================================================================

CREATE TABLE pursuit_phase_duration (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pursuit_id      UUID NOT NULL REFERENCES pursuit(id) ON DELETE CASCADE,
    phase_id        SMALLINT NOT NULL REFERENCES phase(id),
    weeks           NUMERIC(7,2) CHECK (weeks >= 0),
    CONSTRAINT uq_pursuit_phase UNIQUE (pursuit_id, phase_id)
);

CREATE TABLE pursuit_staffing (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pursuit_id          UUID NOT NULL REFERENCES pursuit(id) ON DELETE CASCADE,
    labor_category_id   SMALLINT NOT NULL REFERENCES labor_category(id),
    phase_id            SMALLINT NOT NULL REFERENCES phase(id),
    fte                 fte_amt NOT NULL DEFAULT 0,
    CONSTRAINT uq_pursuit_staffing UNIQUE (pursuit_id, labor_category_id, phase_id)
);
CREATE INDEX ix_staffing_pursuit ON pursuit_staffing(pursuit_id);

-- Effective B&P percentage + B&P start captured per pursuit (workbook had
-- these on StaffingData alongside the FTE grid).
CREATE TABLE pursuit_staffing_meta (
    pursuit_id          UUID PRIMARY KEY REFERENCES pursuit(id) ON DELETE CASCADE,
    effective_bp_pct    rate_frac,
    calculated_bp       money_amt,
    planned_bp_required money_amt,
    calculated_at       TIMESTAMPTZ,
    engine_version      TEXT
);


-- =====================================================================
-- 9. PLANNING TARGETS (replaces Dashboard Table5)
-- =====================================================================

CREATE TABLE plan_year (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_node_id                 UUID NOT NULL REFERENCES org_node(id) ON DELETE CASCADE,
    calendar_year               INT  NOT NULL,
    escalation_rate             rate_frac,
    revenue_target              money_amt,
    fee_target                  money_amt,
    budgeted_bp                 money_amt,
    budgeted_investment         money_amt,
    current_contract_revenue    money_amt,
    current_contract_fee        money_amt,
    CONSTRAINT uq_plan_year UNIQUE (org_node_id, calendar_year)
);

-- ASSUMPTION-3: targets are set at the org node that holds them (typically
-- BU). Rollup to Business = SUM over descendants. If targets are set at
-- Business and ALLOCATED down, this table needs an allocation concept.


-- =====================================================================
-- 10. AUDIT
-- =====================================================================

CREATE TABLE audit_log (
    id              BIGSERIAL PRIMARY KEY,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    client_id       UUID,
    user_id         UUID,
    action          TEXT NOT NULL,          -- 'INSERT','UPDATE','DELETE','LOGIN','EXPORT','ENGINE_CALL'
    table_name      TEXT,
    record_id       UUID,
    changed_fields  JSONB,
    ip_address      INET,
    user_agent      TEXT
);
CREATE INDEX ix_audit_occurred ON audit_log(occurred_at DESC);
CREATE INDEX ix_audit_record   ON audit_log(table_name, record_id);
CREATE INDEX ix_audit_user     ON audit_log(user_id, occurred_at DESC);

COMMENT ON TABLE audit_log IS
    'Required for NIST 800-171 / CMMC regardless of hosting tier. Build now; '
    'retrofitting audit trails after the fact is materially harder.';


-- =====================================================================
-- 11. DEFERRED -- placeholders NOT created. Listed so they are not forgotten.
-- =====================================================================
--   labor_rate / rate_year         -- Feature B; no source data exists today
--   win_loss_debrief + doc store   -- CUI-bearing; object storage, not blobs
--   agent_* tables                 -- optimization agent, back burner
--   license_* tables               -- commercial model under revision
--   data_classification tagging    -- add when debrief ingestion starts


-- =====================================================================
-- ASSUMPTIONS -- confirm or correct before this is treated as settled
-- =====================================================================
-- ASSUMPTION-1  Authentication is external (SSO/IdP). No credentials stored.
-- ASSUMPTION-2  Workbook 'Phase' (Pre-BH etc.) is a PIPELINE STAGE, distinct
--               from staffing phases (Strategy/Solutioning/PreProp/Final/EN).
--               Modeled as two tables. If they are the same concept, merge.
-- ASSUMPTION-3  plan_year targets are held at the node, rolled up by SUM.
-- ASSUMPTION-4  Pwin, Tech, Mgmt, PP, Price, C Price are ENGINE OUTPUTS and
--               are never user-edited. Stored as immutable snapshots.
-- ASSUMPTION-5  pursuit_year_projection values are engine-derived, not
--               user-entered. If a user can override a year's revenue,
--               this table needs an is_override flag + source column.
-- ASSUMPTION-6  A pursuit attaches to exactly one org_node (BU or Division).
--               No cross-BU shared pursuits.
-- ASSUMPTION-7  Fee is stored as a RATE (0.025). Workbook 'Planned Fee'
--               appears to be a rate; 'Probabilistic Fee' is an AMOUNT.
--               Named accordingly -- verify.
--
-- NOTE-1  market_calibration (price_differential) is CDA-side only, keyed
--         (client_code, market_code). It must never appear in this database.
-- NOTE-2  is_license_boundary is a FLAG. Licensing enforcement is
--         deliberately kept out of the access-control path.
-- NOTE-3  Competitor identity is out of scope client-side by decision.
-- =====================================================================
