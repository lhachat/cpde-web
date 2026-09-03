"""
Market sync -- keeps cpde-web's local `market` table aligned with what
the engine's GET /v1/markets reports for each client.

WHY THIS EXISTS: `market` is populated once at load time and never
updated after. If a client's markets change on the engine side,
cpde-web silently drifts out of sync with no error and no signal
anything is wrong.

MATCHING IS BY NAME ONLY -- decided explicitly, not guessed. GET
/v1/markets (read directly from cda_engine/runtime/api.py's
get_markets, and config_loader.py's MarketEntry) returns bare display-
name strings, {"markets": [...]}, with no code or id of any kind. There
is therefore no stable key to detect a rename on the engine side -- one
is structurally indistinguishable from "an old market disappeared and a
different new one appeared." So: a name present in the engine's
response but not locally is CREATED as new, with a freshly generated
code; a local market whose name the engine no longer reports is
FLAGGED, never deleted or silently renamed in place. See
ddl/16_market_sync.sql for the same reasoning against the schema.

NEVER AUTO-DELETE, NEVER TOUCH is_active. flagged_for_review is a pure
signal for a person to act on -- every pursuit that already references
a flagged market keeps working unmodified (bootstrap.py/portfolio.py
only ever LEFT JOIN market, with no flagged_for_review or is_active
predicate on the pursuit-reading queries themselves).

ONE credential path: fetch_engine_market_names goes through
engine_client.call_get_markets, which shares _engine_headers with
call_run (Recalculate Pwin) -- no second, drifting way of
authenticating to the engine ever gets introduced here.

PRODUCTION GATE -- CONFIRMED CLEAR (explicit sign-off, not inferred).
The engine team's three-layer client-config migration is complete and
verified for all three real clients: cda-internal (real per-client SSM
key + real 6-market list confirmed live), collins-aerospace (real key
+ real 5-market list confirmed live, and the sync job's actual create/
flag behavior demonstrated live -- it correctly added the 2 markets
DEMO's local table was missing and left the other 3 untouched).
empower-ai's real engine-side config was NOT independently verified
against this job -- cpde-web has no client row representing that
tenant yet, so there has never been anything for this job to sync it
against. That is a missing-tenant gap, not a config or credential gap;
close it by giving empower-ai a real client row (with its own real
engine_client_code/engine_secret_ref) whenever that tenant is actually
onboarded to cpde-web, not by adding a placeholder row for this job's
sake.

Driven by MARKET_SYNC_ENABLED (see main.py's startup hook for the full
story) -- already true in docker-compose.yml for local dev, which is
also, for now, the only place this runs at all (no separate cpde-web
production deployment exists yet; cpdeWebTaskRole is provisioned but
inert). Whoever builds that deployment should set
MARKET_SYNC_ENABLED=true in its env config from day one.
"""
from __future__ import annotations

import asyncio
import logging
import os
import re

from . import engine_client
from .db import fetch_all, tenant_tx, unscoped_tx

logger = logging.getLogger("market_sync")

# A few minutes is plenty for a POC-scale, low-traffic background sync --
# markets do not change often, and this is not latency-sensitive for any
# user-facing request. Overridable for tests/manual runs.
DEFAULT_INTERVAL_SECONDS = int(os.environ.get("MARKET_SYNC_INTERVAL_SECONDS", 900))


def _generate_code(name: str, existing_codes: set[str]) -> str:
    """Slugify a market name into a code, matching the existing seed
    convention (e.g. "OCS - General" -> OCS_GENERAL, see ddl/03_seed.sql's
    real data): uppercase, non-alphanumeric runs collapsed to a single
    underscore, trimmed. A numeric suffix is appended only on collision
    within the same client -- two different engine names should never
    silently share one local code."""
    base = re.sub(r"[^A-Z0-9]+", "_", name.strip().upper()).strip("_") or "MARKET"
    code = base
    n = 2
    while code in existing_codes:
        code = f"{base}_{n}"
        n += 1
    return code


