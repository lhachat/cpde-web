# Changelog — cpde-web

Web version of the Competitive Pipeline Decision Engine.
Separate repository from `cda-engine`; versioned independently.

Format follows Keep a Changelog. Versions are semantic, but while the
major is 0 the schema may break between minors — say so explicitly when
it does.

---

## [0.2.0] — 2026-08-28

The API layer, a live UI reading from the database instead of embedded
JSON, the Black Hat/PTW assessment forms, and a real (not stubbed) engine
integration for Recalculate Pwin. Originally scoped in the 0.2.0
versioning note below as just "API layer and the prototype reading live
data" — it grew well past that as write endpoints, audit, presence and
the two competitive-analysis paths all turned out to depend on each
other. **146 assertions passing across four suites.**

### Added

- **FastAPI backend** (`api/app/`), served alongside the static UI from
  one origin so the session cookie needs no CORS negotiation.
  - Session-cookie auth (`auth.py`), dev-mode email-only login behind
    `CPDE_DEV_LOGIN`. Tenant context is resolved server-side from the
    session only — never from a request parameter, header, or body
    field. **Tested**: forged `client_id` in the query string, a header,
    and an alternate header all fail to move a session out of its real
    tenant (`test_api_security.py` group 3).
  - **`bootstrap.py`** — single-call full-portfolio payload. The live UI
    now reads this instead of an embedded JSON blob; every view's
    filtering/sorting/aggregation logic is unchanged, only the data
    source moved.
  - **`portfolio.py`** — scoped reads: `/pursuits`, `/pursuits/{id}`,
    `/dashboard`, `/reference` (dropdown source data, codes only — a
    client never sees or sends a foreign key).
  - **`staffing.py`** — the FTE phasing model as an API, matching the
    prototype's month-spreading exactly.
- **Write endpoints** (`write.py`), all sharing one discipline: tenant
  from session, scope re-checked on every id (RLS separates companies,
  not business units — an endpoint that skips the scope predicate is a
  classic IDOR), 404 (not 403) for out-of-scope, only whitelisted fields
  ever reach an `UPDATE`.
  - `PATCH /pursuits/{id}` — general field edits, reference codes
    resolved to ids server-side so a smuggled foreign-tenant key simply
    doesn't resolve.
  - `PATCH /pursuits/{id}/bid` — the bid toggle, its own endpoint rather
    than a field on the general PATCH so it gets its own audit signature.
  - `POST /pursuits/{id}/outcome` — closing/reopening a pursuit, with a
    guard requiring `bid_decision='BID'` before WON/LOST can be recorded
    (`also_set_bid` to change both deliberately in one call).
  - `PUT /plan-years/{year}` — admin/executive only; a capture manager
    cannot move the bar their own pipeline is measured against.
- **Optimistic concurrency** — `PATCH /pursuits/{id}` accepts
  `expected_updated_at`; a write against a row that moved since the
  client last read it is rejected with 409 and the name of who changed
  it, rather than silently overwriting their edit.
- **Audit trail** — database-level, not application code. `fn_audit()`
  trigger on every write-relevant table, `audit_log` with
  before/after `changed_fields`. `updated_by`/`updated_at` surfaced in
  the UI as "last edited by"; `GET /pursuits/{id}/history` is
  deliberately not admin-only (accountability, not surveillance) while
  the portfolio-wide `GET /audit` is.
- **Presence** (`pursuit_presence`) — advisory only, never a lock.
  Heartbeat on open, swept opportunistically on the next heartbeat
  anywhere in the tenant, TTL-based rather than requiring an explicit
  close.
