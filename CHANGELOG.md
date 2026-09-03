# Changelog — cpde-web

Web version of the Competitive Pipeline Decision Engine.
Separate repository from `cda-engine`; versioned independently.

Format follows Keep a Changelog. Versions are semantic, but while the
major is 0 the schema may break between minors — say so explicitly when
it does.

---

## [0.5.0] — 2026-09-03

Significant scope since v0.4.0 -- the first cross-product consistency
audit ran, found a real engine-side bug, and led to scoring, fee, and
competitor construction all moving from three independently-maintained
copies to one engine-served source of truth. Every item below was
verified live -- real AWS/SSM calls, the real production engine, actual
before/after comparisons for known pursuits -- not read from a diff or
taken on another team's word.

### Cross-product consistency audit — first run

- New standing practice: a routine audit comparing `cpde-web`, the
  Salesforce plugin, and the engine directly against each other and
  against the live system, not against documentation or memory.
- Found a real engine-side scoring bug: TM1a "No" scored -10/-10,
  TM1b "No" scored +10/+10, both should be 0/0 -- confirmed against the
  real source VBA (`CPwinScoringTables.cls`). `cpde-web`'s own scoring
  port was already correct on both; the bug was engine-only.
- Confirmed the bug had zero real-world impact: no production Pwin was
  ever computed through the engine's own answer-scoring path (disabled
  since early this project), and no real client data existed during the
  exposure window regardless -- demo data only.
- Found and narrowed an over-broad IAM policy (`CpdeWebCoreReadPolicy`):
  previously granted read access to the `config` path (differentials)
  in addition to the `key-value` secret actually used; narrowed to the
  three specific parameter names needed, `GetParametersByPath` dropped
  entirely. Verified live: `key-value` still resolves, `config` and
  path-based listing are now genuinely denied by direct attempt.
- Found a stale doc in the Salesforce plugin -- handed off to that repo
  directly, not `cpde-web`'s to fix.

### Scoring, fee, and competitor construction moved to the engine

- `GET /v1/scoring-tables` (engine) is now the single source for the
  full TM1a-P1 delta table and the nominal fee-rate-by-contract-type
  table (`fee_rates`, folded into the same response) -- `cpde-web`
  fetches and caches both live; the local hardcoded copies are REMOVED,
  not kept as a dormant fallback.
- `/v1/run` (engine) now accepts an optional `bidders: int` as an
  alternative to a hand-built `competitors` array -- `cpde-web`'s local
  "Avg Co N" construction logic is REMOVED, replaced by sending the
  bidder count directly.
- Resolved a previously-unlogged THIRD copy of the P1 delta table
  (`question_option`/`ddl/13_bhptw_fee.sql`) discovered during this
  migration -- `fee.py` now reads the same live `p1` table `scoring.py`
  already fetches; the old columns are deprecated (flagged, not
  dropped) via `ddl/17_deprecate_fee_columns.sql`.
- All of the above verified live, end to end, against the real
  production engine for a known AERO pursuit (opp 1046) -- Pwin
  (`0.169275`) and fee (`0.075000`) both identical before and after
  every change in this set.
- Competitor-construction equivalence independently re-verified by
  `cpde-web` itself, not taken on the engine team's "confirmed
  byte-identical" report alone: the old hand-built `competitors` array
  and the new `bidders: N` payload were run side-by-side against the
  same real pursuit on the same live engine, and the resulting `pwin`
  values compared directly.

### Local dev credential automation

- Scheduled Task (`cpde-web-aws-creds-refresh`, 45-minute interval,
  runs as the interactive user, never SYSTEM) automates the
  `cpdeWebLocalDevRole` assume-role refresh -- `aws sso login` itself
  remains manual by design, since that step requires human browser
  approval and should not be automated around.