def apply_market_sync(cur, client_id, engine_market_names: list[str]) -> dict:
    """The pure DB-application half of a sync: given the engine's
    current list of market names for this client, create what's
    missing and flag what's locally present but no longer reported.
    Never deletes, never touches is_active, never renames in place
    (see this module's own docstring for why a rename can't be
    detected).

    Runs entirely within the CALLER's transaction -- this function
    itself has no commit/rollback of its own. All-or-nothing for a
    client comes from how sync_client_markets wraps this in
    tenant_tx() and lets a raised exception roll the whole thing back,
    not from anything here.

    Returns {"created": [...], "flagged": [...], "unflagged": [...]}
    -- names only, for logging and the run record. "unflagged" is a
    market that was previously flagged and has reappeared in the
    engine's response: treated exactly like any other still-present
    market (never re-flagged), but surfaced separately so a resurfaced
    market is visible in the log, not silently indistinguishable from
    "was always present"."""
    engine_names = {n.strip() for n in engine_market_names if n and n.strip()}

    local = fetch_all(cur, """
        SELECT id, code, name, flagged_for_review FROM market
         WHERE client_id = %s""", (client_id,))
    local_by_name = {m["name"]: m for m in local}
    existing_codes = {m["code"] for m in local}

    created, flagged, unflagged = [], [], []

    for name in sorted(engine_names):
        m = local_by_name.get(name)
        if m is not None:
            if m["flagged_for_review"]:
                cur.execute("""
                    UPDATE market SET flagged_for_review = false,
                           flagged_at = NULL, flagged_reason = NULL
                     WHERE id = %s""", (m["id"],))
                unflagged.append(name)
            continue
        code = _generate_code(name, existing_codes)
        existing_codes.add(code)
        cur.execute("""
            INSERT INTO market (client_id, code, name, is_active)
            VALUES (%s, %s, %s, true)""", (client_id, code, name))
        created.append(name)

    for name, m in local_by_name.items():
        if name not in engine_names and not m["flagged_for_review"]:
            cur.execute("""
                UPDATE market
                   SET flagged_for_review = true, flagged_at = now(),
                       flagged_reason = 'not present in latest engine sync'
                 WHERE id = %s""", (m["id"],))
            flagged.append(name)

    return {"created": sorted(created), "flagged": sorted(flagged),
           "unflagged": sorted(unflagged)}


async def fetch_engine_market_names(client_row: dict) -> list[str]:
    """GET /v1/markets for one client, via engine_client's shared
    resolution path. Raises on failure -- see call_get_markets."""
    return await engine_client.call_get_markets(client_row)


async def sync_client_markets(client_row: dict) -> dict:
    """One client's full sync.

    ALL-OR-NOTHING: the engine fetch happens OUTSIDE any transaction,
    so a fetch failure (engine unreachable, key resolution fails, a
    non-2xx response) touches no DB state at all -- not even a
    'running' row is left behind, since nothing is written until the
    fetch has already succeeded. The DB-apply half runs inside exactly
    ONE tenant_tx transaction; if apply_market_sync (or anything else
    in that block) raises, the whole transaction rolls back and the
    market_sync_run row is never committed either -- no partial writes,
    no orphaned 'running' rows.
    """
    client_id, client_code = client_row["id"], client_row["code"]
    try:
        names = await fetch_engine_market_names(client_row)
    except Exception as exc:
        logger.error("market sync FAILED for %s: could not fetch engine "
                    "markets: %s", client_code, exc)
        with tenant_tx(client_id) as cur:
            cur.execute("""
                INSERT INTO market_sync_run
                    (client_id, finished_at, status, error_message)
                VALUES (%s, now(), 'failed', %s)""",
                (client_id, str(exc)))
        return {"client": client_code, "status": "failed", "error": str(exc)}

    with tenant_tx(client_id) as cur:
        result = apply_market_sync(cur, client_id, names)
        cur.execute("""
            INSERT INTO market_sync_run
                (client_id, finished_at, status,
                 created_names, flagged_names, unflagged_names)
            VALUES (%s, now(), 'succeeded', %s, %s, %s)""",
            (client_id, result["created"], result["flagged"], result["unflagged"]))

    logger.info(
        "market sync OK for %s: %d created %s | %d flagged %s | %d resurfaced %s",
        client_code, len(result["created"]), result["created"],
        len(result["flagged"]), result["flagged"],
        len(result["unflagged"]), result["unflagged"])
    return {"client": client_code, "status": "succeeded", **result}


async def sync_all_clients() -> list[dict]:
    """Every active client, one at a time. One client's failure never
    stops the others -- sync_client_markets already contains its own
    fetch failure, and this also guards against any other exception a
    single client's sync might raise."""
    with unscoped_tx() as cur:
        clients = fetch_all(cur, "SELECT * FROM fn_list_active_clients()")

    results = []
    for client_row in clients:
        try:
            results.append(await sync_client_markets(client_row))
        except Exception as exc:
            logger.error("market sync FAILED for %s: unexpected error: %s",
                        client_row.get("code"), exc, exc_info=True)
            results.append({"client": client_row.get("code"),
                            "status": "failed", "error": str(exc)})
    return results


async def market_sync_loop(interval_seconds: int = DEFAULT_INTERVAL_SECONDS) -> None:
    """Runs sync_all_clients on a fixed interval, forever, until
    cancelled. Started from main.py's startup hook, gated by
    MARKET_SYNC_ENABLED -- see this module's own docstring for the
    production hold."""
    logger.info("market sync loop starting (every %ds)", interval_seconds)
    while True:
        try:
            await sync_all_clients()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.error("market sync loop: unhandled error", exc_info=True)
        await asyncio.sleep(interval_seconds)
