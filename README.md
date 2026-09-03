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
