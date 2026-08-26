-- =====================================================================
-- 03_seed.sql  --  Reference data
--
-- SOURCE: modDropdowns.bas ('Single source of truth for all form
-- combo/list options'), modStaffing.bas, PwinForm.frm.
-- Extracted verbatim from CDA_Pipeline_v2_15_Engine_v0_23 (cloud).
--
-- engine_value columns are EXACT strings the engine expects today.
-- Do not tidy them. See SEED-NOTE-1 re: TM4 trailing space.
-- =====================================================================

-- ---------- roles ----------
INSERT INTO role (code, name, description) VALUES ('admin','Administrator','Full access within client scope');
INSERT INTO role (code, name, description) VALUES ('executive','Executive','Read + rollup across assigned org scope');
INSERT INTO role (code, name, description) VALUES ('capture_manager','Capture Manager','Create/edit pursuits within scope');
INSERT INTO role (code, name, description) VALUES ('read_only','Read Only','View only');

-- ---------- staffing phases (modStaffing PH_* constants) ----------
INSERT INTO phase (code, label, sequence_no) VALUES ('STRAT','Strategy',1);
INSERT INTO phase (code, label, sequence_no) VALUES ('SOL','Solutioning',2);
INSERT INTO phase (code, label, sequence_no) VALUES ('PREPROP','Pre-Proposal',3);
INSERT INTO phase (code, label, sequence_no) VALUES ('FINAL','Final Proposal',4);
INSERT INTO phase (code, label, sequence_no) VALUES ('EN','EN Response',5);
-- NOTE: engine/VBA internal names: STRAT=Strategy, SOL=Solutioning, PREPROP=PreProposal, FINAL=FinalProposal, EN=ENResponse

-- ---------- pipeline stages (modDropdowns.PhaseOptions) ----------
INSERT INTO pipeline_stage (code, label, sequence_no) VALUES ('PRE_BH','Pre-BH',1);
INSERT INTO pipeline_stage (code, label, sequence_no) VALUES ('POST_BH','Post-BH',2);
INSERT INTO pipeline_stage (code, label, sequence_no) VALUES ('POST_PTW','Post-PTW',3);

-- ---------- contract types (modDropdowns.ContractTypes) ----------
INSERT INTO contract_type (code, label, engine_value, display_order) VALUES ('COST_PLUS','Cost Plus','Cost Plus',1);
INSERT INTO contract_type (code, label, engine_value, display_order) VALUES ('T_AND_M','Time & Materials','Time & Materials',2);
INSERT INTO contract_type (code, label, engine_value, display_order) VALUES ('FIXED_PRICE','Fixed Price','Fixed Price',3);

-- ---------- opportunity types (modDropdowns.PursuitTypes) ----------
-- type_group drives TM1a/TM1b variant selection (IsDevOrExistingProduct).
INSERT INTO opportunity_type (code, label, engine_value, type_group, display_order) VALUES ('EXIST_PROD','Existing product solution, little modification required','Existing product solution, little modification required','PRODUCT',1);
INSERT INTO opportunity_type (code, label, engine_value, type_group, display_order) VALUES ('DEV_NEW','Developmental/New Product','Developmental/New Product','PRODUCT',2);
INSERT INTO opportunity_type (code, label, engine_value, type_group, display_order) VALUES ('ENG_TECH_SVC','Engineering/Technical Services','Engineering/Technical Services','SERVICES',3);
INSERT INTO opportunity_type (code, label, engine_value, type_group, display_order) VALUES ('SUSTAIN_OM','Sustainment/O&M','Sustainment/O&M','SERVICES',4);

-- ---------- labor categories (modStaffing catNames/catShort) ----------
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('CM','CM','core',1);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('TECHLEAD','Tech Lead','core',2);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('BDGEN','BD Generalist','core',3);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('PROPMGR','Proposal Mgr','core',4);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('VOLLEADS','Volume Leads','core',5);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('WRITERS','Writers/Editors','core',6);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('SMEENG','SMEs (Engineering)','sme',7);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('SMEOPS','SMEs (Ops)','sme',8);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('SMEPROD','SMEs (Production)','sme',9);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('MATLMGR','Mat''l/Subcontract Mgr','core',10);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('PRICELEAD','Pricing Lead','core',11);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('PRICING','Pricing','core',12);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('GRAPHICS','Graphics/Production','core',13);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('COMPLIANCE','Compliance','core',14);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('REVBLUE','Reviewers (Blue Team)','review',15);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('REVPINK','Reviewers (Pink Team)','review',16);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('REVRED','Reviewers (Red Team)','review',17);
INSERT INTO labor_category (code, label, category_group, display_order) VALUES ('REVGOLD','Reviewers (Gold Team)','review',18);

-- ---------- questionnaire v1 ----------
-- Section grouping matches PwinForm layout. PP1 and P1 both number from 1
-- because they open new sections (Past Performance, Price).
ALTER TABLE question ADD COLUMN IF NOT EXISTS section TEXT;

INSERT INTO questionnaire_version (code, version_no, engine_version, effective_from, is_active, notes)
VALUES ('pwin', 1, '0.23', DATE '2026-01-01', TRUE,
        'Extracted from workbook v2.15 / engine v0.23. Option engine_value
         strings must match modDropdowns.bas verbatim.');

INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'TM1A', 1, '(varies by opportunity type -- see question_prompt_variant)', 'single_select', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;
INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'TM1B', 2, '(varies by opportunity type -- see question_prompt_variant)', 'single_select', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;
INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'TM2', 3, '2.  Is there an incumbent?', 'single_select', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;
INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'TM3', 4, '3.  Is the incumbent well-performing?', 'single_select', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;
INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'TM4', 5, '4.  Will we need a teammate in order to bid key aspects of the job?', 'single_select', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;
INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'TM5', 6, '5.  Do we plan to invest (other than B&P) to increase competitiveness prior to RFP release?', 'single_select', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;
INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'INVEST_PCT', 7, 'Investment percentage (fraction of award value)', 'numeric', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;
INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'PP1', 8, '1.  Do we have any performance issues on similar contracts within the last 3 years?', 'single_select', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;
INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'P1', 9, '1.  How far above/below a normal bid are we planning for this proposal?', 'single_select', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;
INSERT INTO question (questionnaire_version_id, code, display_order, prompt_text, answer_type, is_required)
SELECT id, 'P2', 10, '2.  Is this Best Value or LPTA?', 'single_select', TRUE FROM questionnaire_version WHERE code='pwin' AND version_no=1;


-- section assignment
UPDATE question SET section='Technical & Management' WHERE code='TM1A';
UPDATE question SET section='Technical & Management' WHERE code='TM1B';
UPDATE question SET section='Technical & Management' WHERE code='TM2';
UPDATE question SET section='Technical & Management' WHERE code='TM3';
UPDATE question SET section='Technical & Management' WHERE code='TM4';
UPDATE question SET section='Technical & Management' WHERE code='TM5';
UPDATE question SET section='Technical & Management' WHERE code='INVEST_PCT';
UPDATE question SET section='Past Performance' WHERE code='PP1';
UPDATE question SET section='Price' WHERE code='P1';
UPDATE question SET section='Price' WHERE code='P2';

-- variant prompt text (TM1A / TM1B only)
INSERT INTO question_prompt_variant (question_id, type_group, prompt_text)
SELECT q.id, 'PRODUCT', '1a.  Does our product perform better than our competitor?' FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1A';
INSERT INTO question_prompt_variant (question_id, type_group, prompt_text)
SELECT q.id, 'SERVICES', '1a.  Have we done a job like this before?' FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1A';
INSERT INTO question_prompt_variant (question_id, type_group, prompt_text)
SELECT q.id, 'PRODUCT', '1b.  Is our Technical Solution more mature than competitors?' FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1B';
INSERT INTO question_prompt_variant (question_id, type_group, prompt_text)
SELECT q.id, 'SERVICES', '1b.  Have our competitors done a job like this before?' FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1B';

-- ---------- question options ----------
-- TM1A
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'SAME', 'Same', 'Same', 1, 'PRODUCT'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1A';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'BETTER', 'Better', 'Better', 2, 'PRODUCT'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1A';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'WORSE', 'Worse', 'Worse', 3, 'PRODUCT'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1A';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'ON_CONTRACT_TODAY', 'On contract today', 'On contract today', 1, 'SERVICES'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1A';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'YES_FEWER_BLOCKS', 'Yes, but not as many building blocks as competitor', 'Yes, but not as many building blocks as competitor', 2, 'SERVICES'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1A';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'NO_TEAMMATES_ON_CONTRACT', 'No, but our teammates are on contract today', 'No, but our teammates are on contract today', 3, 'SERVICES'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1A';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'NO', 'No', 'No', 4, 'SERVICES'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1A';

-- TM1B
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'SAME_LEVEL', 'Same Level', 'Same Level', 1, 'PRODUCT'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1B';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'MORE_MATURE', 'More Mature', 'More Mature', 2, 'PRODUCT'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1B';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'LESS_MATURE', 'Less Mature', 'Less Mature', 3, 'PRODUCT'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1B';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'ON_CONTRACT_TODAY', 'On contract today', 'On contract today', 1, 'SERVICES'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1B';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'YES_FEWER_BLOCKS_THAN_US', 'Yes, but not as many building blocks as us', 'Yes, but not as many building blocks as us', 2, 'SERVICES'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1B';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'NO', 'No', 'No', 3, 'SERVICES'
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM1B';

-- TM2
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'YES_US', 'Yes, us', 'Yes, us', 1, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM2';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'YES_COMPETITOR', 'Yes, one of the competitors', 'Yes, one of the competitors', 2, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM2';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'NO', 'No', 'No', 3, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM2';

-- TM3
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'WE_SATISFACTORY', 'We are performing satisfactorily/unknown', 'We are performing satisfactorily/unknown', 1, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM3';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'WE_ISSUES', 'We have performance issues', 'We have performance issues', 2, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM3';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'NA', 'N/A', 'N/A', 3, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM3';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'INCUMBENT_SATISFACTORY', 'Incumbent competitor is performing satisfactorily/unknown', 'Incumbent competitor is performing satisfactorily/unknown', 4, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM3';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'INCUMBENT_ISSUES', 'Incumbent competitor has performance issues', 'Incumbent competitor has performance issues', 5, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM3';

-- TM4
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'YES_MOST', 'Yes, we will outsource most of the actual work requested ("noble work")', 'Yes, we will outsource most of the actual work requested ("noble work")', 1, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM4';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'YES_SOME', 'Yes, we will outsource some of the actual work requested ("noble work")', 'Yes, we will outsource some of the actual work requested ("noble work")', 2, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM4';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'NO', 'No', 'No', 3, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM4';

-- TM5
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'NO', 'No', 'No', 1, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM5';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'LOW', 'Low', 'Low', 2, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM5';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'MODERATE', 'Moderate', 'Moderate', 3, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM5';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'HIGH', 'High', 'High', 4, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='TM5';

-- PP1
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'YES', 'Yes', 'Yes', 1, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='PP1';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'NO', 'No', 'No', 2, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='PP1';

-- P1
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'ABOVE_3', '3% above normal', '3% above normal', 1, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P1';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'ABOVE_2', '2% above normal', '2% above normal', 2, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P1';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'ABOVE_1', '1% above normal', '1% above normal', 3, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P1';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'NORMAL', 'Normal Bid', 'Normal Bid', 4, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P1';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'LOWER_1', '1% lower than normal', '1% lower than normal', 5, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P1';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'LOWER_2', '2% lower than normal', '2% lower than normal', 6, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P1';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'LOWER_3', '3% lower than normal', '3% lower than normal', 7, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P1';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'LOWER_4', '4% lower than normal', '4% lower than normal', 8, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P1';

-- P2
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'BEST_VALUE', 'Best Value', 'Best Value', 1, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P2';
INSERT INTO question_option (question_id, code, label_text, engine_value, display_order, applies_to_type_group)
SELECT q.id, 'LPTA', 'LPTA', 'LPTA', 2, NULL
  FROM question q JOIN questionnaire_version v ON v.id=q.questionnaire_version_id
 WHERE v.code='pwin' AND v.version_no=1 AND q.code='P2';

-- ---------- conditional logic ----------
-- P2 = LPTA disables TM1A and TM1B (PwinForm.frm: CB_TM1a.Enabled = Not isLPTA)
INSERT INTO question_dependency (question_id, depends_on_question_id, trigger_option_id, effect)
SELECT qt.id, qp.id, opt.id, 'DISABLE'
  FROM questionnaire_version v
  JOIN question qt  ON qt.questionnaire_version_id=v.id AND qt.code='TM1A'
  JOIN question qp  ON qp.questionnaire_version_id=v.id AND qp.code='P2'
  JOIN question_option opt ON opt.question_id=qp.id AND opt.code='LPTA'
 WHERE v.code='pwin' AND v.version_no=1;
INSERT INTO question_dependency (question_id, depends_on_question_id, trigger_option_id, effect)
SELECT qt.id, qp.id, opt.id, 'DISABLE'
  FROM questionnaire_version v
  JOIN question qt  ON qt.questionnaire_version_id=v.id AND qt.code='TM1B'
  JOIN question qp  ON qp.questionnaire_version_id=v.id AND qp.code='P2'
  JOIN question_option opt ON opt.question_id=qp.id AND opt.code='LPTA'
 WHERE v.code='pwin' AND v.version_no=1;

-- =====================================================================
-- SEED NOTES
-- SEED-NOTE-1  TM4 option YES_SOME has a TRAILING SPACE in its VBA
--              string literal (modDropdowns.bas). Deliberately REMOVED
--              here per decision 2026-08-17. If the engine ever
--              string-matches this option and fails, the trailing space
--              is the first thing to check.
-- SEED-NOTE-2  RESOLVED 2026-08-17. Question prompt_text is now the
--              verbatim PwinForm control caption, recovered from the
--              vbaProject.bin form stream. TM1A/TM1B variant prompts are
--              in question_prompt_variant. Do not reword without
--              creating a new questionnaire_version.
-- SEED-NOTE-3  INVEST_PCT is a numeric answer (confirmed 2026-08-17).
--              Stored as a fraction, 0..1. VBA derives it via
--              modAOP.InvestmentPercent(); the web app accepts it as a
--              numeric input.
-- SEED-NOTE-4  Market, Bidders, Contract Type and Fee live on `pursuit`,
--              not in the questionnaire, though the Pwin sheet shows
--              them as columns. They are pursuit attributes the engine
--              consumes alongside the answers.
-- SEED-NOTE-5  No markets seeded. Markets are CDA-provisioned per client
--              at onboarding.
-- =====================================================================