- Confirmed and documented: every successful refresh recreates the
  `api` container (Docker doesn't propagate `.env` changes to a running
  container; `engine_client.py`'s SSM client is a process-lifetime
  singleton either way) -- a real, accepted ~45-minute restart cadence,
  stated plainly rather than hidden.
- Failure path genuinely tested (both the SSO login-token cache and the
  derived-credential cache removed to simulate a real expiry, not just
  reasoned about) -- failure surfaces in Task Scheduler's own result
  code and a dedicated log file, readable via `check-aws-creds-status.ps1`.

### Test suite growth

| Suite | Assertions | Result |
|---|---|---|
| `test_isolation.py` — tenant isolation (RLS) | 29 | pass |
| `test_scope.py` — business-unit scope | 14 | pass |
| `test_integrity.py` — data integrity | 44 | pass (1 warning, non-fatal, unchanged since v0.2.0) |
| `test_api_security.py` — API-layer security | 116 | pass |
| `test_staffing_escalation.py` — staffing escalation model | 14 | pass |
| `test_market_sync.py` — market sync job | 16 | pass |
| `test_recalc_response_handling.py` — engine response-shape discipline | 3 | pass |
| `test_scoring_migration.py` — live scoring-table migration (new) | 10 | pass |
| `test_fee_competitor_migration.py` — fee/competitor migration (new) | 8 | pass |
| `test_engine_client.py` — real AWS/SSM + live engine verification | 10 | pass (requires a live AWS session; skipped, not failed, otherwise) |

**264 assertions passing across ten suites** (up from 244 across eight
at v0.4.0).

### Known gaps

- `market_sync` noise: repeatedly flags AERO's real markets and injects
  a placeholder while running against production -- cosmetic, not yet
  investigated, worth a look. New this round.
- The Salesforce plugin has not yet migrated to the new
  `/v1/scoring-tables` `fee_rates` or the `bidders` shortcut -- that
  repo's own work, tracked there, not blocking anything here.
- No real `cpde-web` production ECS deployment yet -- `cpdeWebTaskRole`
  exists, inert. Unchanged since v0.4.0.
- `empower-ai` still has no `cpde-web` client row -- not currently
  needed, Excel-only for now. Unchanged since v0.4.0.
- `pwin_assessment.blended_pwin` (the dependency-blend math combining a
  `BASE` and `DEPENDENT_WON` assessment) is still not computed anywhere
  -- unchanged since v0.3.0.
- Two AERO pursuits reassigned from BMC2A to MSN in the database only;
  their stored Pwins were computed against BMC2A's differential --
  unchanged since v0.3.0.
- `06_plan_year.sql` superseded by `migrate_workbook.py`; delete it --
  unchanged since v0.3.0.
- Tests are still not automated on commit.
- No licensing enforcement.

## [0.4.0] — 2026-09-02

Significant scope since v0.3.1 -- this is the first round where
`cpde-web` authenticated against real AWS infrastructure and the real
production engine, not local stubs or overrides, alongside a full pass
of Targets & Budgets / Dashboard scope fixes and a new market-sync
feature. Every item below was verified by actually driving it -- live
API calls, live AWS/SSM calls, Playwright where UI was involved -- not
read from a diff.

### Targets & Budgets and Dashboard scope fixes

- **The Targets picker genuinely didn't work.** Root cause: a dead,
  hardcoded `.chip` UI element sat exactly where a real BU picker
  belonged, styled to look clickable but wired to nothing -- the real,
  working picker was a plain `<select>` elsewhere on the page that a
  real user had no reason to notice. Removed the dead chips; the real
  picker now shows a "Viewing: X — Change" banner so the current
  selection is never invisible again.
- Whole-business scope added as a valid Targets/Dashboard target, not
  just license-boundary business units -- confirmed nothing in the
  schema (`plan_year.org_node_id`) structurally prevented it.
