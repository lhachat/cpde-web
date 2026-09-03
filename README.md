# cpde-web

Web version of the Competitive Pipeline Decision Engine. FastAPI +
Postgres backend, a single-file vanilla-JS frontend. See
`CHANGELOG.md` for what's shipped so far.

## Local dev setup

**Before starting the stack (or any time an SSM-dependent call -- e.g.
Recalculate Pwin, or the market sync job -- starts failing mid-session
with an auth error), run:**

```powershell
.\refresh-aws-creds.ps1
```

This assumes the scoped `cpdeWebLocalDevRole` (never your own personal
SSO session -- the script hardcodes the target role and prints the
resolved identity back to you so you can see exactly which credentials
are in play) and wires the resulting temporary credentials into both
this shell session and the API container. Credentials expire after
about an hour; the script prints the exact expiry when it finishes, and
is safe to re-run at any time.

If your SSO session itself has expired, the script will tell you to run
`aws sso login` first -- that step is a human, browser-based flow and is
deliberately not scripted.

**To stop re-running this by hand every ~hour**, register a Scheduled
Task that does it automatically, every 45 minutes:

```powershell
.\install-refresh-task.ps1
```

Runs as your own Windows account (not SYSTEM -- it needs your cached
SSO session to assume-role without prompting), so it only fires while
you're logged on. It still cannot do `aws sso login` itself; if that
base session lapses, the scheduled run fails and logs why to
`logs\aws-creds-refresh.log` -- check it (or the state of things) with:

```powershell
.\check-aws-creds-status.ps1
```

Every successful refresh recreates the `api` container (`docker compose
up -d api`) -- a brief restart, roughly every 45 minutes. This is not
avoidable with the current design: Docker does not propagate a changed
`.env` file into an already-running container's environment, and
`engine_client.py`'s `boto3.client("ssm")` is a process-lifetime
singleton that resolves credentials once, not on every call -- so
picking up new credentials requires a new container process either
way.

To remove the scheduled task later: `.\uninstall-refresh-task.ps1`.

Then start the stack as usual:

```powershell
docker compose up -d
```

`GET /health` on `http://localhost:8001` confirms the API is up.
`.\run_tests.ps1` runs the full test suite -- this includes a real,
live check of per-client SSM key resolution against the shared AWS
account (test_engine_client.py), which is automatically skipped, not
failed, if `.\refresh-aws-creds.ps1` hasn't been run.

## Market sync

Keeps the local `market` table aligned with the engine's real per-client
market list -- see `api/app/market_sync.py`'s own docstring for the full
design and verification history. `MARKET_SYNC_ENABLED=true` in
`docker-compose.yml` runs it locally already.

**No separate `cpde-web` production deployment exists yet.** Whenever
one is built: set `MARKET_SYNC_ENABLED=true` in its env config from day
one. The engine team's config-migration gate this used to be blocked on
is confirmed clear (explicit sign-off, verified live for cda-internal
and collins-aerospace); do not let the flag default to off there and
have this need rediscovering as a gap.
