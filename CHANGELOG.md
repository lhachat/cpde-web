# Changelog — cpde-web

Web version of the Competitive Pipeline Decision Engine.
Separate repository from `cda-engine`; versioned independently.

Format follows Keep a Changelog. Versions are semantic, but while the
major is 0 the schema may break between minors — say so explicitly when
it does.

---

## [0.1.0] — 2026-08-25

First tagged version. The database is real, tested and loaded with two
tenants. The front end is still a static prototype with no backend.

### Database schema

- **`ddl/01_schema.sql`** — core relational schema, 23 tables.
  - `org_node` self-referencing tree, max depth 3 (business → business unit
    → division), depth and nesting enforced by trigger. Division optional.
  - `pursuit` with self-referencing `depends_on_pursuit_id`, replacing the
    workbook's separate `Pwin_Dep` sheet.
  - `pursuit_staffing` — the 98-column `StaffingData` sheet normalized to
    `(pursuit_id, labor_category_id, phase_id, fte)`.
  - `pursuit_year_projection` — the 30 AOP Year 1–5 columns normalized.
    **No five-year ceiling**; that was a spreadsheet artifact.
  - `pwin_assessment` append-only, stamped with `engine_version` and
    `questionnaire_version_id`, retaining `engine_request` and
    `engine_response` as JSONB.
  - Surrogate UUID keys throughout, with `(client_id,
    external_opportunity_id)` unique. UID and Opportunity ID are distinct
    and not interchangeable.
- **`ddl/02_schema_patch.sql`** — questionnaire variant support.
  `question_prompt_variant` and `question_option.applies_to_type_group`
  for TM1a/TM1b, which differ entirely between PRODUCT and SERVICES
  opportunity types. `question_dependency` for cross-question rules.
- **`ddl/03_seed.sql`** — reference data extracted from `modDropdowns.bas`,
  `modStaffing.bas` and the `PwinForm` control captions. 94 inserts:
  roles, phases, pipeline stages, contract types, opportunity types, 18
  labor categories, and questionnaire v1 with verbatim prompts and options.
  `question_option.engine_value` holds the exact string the engine expects,
  so the engine contract can change without touching stored answers.
- **`ddl/04_schema_patch_scenario.sql`** — `pwin_assessment.scenario`
  (`BASE` | `DEPENDENT_WON`) plus `blended_pwin`. Discovered that
  `Pursuits Pwins Dependent` is not a duplicate of `Pursuits Pwins` but a
  second independent assessment of the same pursuit, answered as though the
  preceding pursuit was won.
- **`ddl/06_engine_identity.sql`** — `client.engine_client_code`,
  `engine_secret_ref`, `engine_base_url`. Maps a tenant to its engine
  credential. Stores a *reference* only; never a key.

### Security

- **`ddl/05_security.sql`** — multi-tenant isolation.
  - `client_id` denormalized onto child tables, derived by trigger on write
    so it cannot drift.
  - `cpde_app` role owns nothing and cannot DDL.
  - `set_tenant()` using `SET LOCAL`, so context cannot survive a
    transaction and leak across a pooled connection.
  - `current_tenant()` returns the all-zero UUID when unset — a query with
    no context matches nothing rather than everything. Fails closed.
  - `ENABLE` + **`FORCE ROW LEVEL SECURITY`** with `USING` and `WITH CHECK`
    policies on all 14 tenant-scoped tables.
  - A coverage assertion that fails the migration if any table carrying
    `client_id` lacks RLS. Catches the table someone adds later.

### Tooling

- **`migrate_workbook.py`** — loads a CPDE workbook into the schema.
  `--dry-run` validates without touching the database and refuses to load
  while any ERROR-level issue stands. Cross-sheet integrity checks,
  reference-value validation, unresolvable dependency detection.
  - Loads `plan_year` from Dashboard Table5 — **seven years, not the five
    the Dashboard grid displays**.
  - Market authority is the **Pwin sheet**, not AOP. The two disagreed on
    128 of 150 rows in the demo workbook; the Pwin sheet's value is what
    the engine actually scored against.
  - `--force-bid` loads every pursuit as Bid. Narrowing the pipeline is the
    tool's job in a demo, not the data's.