- **Dashboard showed a real $0 target for any multi-candidate user**,
  including AERO's own business-level admin -- last round's own
  ambiguity fix (refusing to guess which BU's targets to show) had no
  UI path to resolve the ambiguity for the Dashboard specifically. Fixed
  with a new hierarchical rollup selector (division / BU / whole
  business, matching the real org tree depth, not hardcoded to two
  levels) and a rollup query that sums every descendant's own
  `plan_year` row -- verified against AERO's real, asymmetric BU/BU2
  target split ($250.0M + $41.4M = $291.4M), not just a trivial
  single-branch case.
- Org-unit picker added to the pursuit edit form (full path label,
  e.g. "Advanced Systems | Sensors" vs. "Space Systems" alone,
  generated from the real tree depth). Reassignment is scope-limited
  (reuses `fn_user_visible_org_nodes`, no new access-control mechanism)
  and audited through the same trigger as every other pursuit edit.
  Confirmed directly against the schema that a pursuit CAN structurally
  sit on a BU with real divisions beneath it -- the "leaf nodes only"
  picker rule is therefore an application-level choice, not a database
  guarantee, and is documented as such.
- `org_node.is_test_fixture` added so a synthetic node created purely
  to give the scope test suite a genuinely-empty fixture (`BUZ`) is
  excluded from all three user-facing pickers (Targets, Dashboard,
  pursuit org-unit) while remaining fully functional for actual scope
  resolution -- a user genuinely scoped to a test-fixture node still
  resolves correctly through `fn_user_visible_org_nodes`/
  `fn_user_pursuits`, verified directly, not just documented as intent.

### Real SSM/IAM engine authentication

- `engine_client.py` now resolves real per-client API keys from AWS SSM
  (`ssm:GetParameter` with decryption), replacing the local-dev env-var
  override entirely -- one credential path, not two.
- Standard AWS credential chain (STS-assumed role locally via
  `cpdeWebLocalDevRole`, task role in production via `cpdeWebTaskRole`
  when that deployment exists) -- no code-level distinction between the
  two.
- 5-minute in-process key cache, invalidated on a 401/403 from the
  engine rather than trusted blindly for its full TTL.
- `refresh-aws-creds.ps1` -- local dev credential helper, hardened to
  print the resolved IAM identity back to the developer after every
  refresh (built specifically after an earlier round accidentally
  exported an admin session instead of the scoped role).
- Real end-to-end Recalculate Pwin verified against the live production
  engine (`api.cda-us.com`), not a stub, for a known AERO pursuit --
  result matched already-stored data.

### Data fixes found and corrected

- `client.engine_secret_ref` for DEMO and AERO updated to the real
  per-product SSM paths (the per-product API key scoping cutover had
  deleted the old flat paths).
- DEMO's `engine_client_code` corrected from `collins` to the real
  `collins-aerospace` -- a naming mismatch between two independently-run
  pieces of work, not a bug in either one individually, found because it
  became load-bearing once real SSM resolution went live.

### `client_escalation_rate` write endpoint

- `PUT/GET /api/staffing/escalation-rates[/{year}]`, same role gate as
  plan-year targets, deliberately NOT audited via `fn_audit` (a prior,
  documented design decision -- operational configuration, not pursuit
  data -- correctly preserved rather than silently overridden this
  round).
- Verified an override is actually CONSUMED by a real staffing
  calculation, not just stored (BDGEN/2028-01 escalated figure changed
  correctly when a client override was set, reverted correctly when
  removed).

### Market sync

- New scheduled job polling the engine's `/v1/markets` (never SSM's
  `/config` directly -- `cpde-web`'s IAM is deliberately not scoped to
  read differentials) and syncing the local `market` table.
- Additions sync automatically; removals are NEVER auto-deleted, only
  flagged for review (`flagged_for_review`, `flagged_at`,
  `flagged_reason`) -- a market disappearing while pursuits reference it
  is a human decision. Renames cannot be distinguished from a removal +
  an addition -- confirmed directly against the engine's own
  `GET /v1/markets` contract (bare display-name strings, no code or id
  at all) rather than assumed; documented as a real, structural
  limitation, not an oversight.
