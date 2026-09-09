# CLAUDE.md

Guidance for Claude Code sessions working in this repo. Read this before
making changes -- it exists so classes of problem a periodic audit finds
get caught while code is being written, not only when someone remembers
to schedule another audit.

## Security and quality checklist for new code

A security/quality audit run on 2026-09-09 found real, serious issues
that had accumulated silently: stored XSS with zero output escaping
across 90 render sites, a test harness that hid skipped suites under a
green "ALL SUITES PASSED" banner, a dev-login flag that fails OPEN by
default, a logout endpoint that clears the cookie but never destroys
the session, and the same query/constant logic hand-duplicated across
several files. Nothing was checking for these classes of problem as the
code was written. The following is standing practice now, not a one-time
cleanup -- apply it to every change, not just when auditing.

1. **Escape every server- or user-provided string before it reaches
   `innerHTML`.** `index.html` has one shared helper for this,
   `esc()`. Any new render path that interpolates a name, label,
   market, email, or any other string into an HTML string goes through
   it -- never raw template interpolation. This was completely absent
   across 90 call sites before the audit found it; it must never be
   absent from a new one. (Note: `esc()` is for HTML-string contexts.
   Don't run it through `.value`/`.textContent` assignments, which are
   already inert -- doing so would show literal `&amp;` entities.)

2. **No new inline event handler attributes.** `onclick="..."` and
   equivalents cannot run under this app's Content-Security-Policy
   (`script-src` is nonce-only, no `unsafe-inline`) -- they will
   silently do nothing. Wire new interactive elements the way every
   existing one now is: a `data-*` attribute plus the single delegated
   `document.addEventListener('click', ...)` handler in `index.html`.

3. **RLS and server-side scope checks are non-negotiable.** Any new
   table carrying `client_id` gets `ALTER TABLE ... ENABLE ROW LEVEL
   SECURITY` **and** `FORCE ROW LEVEL SECURITY`, plus a tenant-isolation
   policy -- enabling without forcing leaves the table owner able to
   bypass it. Any new write endpoint re-checks the caller's scope
   server-side on every id it touches; never rely on the UI hiding a
   control as the only guard.

4. **Every new write path is audited, or explicitly and deliberately
   not, with a written reason.** Default to the existing generic audit
   trigger. If a table is a genuine exception (like
   `client_escalation_rate`), say so in a comment at the point of the
   write, the same way that exception is already documented -- never
   leave a new write path silently uncovered.

5. **Least privilege on new grants.** Don't grant the application
   database role (`cpde_app`/`cpde_api`) broader permissions than a new
   feature actually needs -- especially `INSERT`/`UPDATE`/`DELETE` on
   reference or global tables that have no RLS. The audit found the app
   role already holds write access to tables nothing in the app ever
   writes to, with no database-level backstop if application logic ever
   has a bug. Don't add to that; narrow it going forward.

6. **Never let internal detail reach a client-facing error.** SSM
   parameter paths, internal service URLs, raw exception text, stack
   traces -- sanitize before anything reaches an API response, even one
   only an authenticated user sees. A specific, actionable message is
   fine; the underlying `str(exc)` usually is not.

7. **Search before you duplicate.** The audit found the "latest current
   assessment row for this pursuit/scenario" query hand-written
   independently in six different files, and the scored-question list
   duplicated in four. This project has already spent real effort
   eliminating exactly this kind of drift risk ACROSS repos (scoring,
   fee, the questionnaire spec) -- don't let the same pattern grow back
   WITHIN this one. Before writing a new query, constant, or helper,
   grep for whether an equivalent already exists and extend or reuse
   it instead.

8. **Tests clean up in a `finally` block, always -- not just on the
   happy path.** The audit found tests that left real pursuits dirty
   after a mid-run failure, and one suite that overwrites and deletes a
   real named user's own data (`aero.admin`'s dashboard settings) on
   every run. Prefer dedicated test fixtures over real-looking named
   accounts where practical; whatever a test mutates, restore it in a
   `finally`, not only after the last assertion.

9. **New environment-gated behavior defaults to the safe state.**
   `MARKET_SYNC_ENABLED` defaulting to off is the pattern to follow.
   `DEV_LOGIN_ENABLED` defaulting to on -- fail-open, so an environment
   that forgets to set it gets password-less login -- is the
   anti-pattern the audit flagged. When adding a new feature flag or
   env-gated behavior, default it closed/off unless there's a specific,
   stated reason not to.

10. **A claimed lifecycle action must actually complete, not just look
    like it did.** The audit found `POST /api/logout` clears the
    session cookie but never calls `destroy_session()` -- a function
    that already existed and was already imported for exactly this
    purpose -- so a captured token stayed valid for its full TTL after
    "logout." For anything with a "this undoes/completes/finalizes X"
    shape, verify the full claimed behavior end to end, not just the
    visible symptom (the cookie disappearing from the browser, in that
    case).

## `run_tests.ps1` is trustworthy now -- but still read the summary

The harness used to print an unqualified "ALL SUITES PASSED" over
silently skipped suites. That's fixed: skips are now a distinct,
counted state, the banner says PASSED WITH SKIPS when any suite didn't
run, and the exit code reflects it (`0` clean, `2` passed-with-skips,
`1` failed). That means the false-positive banner is gone -- it does
NOT mean skips themselves are gone. No AWS session is still a real,
legitimate reason several suites won't run. Before trusting a green
result for anything that matters, glance at the summary table and
confirm it says `ALL SUITES PASSED` (not `PASSED WITH SKIPS`), or that
the specific suites relevant to your change actually ran.