- **`gen_demo.py`** — synthetic pipeline generator. Level-loads B&P against
  budget, enforces the questionnaire cascade rules, holds market
  differentials as pinned constants so a seed change cannot silently alter
  them.
- **`test_setup.sql`** — `cpde_api` login role (`NOBYPASSRLS`), test users,
  a second business unit and a division for scope testing.
- **`test_isolation.py`** — 29 assertions across 7 groups. Aborts if the
  connecting role can bypass RLS, so it cannot pass vacuously. Tests
  fail-closed behaviour, per-tenant visibility, cross-tenant reads on all
  11 scoped tables, write isolation, transaction-scoped context, and
  privilege escalation. **29/29 passing.**

### Prototype

- **`cpde_prototype.html`** — single-file static prototype, no dependencies,
  no backend. CDA branding. Eight views: Portfolio Dashboard, Pursuits,
  Staffing Capacity, Revenue & Profit, B&P and Investment, Scenario
  Sandbox, Targets & Budgets, Import.
  - Live bid/no-bid toggles recomputing B&P, revenue and investment.
  - Pagination, seven filters, search, sortable columns.
  - Full-page two-column pursuit detail with keyboard-free stepping.
  - Questionnaire cascade rules matching `PwinForm` exactly.
  - Dependency badges resolving to opportunity name, never the internal UID.
  - Configurable dashboard: show/hide and bar↔table switching.

### Data loaded

| Tenant | Engine identity | Pursuits | Markets | Source |
|---|---|---|---|---|
| `DEMO` | `collins` | 36 | 3 | `CDA_Pipeline_v2.15_Engine_v0.23 (cloud).xlsm` |
| `AERO` | `cda-internal` | 150 | 6 | `..._Engine_v0_23__demo_.xlsm` |

### Decisions recorded

- **Multi-tenant shared database** with RLS, not database-per-tenant.
- **Commercial AWS**, not GovCloud. Commercial holds a FedRAMP Moderate
  P-ATO; only High or DoD IL4+ would force a move.
- **SSO first**, managed IdP fallback with mandatory MFA. No password
  column exists in the schema and none should be added.
- **SOC 2 Type II** as the certification target. CMMC L2 when a contract
  flows it down. FedRAMP only if CPDE ever stores CUI.
- **Unified API** for CRM integration rather than N hand-built connectors.
  Salesforce restricted new Connected App creation in Spring '26 — build
  for External Client Apps.
- **Engine-side IP isolation holds.** Scoring tables, base score, per-answer
  deltas, price position and market differentials never reach the
  client-facing database or the browser. The prototype violated this once
  and was stripped.

### Known gaps

- No API layer. The prototype reads embedded JSON, not the database.
- **Scope filtering is untested.** `fn_user_visible_org_nodes` exists but
  nothing exercises it. `aero.bu2@demoaero.test` is scoped to a BU holding
  zero pursuits and should see nothing — unverified.
- No audit trigger. `audit_log` exists; nothing writes to it.
- No licensing enforcement. Deliberately kept out of the access path.
- Staffing month-spreading in the prototype is an assumption, not checked
  against `staffing_phaser.py`.
- Two AERO pursuits were reassigned from BMC2A to MSN in the database only;
  their stored Pwins were computed against BMC2A's differential.
- `06_plan_year.sql` is superseded by `migrate_workbook.py` and should be
  deleted.

---

## Versioning notes

- **0.1.x** — database and prototype. Schema may break between patches.
- **0.2.0** — API layer and the prototype reading live data.
- **0.3.0** — authentication and scope enforcement.
- **1.0.0** — first production deployment for a paying client.

Engine versions are tracked separately in `cda-engine`. The schema records
which engine version produced each assessment via
`pwin_assessment.engine_version`; current data is engine v0.23.