- Verified against REAL production drift, not a synthetic test case:
  Collins-aerospace's real market list had grown to 5 (from the 3
  originally loaded); the sync correctly created the 2 missing ones and
  left the existing 3 untouched.
- Confirmed the recurring background loop fires on its own schedule
  (observed multiple times, unprompted, during verification), not just
  via manual trigger.
- `empower-ai` has no client row in `cpde-web` yet -- market sync
  correctly has nothing to do there; this resolves naturally whenever
  that tenant is actually onboarded, not a bug to chase now.
- Production gate (blocked on the engine team's three-layer client-
  config migration) is now CONFIRMED CLEAR -- explicit sign-off
  received for all three real clients, not inferred from documentation.
  `MARKET_SYNC_ENABLED` already defaults true in local dev; no separate
  `cpde-web` production deployment exists yet to flip anything else on.

### External reference verification (engine v0.27 integration doc)

- Systematic verification against the engine team's own published
  integration reference -- found and confirmed a REAL ERROR IN THE
  REFERENCE DOC ITSELF: its example competitor `scores` keys
  (`tech`/`mgmt`/`pp`) fail against the live engine (DAP solver error,
  every synthetic competitor, for a real pursuit's real inputs);
  `cpde-web`'s actual keys (`Technical`/`Management`/`Past Performance`,
  matching the original VBA contract) are the ones the engine actually
  reads correctly. No prior Recalculate Pwin result was affected --
  `cpde-web` has always sent the correct keys. Locked in as a permanent
  live regression test.
- Confirmed every engine call in the codebase checks the correct,
  endpoint-specific failure signal (`solver_succeeded`, not bare HTTP
  status -- every engine endpoint returns 200 regardless of success).
  Added a regression test proving `recalc.py` actually raises on a
  200-with-`solver_succeeded:false` response rather than treating the
  HTTP success as computation success.
- Confirmed `cpde-web` calls exactly two engine endpoints (`/v1/run`,
  `/v1/markets`) and nothing outside its key's authorized scope.
- Ran the engine team's own suggested smoke test end to end, live:
  `GET /health` (confirmed `product: cpde-core`, correct `client_name`,
  `engine_version: 0.27`), `GET /v1/markets` (real list, not the
  generic fallback), `POST /v1/run` (matched a known-good stored Pwin
  exactly).

### Process note worth carrying forward

A shared reference document from the team that owns the engine was
still WRONG on a real, load-bearing detail. Verify against the live
system even when a trusted source's documentation says otherwise --
this is the second time this project has found a documentation/
assumption error by testing live rather than trusting a written source
(the first was the IP-boundary correction earlier this project).

### Test suite growth

| Suite | Assertions | Result |
|---|---|---|
| `test_isolation.py` — tenant isolation (RLS) | 29 | pass |
| `test_scope.py` — business-unit scope | 14 | pass |
| `test_integrity.py` — data integrity | 44 | pass (1 warning, non-fatal, unchanged since v0.2.0) |
| `test_api_security.py` — API-layer security | 116 | pass |
| `test_staffing_escalation.py` — staffing escalation model | 14 | pass |
| `test_market_sync.py` — market sync job | 16 | pass |
| `test_recalc_response_handling.py` — engine response-shape discipline | 3 | pass |
| `test_engine_client.py` — real AWS/SSM + live engine verification | 8 | pass (requires a live AWS session; skipped, not failed, otherwise) |

**244 assertions passing across eight suites** (up from 164 across five
at v0.3.1).

### Known gaps

- No real `cpde-web` production ECS deployment yet -- `cpdeWebTaskRole`
  exists, inert. Whoever builds it should default
  `MARKET_SYNC_ENABLED=true` in that environment's config (documented
  in three places this round specifically so this isn't rediscovered).
