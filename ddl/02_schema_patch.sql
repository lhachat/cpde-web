-- =====================================================================
-- 02_schema_patch.sql
-- Adds questionnaire VARIANT support.
--
-- WHY: modDropdowns.bas + PwinForm.frm show TM1a and TM1b have two
--      different option sets AND two different prompt texts, selected by
--      modAOP.IsDevOrExistingProduct(). The original schema assumed one
--      fixed option set per question. It does not.
-- =====================================================================

-- Which variant family an opportunity type belongs to.
-- Drives TM1a/TM1b prompt + option selection.
ALTER TABLE opportunity_type
    ADD COLUMN type_group TEXT
    CHECK (type_group IN ('PRODUCT','SERVICES'));

COMMENT ON COLUMN opportunity_type.type_group IS
    'PRODUCT = VBA IsDevOrExistingProduct() TRUE. SERVICES = FALSE. '
    'Selects which TM1a/TM1b prompt + option set is presented.';


-- Variant-specific prompt text. Absent row = use question.prompt_text.
CREATE TABLE question_prompt_variant (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    question_id     UUID NOT NULL REFERENCES question(id) ON DELETE CASCADE,
    type_group      TEXT NOT NULL CHECK (type_group IN ('PRODUCT','SERVICES')),
    prompt_text     TEXT NOT NULL,
    help_text       TEXT,
    CONSTRAINT uq_question_prompt_variant UNIQUE (question_id, type_group)
);


-- NULL = option applies to every variant. Non-null = variant-specific.
ALTER TABLE question_option
    ADD COLUMN applies_to_type_group TEXT
    CHECK (applies_to_type_group IN ('PRODUCT','SERVICES'));

COMMENT ON COLUMN question_option.applies_to_type_group IS
    'NULL = applies to all opportunity types. Non-null = only shown when '
    'the pursuit''s opportunity_type.type_group matches.';

-- Existing unique (question_id, code) still holds: TM1A''s SERVICES set and
-- PRODUCT set use disjoint codes, so no collision. Verify before adding
-- any new option that reuses a code across variants.


-- Conditional disable: P2 = LPTA disables TM1A and TM1B in PwinForm.
-- Modeled generically rather than hardcoding LPTA in application code.
CREATE TABLE question_dependency (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    question_id             UUID NOT NULL REFERENCES question(id) ON DELETE CASCADE,
    depends_on_question_id  UUID NOT NULL REFERENCES question(id) ON DELETE CASCADE,
    trigger_option_id       UUID NOT NULL REFERENCES question_option(id) ON DELETE CASCADE,
    effect                  TEXT NOT NULL CHECK (effect IN ('DISABLE','HIDE','REQUIRE')),
    CONSTRAINT uq_question_dependency
        UNIQUE (question_id, depends_on_question_id, trigger_option_id),
    CONSTRAINT ck_qd_not_self CHECK (question_id <> depends_on_question_id)
);

COMMENT ON TABLE question_dependency IS
    'Cross-question conditional logic. Currently one known rule: '
    'P2 = LPTA disables TM1A and TM1B. Source: PwinForm.frm '
    '(CB_TM1a.Enabled = Not isLPTA).';