- **Black Hat and PTW assessment forms**, replacing the "not built in
  this version" placeholder. Two modes on one form (`bhptw.py`):
  - Black Hat computes fee (`fee.py`: `contract_type.base_fee_rate` + the
    chosen P1 option's `price_delta`) and records a price-aggressiveness
    choice; PTW takes margin (capped 30%) and bid price as a direct
    override of the fee formula.
  - Both write the analyst-entered Pwin to `base_pwin`, require an
    existing `QUESTIONNAIRE` assessment to exist first, and require both
    `BASE` and `DEPENDENT_WON` scenarios for a dependent pursuit
    (`black_hat_ptw_complete` only flips true once every scenario the
    pursuit actually needs is satisfied).
  - **Neither path calls the engine** — confirmed against
    `BuildInputJson_`/`CallPwinEngine_` in the VBA: by this phase a real
    competitive analysis has already happened outside the system, and
    the engine's questionnaire-based score has nothing further to add.
    `/v1/run` is Pre-BH-questionnaire-only.
  - `ddl/13_bhptw_fee.sql` — `contract_type.base_fee_rate`,
    `question_option.price_delta`. P1 deltas seeded directly (the value
    is literally the percentage in the option's label); contract-type
    rates seeded from `fee_config.py` in `cda-engine`, confirmed against
    every Post-BH pursuit in the loaded AERO data.
- **Real Recalculate Pwin** — the Pre-BH questionnaire path, replacing
  the `alert()` stub in both the pursuit detail view and the sandbox.
  - **`api/app/scoring.py`** — full port of `CPwinScoringTables.Lookup()`
    (all eight questions: TM1a, TM1b, TM2, TM3, TM4, TM5, PP1, P1), not
    just the P1 slice Black Hat needed. Verified against the VBA's own
    `SmokeTest()` (11/11) and, independently, against three real AERO
    pursuits' stored answers — reproduced their exact stored
    tech/mgmt/pp/price/cprice, including the TM5 quirk where its price
    delta writes onto `client_price` (not `comp_price`) with the sign
    flipped.
  - **`api/app/fee.py`** — fee resolution factored out and shared between
    Black Hat and Recalculate Pwin so the two computations can't drift
    apart from each other.
  - **`api/app/engine_client.py`** — the HTTP client for `POST /v1/run`.
    Confirmed the request/response shape by reading
    `cda_engine/runtime/api.py` and `pwin_engine.py` directly, not
    assumed from the VBA (the VBA's answer-scoring entry point,
    `compute_pwin_from_answers()`, is disabled in the current engine —
    scores must be pre-computed by the caller, which is what
    `scoring.py` is for). Synthetic "Avg Co N" competitors (fixed
    85/85/85 scores, one per bidder) confirmed against `BuildInputJson_`
    — competitor identity is out of scope client-side by design
    (`ddl/01_schema.sql` NOTE-3), and always was.
  - **Sandbox preview vs. the real pursuit path** — the sandbox's
    hypothetical, unsaved answer edits needed a fundamentally different
    call than the pursuit detail's real recalculation: `recalculate_pwin()`
    takes an optional `answers_override` and a `persist` flag.
    `persist=False` (the sandbox) never writes to `pwin_assessment` and
    skips the Pre-BH stage guard, since there's nothing to regress; the
    real path (`persist=True`) does both.
  - **Guard against regressing a Post-BH/PTW pursuit** — recalculating
    would otherwise flip `is_current` back onto a new `QUESTIONNAIRE`
    row, silently overwriting a Black Hat/PTW pursuit's higher-precision
    analyst-entered assessment with a lower-precision engine one. Blocked
    with a 400, checked once in `recalculate_pwin()` itself so both the
    HTTP endpoint and `write.py`'s sole-source-toggle-off path get it.
  - `write.py`'s sole-source-toggle-off path now attempts a real
    recalculation instead of only setting `pwin_needs_recalc` — that flag
    existed specifically because this integration didn't exist yet
    (see that file's own comment history). Falls back to the flag only
    if the recalculation attempt itself fails.
- **Test suite growth**: `test_api_security.py` gained sections for
  Black Hat/PTW (IDOR, tenant-forgery, role, business-rule checks) and
  for Recalculate Pwin (same, plus the Post-BH/sole-source/closed guards
  and the answers-preview validation).

### Fixed

- **`pursuit_history`'s FK-label resolver assumed every `FK_LOOKUP`
  column was a UUID** (`id = ANY(%s::uuid[])`). `contract_type_id`,
  `opportunity_type_id` and `pipeline_stage_id` are `SMALLSERIAL`, not
  UUID — viewing a pursuit's history after any stage/contract/opportunity
  type change 500'd. Fixed once, correctly, by casting the *column* to
  text instead of the parameter to `uuid[]` (`id::text = ANY(%s)`) — a
  single shared query template, so the fix covers every `FK_LOOKUP`
  column by construction, not just the one that happened to be exercised
  first. (This surfaced twice in this cycle's own working notes, once
  during the BH/PTW work and again during Recalculate Pwin — same bug,
  not two; the second mention was a re-report of an already-comprehensive
  fix, not a second narrow patch. `test_api_security.py`'s new "pursuit_history
  resolves every FK column type" check locks this in by changing a
  uuid-keyed and three smallint-keyed columns in one PATCH, rather than
  testing one column at a time.)
- **`ddl/12_sole_source_pwin.sql` existed but had never been applied** to
  the running database — `pwin_assessment.is_sole_source_pwin` did not
  exist, meaning every "turn sole source on" write had been silently
  failing with a database error since that migration was written, with
  nothing surfacing the failure. Applied it; verified the full sole
  source on → off → real-recalculation cycle end-to-end.
  Lesson: a migration file existing in `ddl/` is not evidence it ran —
  Postgres only executes `docker-entrypoint-initdb.d` scripts against an
  empty data directory, so anything added after first init needs to be
  applied by hand and confirmed, the same way `13_bhptw_fee.sql` was.

### Verified

| Suite | Assertions | Result |
|---|---|---|
| `test_isolation.py` — tenant isolation (RLS) | 29 | pass |
| `test_scope.py` — business-unit scope | 12 | pass |
| `test_integrity.py` — data integrity | 41 | pass (1 warning, non-fatal) |
| `test_api_security.py` — API-layer security | 64 | pass |

The one warning: 20 pursuits sitting at Post-BH/Post-PTW whose
`assessment_type` is still `QUESTIONNAIRE` — data migrated from the
workbook before this schema distinguished the three types, and (per
`11_assessment_type.sql`'s own comment) not retroactively recoverable.
Expected, not a regression.

All UI-facing work (BH/PTW forms, Recalculate Pwin, the sandbox preview)
verified by actually driving the app end-to-end (Playwright against a
real Chromium instance), not just by reading the diff — consistent with
the two worst bugs of the previous cycle (a raw-newline syntax error, an
SVG rotation error) both having looked correct on paper.

### Known gaps (unchanged from 0.1.1 except where noted)

- **No AWS SSM/IAM secret resolution.** `client.engine_secret_ref` is
  still only a reference; `engine_client.py`'s local dev sends
  `CPDE_ENGINE_API_KEY` if set, or no key at all — which the engine's own
  documented fallback (unresolved client → default config) handles, but
  real per-client secret resolution via SSM is separate follow-up work,
  flagged in that module's own docstring.
- **`pwin_assessment.blended_pwin`** (the dependency-blend math combining
  a `BASE` and `DEPENDENT_WON` assessment) is still not computed anywhere
  in this codebase — Recalculate Pwin writes `pwin = base_pwin` directly
  for a non-dependent pursuit and leaves `pwin` NULL (flagging
  `pwin_needs_recalc`) for a dependent one, rather than inventing the
  blend formula.
- Two AERO pursuits reassigned from BMC2A to MSN in the database only;
  their stored Pwins were computed against BMC2A's differential.
- `06_plan_year.sql` superseded by `migrate_workbook.py`; delete it.
- **Tests are still not automated** on commit.
- No licensing enforcement.
- Dashboard pie/combo charts, duplicate-pursuit detection, the
  change-polling banner, and staffing escalation modeling remain
  unbuilt (see the working brief's backlog).

---

## [0.1.1] — 2026-08-25

Scope enforcement built and verified. Both isolation layers now proven
rather than assumed: **41 assertions passing across two suites.**

### Added

- **`ddl/07_scope.sql`** — the canonical scope predicate.
  - `fn_user_pursuits(user_id)` — the one predicate every pursuit query
    must use. `fn_user_visible_org_nodes` already returned org nodes, but
    nothing turned that into a pursuit filter, so each query would have
    written its own and the one that forgot would be a silent cross-BU
    leak.
  - `fn_user_has_scope(user_id, org_node_id)` — for admin delegation: an
    admin may grant access only at or below their own node.
  - Deliberately **not** `SECURITY DEFINER`. The functions run as the
    caller, so RLS still applies beneath them. That is what stops a scope
    assignment pointing at a foreign node from resolving.
  - `is_active` semantics documented: deactivating a node hides its whole
    subtree, because the recursion cannot reach children through an
    inactive parent. Shutting a business unit shuts its divisions.
- **`test_scope.py`** — 12 assertions. Downward inheritance from the
  business node, narrow scope excluding, scope not crossing tenants, a
  foreign scope assignment being inert, `is_active` cutting a subtree, and
  scope failing closed without tenant context. **12/12 passing.**

### Verified

| Suite | Assertions | Result |
|---|---|---|
| `test_isolation.py` — tenant isolation (RLS) | 29 | pass |
| `test_scope.py` — business-unit scope | 12 | pass |

Cross-tenant scope protection holds because RLS makes foreign `org_node`
rows invisible before the recursive CTE reaches them. Sound, and now
tested — the failure mode to watch is someone marking these functions
`SECURITY DEFINER` for performance, which would quietly remove it.

### Changed

- Scope filtering moved out of Known gaps.
- `test_setup.sql` now also underpins the scope suite; `test_scope.py`
  creates a division-scoped user of its own.

### Known gaps (unchanged from 0.1.0 except where noted)

- No API layer. The prototype still reads embedded JSON.
- **Tests are not automated.** They pass on demand; nothing runs them on
  commit. A suite that protects you is one that cannot be skipped.
- No audit trigger. `audit_log` exists; nothing writes to it.
- No licensing enforcement.
- Staffing month-spreading in the prototype remains unchecked against
  `staffing_phaser.py`.
- Two AERO pursuits reassigned from BMC2A to MSN in the database only;
  their stored Pwins were computed against BMC2A's differential.
- `06_plan_year.sql` superseded by `migrate_workbook.py`; delete it.

### Note

`test_scope.py` temporarily deactivates AERO's business unit to prove the
subtree is cut, then restores it. If the run dies inside that group the
node stays inactive and the tenant looks empty. One UPDATE to fix, but
worth knowing.

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

- **0.1.x** — database, security and prototype. Schema may break between
  patches.
- **0.2.0** — API layer and the prototype reading live data.
- **0.3.0** — authentication and scope enforcement.
- **1.0.0** — first production deployment for a paying client.

Engine versions are tracked separately in `cda-engine`. The schema records
which engine version produced each assessment via
`pwin_assessment.engine_version`; current data is engine v0.23.