- `empower-ai` has no `cpde-web` client row -- not a bug, just not
  onboarded yet.
- `pwin_assessment.blended_pwin` (the dependency-blend math combining a
  `BASE` and `DEPENDENT_WON` assessment) is still not computed anywhere
  -- unchanged since v0.3.0.
- Two AERO pursuits reassigned from BMC2A to MSN in the database only;
  their stored Pwins were computed against BMC2A's differential --
  unchanged since v0.3.0.
- `06_plan_year.sql` superseded by `migrate_workbook.py`; delete it --
  unchanged since v0.3.0.
- Tests are still not automated on commit.
- No licensing enforcement.
- Duplicate-pursuit detection remains unbuilt (see the working brief's
  backlog).

---

## [0.3.1] — 2026-09-01

Resolves the top Known Gap from v0.3.0: Targets & Budgets was unusable
for AERO's real admin user, because `plan_year` had no way to say which
of a user's several license-boundary business units a read or write
applied to.

### Investigation finding, stated plainly

Before this fix, `GET /api/plan-years` did **not** already refuse like
`PUT` did — it silently queried every visible org node at once with no
way to tell which business unit a row belonged to, and returned
whatever it found as a bare, unmarked list. For a multi-BU user this
looked correct only by coincidence: AERO's BU2 happens to hold zero
`plan_year` rows today, so the merge never visibly collided. The moment
BU2 got any target data of its own, this endpoint -- and `bootstrap.py`'s
own separate copy of the same query, which is what actually feeds the
Targets page and every dashboard chart -- would have silently returned
ambiguous or wrong numbers with no indication anything was wrong. That
is worse than `PUT`'s explicit 409, and is now fixed the same way.

### Fixed

- New shared resolver (`api/app/plan_scope.py`), reused by `PUT
  /api/plan-years/{year}`, `GET /api/plan-years`, and `bootstrap.py`'s
  embedded plan query -- one place the disambiguation logic lives,
  not three that could drift.
- Both endpoints now accept an optional `org_node_id`. Exactly one
  candidate BU in scope: behaves exactly as before, no parameter
  required -- confirmed backward compatible for `demo.admin` and every
  other single-BU user, byte-for-byte unchanged flow.
- Multiple candidates, no `org_node_id`: `PUT` 409s and `GET` returns
  `{"ambiguous": true, ...}`, both now carrying the real candidate list
  (`{id, code, name}` each) instead of a plain string with no recovery
  path.
- `org_node_id` supplied: verified against the caller's own resolved
  candidate set before use -- an id outside scope (or a different
  tenant's id entirely) is rejected, never silently accepted. Verified
  directly: a DEMO admin's cross-tenant attempt using AERO's own BU id
  was rejected.
- `bootstrap.py` embeds no targets at all for a multi-BU user (rather
  than the old silent merge) and adds `target_org_nodes` so the frontend
  can offer a picker instead of presenting arbitrary numbers as if they
  were real.
- Frontend: Targets & Budgets shows a BU picker only when
  `D.target_org_nodes` is non-empty. Picking a BU fetches its real data
  via the now-fixed `GET`, and the selection is remembered for the
  session (survives an internal post-save reload, resets on sign-out or
  a genuine page reload) so `PUT` calls carry the right `org_node_id`.
  A single-BU user never sees the picker at all.

### Verified

- All 6 of this round's RED checks (4 backend, 2 Playwright) confirmed
  failing for the right reasons before any fix, all green after.
- Driven live as `aero.admin`: picked "Advanced Systems (BU)" from two
  candidates, edited 2027's revenue target, saved, reloaded. Checked the
  underlying `plan_year` row's `org_node_id` directly, not just the UI
  round-trip -- landed on `BU`, confirmed `BU2` untouched (0 rows).
  Audit trail shows the correct before/after diff, attributed correctly.
  Restored via the real write path afterward.
- `demo.admin`'s existing single-BU flow re-verified end-to-end
  (edit -> save -> reload) with zero picker, zero behavior change --
  the backward-compatibility check that mattered most here, since it's
  the path that already worked and could not regress.
- 164 assertions passing across five suites (up from 157 at v0.3.0):
  isolation 29, scope 12, integrity 41 (1 non-fatal warning),
  api_security 76, staffing_escalation 6.

---

## [0.3.0] — 2026-09-01

Real engine-integrated Pwin recalculation, and full closure of the
original backlog (3a-3f: engine recalculation, dashboard pie/combo
charts, no-blank-space grid, change-polling banner, staffing escalation,
Targets & Budgets). Every item below was verified by actually driving
it -- Playwright end-to-end where UI was involved, direct API/DB checks
otherwise -- not just read from a diff. **157 assertions passing across
five suites**, up from 146 at v0.2.0.

### Added

**Recalculate Pwin — real engine integration**
- Full `CPwinScoringTables.Lookup()` port (`api/app/scoring.py`),
  verified two independent ways: against the VBA's own `SmokeTest()`
  (11/11) and against three real AERO pursuits' stored answers,
  reproducing their exact stored tech/mgmt/pp/price/cprice -- including
  the TM5 quirk where its price delta writes onto `client_price` (not
  `comp_price`) with the sign flipped.
- Fee computation shared between Black Hat and Recalculate
  (`api/app/fee.py`) so the two can't drift apart.
- Engine client (`api/app/engine_client.py`) calling the confirmed real
  `/v1/run` contract (confirmed by reading `cda_engine/runtime/api.py`
  and `pwin_engine.py` directly, not assumed from the VBA). Local dev
  targets a local engine instance via `CPDE_ENGINE_URL`; real per-client
  SSM/IAM key resolution is explicitly NOT built yet (flagged in that
  module's own docstring as follow-up work, not silently skipped).
- Synthetic competitor construction confirmed from `BuildInputJson_` and
  ported exactly: bidder count -> N "Avg Co" entries, fixed 85/85/85
  scores, `bid_probability: 1.0`. Not real competitor identity or
  scores -- `ddl/01_schema.sql` NOTE-3 already established that's out of
  scope client-side by decision.
- Sandbox preview mode (`persist=False`) kept architecturally separate
  from the real pursuit path -- the sandbox's hypothetical, unsaved
  answer edits needed a fundamentally different call than a real
  recalculation, not a shared code path with a flag bolted on.
- Guard against silently regressing a Post-BH/PTW pursuit's
  `assessment_type` back to `QUESTIONNAIRE` on recalculation -- would
  otherwise overwrite a higher-precision analyst-entered assessment with
  a lower-precision engine one.
- **Correction to an earlier design assumption in this project, stated
  plainly so it isn't reintroduced**: the actual IP boundary is the
  tournament solve inside `/v1/run`, NOT the per-answer scoring deltas
  or the fee computation. Both of the latter are already computed
  client-side in the production Excel tool and displayed openly. An
  earlier assumption in this project drew that boundary too broadly;
  `scoring.py` and `fee.py` are correct as built, computing both
  server-side in this app rather than round-tripping through the engine
  for values that were never protected.

**Sole source**
- Fixed: `12_sole_source_pwin.sql` had been written but never actually
  applied to the running database -- every "turn sole source on" write
  had been silently failing. Applied it, and added a permanent
  regression test (`test_sole_source_migration_applied` in
  `test_integrity.py`) specifically so "migration file exists but was
  never run" cannot recur unnoticed -- that exact class of bug, not just
  this one instance of it.
- Confirmed via an isolated throwaway Postgres container (not the live
  dev database) that a genuinely fresh environment picks up the
  migration correctly -- this was a live-database timing gap, not a
  `docker-compose.yml` or init-script ordering bug.
- Full sole-source on -> off -> real-recalculation cycle verified
  end-to-end against the live API.

**Dashboard (backlog 3b, 3c)**
- Pie chart restricted to "By market" and "By competitive analysis
  phase" only -- every other card's configure dropdown no longer offers
  it at all, rather than offering it and silently refusing to render.
- Pie given its own `PIE_COLORS` constant, deliberately not the staffing
  view's `CCOL` -- `CCOL`'s first entry is near-black, and Pre-BH being
  the dominant phase in every dataset loaded so far turned that into a
  giant black wedge filling most of the card. Also fixed: the pie's SVG
  had no fixed size, so the page's global `svg{width:100%}` rule (meant
  for the responsive bar/combo charts) stretched a 1:1-aspect pie to the
  full card width. Both bugs, not just the color one.
- Combo (bar + overlaid line) chart added, now the DEFAULT for Revenue
  vs Target, B&P vs Budget, and Investment vs Budget -- a bar-only chart
  was losing the target line's context.
- No-blank-space grid pass across the dashboard and B&P views: found and
  fixed one real instance (`invtable` sitting alone in its own
  two-column grid row) by moving it to a full-width card, matching the
  convention already used elsewhere on the page. Audited every other
  grid on both views; none of them had the problem.
- Card titles corrected: "By market" -> "Revenue by market", "By
  competitive analysis phase" -> "Revenue by competitive analysis
  phase" -- checked that the second title was equally underspecified
  (same four columns as the first) before applying the same fix, rather
  than assuming.

**Change-polling banner (backlog 3e)**
- `GET /api/changes?since=` -- already built, never called from the
  frontend -- is now polled roughly every 60 seconds. Distinct from the
  presence system (presence says someone else has THIS pursuit open;
  this says the PORTFOLIO changed since the page loaded); both run at
  once without interfering with each other, confirmed via a real
  two-session test with no mocking.
- Polling stops when the tab is hidden (`visibilitychange`) and resumes
  when visible again -- no wasted requests in a background tab.
- The banner is persistent, not auto-dismissing like the existing
  `#toast` pattern -- a portfolio change is not a transient
  confirmation. Dismissing it hides it only until the next poll finds
  something new; it does not permanently suppress future changes.
- The `since` cursor advances via the response's `latest` field after
  every poll (found changes or not), so nothing in the gap between two
  polls is missed and the same change is never reported twice.
- Test-interval override (`window.__CPDE_TEST_POLL_MS`) is a bare JS
  global reachable only by running script before the page's own script
  executes (Playwright's `addInitScript`, a devtools console) -- never a
  URL parameter or UI control a real user could trigger by accident.

**Staffing escalation (backlog 3f)**
- `labor_category.is_static` ported from `cda_engine`'s real
  `LABOR_CATEGORIES` config, not guessed from category names -- 5
  static (CM, Tech Lead, Proposal Mgr, Volume Leads, Pricing Lead), 13
  variable, confirmed against the live schema.
- Escalation applied inside `monthly_contributions()`, the shared
  per-month aggregation point both `/api/staffing/demand` and
  `bootstrap.py`'s own duplicate staffing widget read from -- fixed
  once, both call sites correct, rather than fixing the one that
  happened to be tested first.
- New `client_escalation_rate` table (per-tenant override of the
  generic rate table for one calendar year, full RLS) -- built after
  confirming with the user this was in scope for the pass, not assumed.
  No write endpoint ships with it; setting an override rate today is a
  manual `INSERT`, the same posture as `set_engine_identity.sql`.
- Cross-verified two independent ways before wiring anything into
  `staffing.py`: a hand-computed cumulative escalation factor, and all
  22 assertions in `cda_engine`'s own `test_staffing_escalation.py` test
  fixture run against the ported functions -- both agreed exactly.
- Known before/after for the verification fixture (BDGEN, 2028-01):
  2.02 unescalated -> 1.86 escalated; all five static categories
  confirmed byte-for-byte unchanged in the same month.

**Targets & Budgets**
- Wired to the real `PUT /api/plan-years/{year}` endpoint via the
  existing edit-buffer/save-bar pattern (a year-keyed `targetBuf`,
  reusing `editBar()`'s HTML/CSS) instead of a second editing mechanism.
  Previously this view only ever mutated the in-memory `TG` object --
  confirmed directly by reading the code, not assumed -- with no save
  path and no role gating at all.
- Caught and avoided re-introducing a documented past bug from this
  exact codebase: re-rendering the whole view on every `change` event
  destroys the Save button before a blur-triggered click lands. Fixed
  by updating the buffer and dirty styling in place, matching pursuit-
  detail editing's established discipline, rather than the naive
  full-rerender-on-change approach that shipped this bug once already.
- Dashboard chart propagation confirmed to need no extra invalidation
  step: `loadData()` already rebuilds `TG` from fresh `D.targets` inside
  `rebuildDerived()`, and `render()` unconditionally redraws every view.
  The first version of the verification check for this false-positived
  by reading `TG` in-memory without a real page reload -- editing
  mutates the same object the dashboard reads, so it would have passed
  even with zero persistence. Caught during the RED phase and rewritten
  to force a genuine reload before checking; the rewritten check showed
  the dashboard chart's tooltip literally reading the newly-saved target
  value after reload.
- Non-admin/executive users see read-only targets with the same
  "admin only" visual treatment already used for Opportunity ID, not a
  new pattern.

### Test suite growth

| Suite | Assertions | Result |
|---|---|---|
| `test_isolation.py` — tenant isolation (RLS) | 29 | pass |
| `test_scope.py` — business-unit scope | 12 | pass |
| `test_integrity.py` — data integrity | 41 | pass (1 warning, non-fatal) |
| `test_api_security.py` — API-layer security | 69 | pass |
| `test_staffing_escalation.py` — staffing escalation model | 6 | pass |

The one integrity warning is unchanged from v0.2.0: 20 pursuits migrated
from the workbook before this schema distinguished assessment types,
`assessment_type` left as `QUESTIONNAIRE` because it isn't retroactively
recoverable (`11_assessment_type.sql`'s own documented behavior).

### Known gaps

- **Targets & Budgets does not work for AERO specifically.**
  `PUT /api/plan-years/{year}` correctly refuses to guess which business
  unit's plan to edit when a user has more than one license-boundary BU
  in scope -- and AERO's admin user does (BU and BU2 both visible);
  DEMO's admin does not, which is why DEMO was used to verify the
  feature above. There is no UI or API parameter to specify which BU's
  plan a multi-BU user means. Not introduced this round -- surfaced by
  this round's testing, on the endpoint exactly as it shipped in v0.2.0.
  Real AERO users cannot set targets today. This should be picked up
  next, not left indefinitely -- it blocks a core feature on the more
  representative of the two loaded tenants.
- `engine_client.py`'s local-dev API key handling (no SSM/IAM in this
  sandbox) -- flagged as follow-up work, per that module's own
  docstring.
- `client_escalation_rate` has no write endpoint; setting a client
  override rate is a manual `INSERT` until one is built.
- `pwin_assessment.blended_pwin` (the dependency-blend math combining a
  `BASE` and `DEPENDENT_WON` assessment) is still not computed anywhere
  -- Recalculate Pwin writes `pwin = base_pwin` directly for a
  non-dependent pursuit and leaves `pwin` NULL (flagging
  `pwin_needs_recalc`) for a dependent one, rather than inventing the
  blend formula.
- Two AERO pursuits reassigned from BMC2A to MSN in the database only;
  their stored Pwins were computed against BMC2A's differential.
- `06_plan_year.sql` superseded by `migrate_workbook.py`; delete it.
- Tests are still not automated on commit.
- No licensing enforcement.
- Duplicate-pursuit detection remains unbuilt (see the working brief's
  backlog).

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
