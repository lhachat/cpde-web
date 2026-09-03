"""
Pwin scoring-table lookups -- fetched LIVE from the engine's
GET /v1/scoring-tables (engine v0.28+), not a hardcoded local copy.

WHY THE MIGRATION: cpde-web previously hardcoded its own copy of this
table (ported from CPwinScoringTables.cls, the original VBA). Verified
correct against every real AERO pursuit this session -- this migration
is preventive, not corrective: closing a standing drift risk (the
engine's table could be corrected or extended with no signal cpde-web's
own copy had gone stale), not fixing an active bug.

FEE RATES (engine v0.29+): the same GET /v1/scoring-tables response
also carries fee_rates -- {contract_type_label: nominal_rate} -- folded
in alongside tables/base_score, same fetch/cache, no second call. This
retired a real, previously three-deep duplication of the same fee data
(the old hardcoded scoring.py table now removed; a DB-seeded
contract_type.base_fee_rate + question_option.price_delta pair,
ddl/13_bhptw_fee.sql, now deprecated -- see that file's own updated
note; and this live table, now the one source of truth). fee.py
(resolve_fee) consumes fee_rate_for_label() for the contract-type side
and lookup("p1", ...) for the P1 delta -- the SAME p1 table this module
already fetches for Pwin scoring, not a separate copy.

CACHING: fetched once at API startup (main.py's startup hook awaits
refresh() before serving any request) and refreshed on a long interval
(CACHE_TTL_SECONDS, default 1 hour) as a background safety net against
a long-running process missing an engine update -- NOT the primary
mechanism. An hour is deliberately generous: this data only changes on
an engine deploy, far less often than per-client keys (5 min,
engine_client.py) or market lists (15 min, market_sync.py); a real
table correction is still picked up within the same working day without
needing a restart.

NO FALLBACK ON FAILURE. If the engine cannot be reached at startup or
refresh, the cache stays exactly as it was (empty, or the last good
value) and refresh() raises ScoringTableError loudly rather than
serving a stale-but-silent value; lookup() raises the SAME error if no
fetch has ever succeeded. Recalculation must fail cleanly at that
point, never produce a quietly wrong Pwin.

TM5's shape from the engine already bakes in the dev/service split this
module used to compute itself (a local _TM5_INVEST table, keyed by
(answer, is_dev), with a sign-flipped client_price) -- the engine now
returns tables.tm5.dev / tables.tm5.service, each a fully-formed row
per answer, confirmed by reading the live response directly. Only the
DECISION of which branch applies (from the pursuit's type_group) stays
local; the numbers themselves no longer do.
"""
from __future__ import annotations

import asyncio
import logging
import time

from . import engine_client
from .db import fetch_all, unscoped_tx

logger = logging.getLogger("scoring")

# See module docstring for the reasoning -- generous on purpose, this
# is a background safety net, not the primary refresh mechanism.
CACHE_TTL_SECONDS = 3600


class ScoringTableError(RuntimeError):
    """Could not fetch/refresh the scoring table from the engine, or
    lookup() was called before any fetch ever succeeded. Distinct from
    an engine COMPUTE failure (/v1/run itself failing) -- this means
    recalculation cannot even start, because there is nothing to score
    with."""


_ZERO_ROW = {"tech": 0.0, "mgmt": 0.0, "pp": 0.0,
            "client_price": 0.0, "comp_price": 0.0}

# {question_code: {answer_lower: row}}, except "tm5":
# {"dev"|"service": {answer_lower: row}} -- see module docstring.
_tables: dict | None = None
BASE_SCORE: float | None = None
# {contract_type_label_lower: rate} -- Black Hat/Recalculate fee's
# nominal rate table, engine v0.29+, folded into this SAME response
# (see fee_rate_for_label() and fee.py). Fetched/cached together with
# _tables/BASE_SCORE -- one response, one refresh, never partially
# updated relative to each other.
_fee_rates: dict | None = None
_last_fetched: float = 0.0


def _normalize(table: dict) -> dict:
    return {k.strip().lower(): v for k, v in table.items()}


async def refresh(client_row: dict) -> None:
    """Fetch the current scoring table from the engine and populate the
    in-process cache. Raises ScoringTableError on failure and leaves
    whatever was cached before UNCHANGED -- a failed refresh never wipes
    out a previously-good table, and never partially updates it."""
    global _tables, BASE_SCORE, _fee_rates, _last_fetched
    try:
        data = await engine_client.call_get_scoring_tables(client_row)
    except Exception as exc:
        raise ScoringTableError(
            f"could not fetch scoring tables from the engine: {exc}") from exc

    raw_tables = data["tables"]
    normalized = {}
    for code, table in raw_tables.items():
        if code == "tm5":
            normalized["tm5"] = {branch: _normalize(answers)
                                 for branch, answers in table.items()}
        else:
            normalized[code] = _normalize(table)

    _tables = normalized
    BASE_SCORE = data["base_score"]
    _fee_rates = _normalize(data.get("fee_rates", {}))
    _last_fetched = time.monotonic()


def is_loaded() -> bool:
    return _tables is not None


def fee_rate_for_label(contract_type_label: str) -> float | None:
    """The live-fetched nominal fee rate for a contract type label (e.g.
    "Cost Plus" -> 0.065), or None if the loaded table has no matching
    entry -- fee.py treats that as "not configured" and refuses to
    guess, same discipline the old DB-seeded column had. Raises
    ScoringTableError if no fee table has ever been successfully loaded
    at all -- distinct from "loaded, but this label isn't in it"."""
    if _fee_rates is None:
        raise ScoringTableError(
            "fee rate table has not been loaded from the engine yet -- "
            "cannot compute a fee until a fetch succeeds")
    return _fee_rates.get((contract_type_label or "").strip().lower())


def _is_dev(pursuit_type: str) -> bool:
    """Matches TM5InvestDelta_'s InStr checks exactly. opportunity_type.
    type_group ('PRODUCT'/'SERVICES') passes straight through this
    unchanged -- 'PRODUCT' contains 'product', 'SERVICES' contains none
    of the three substrings, same as passing the VBA's literal 'Dev'/
    'Service' would. Which of the engine's two pre-computed tm5 branches
    (dev/service) applies is decided here; the numbers within each
    branch come entirely from the engine now."""
    p = (pursuit_type or "").lower()
    return "dev" in p or "existing" in p or "product" in p


def lookup(question_code: str, answer: str, pursuit_type: str = "") -> dict:
    """One question's score delta. Unknown table or unknown answer ->
    all-zero delta (matches the VBA's own silent fallback -- it only
    logs to the Immediate window, which has no web equivalent).

    Raises ScoringTableError if no scoring table has ever been
    successfully loaded -- never silently returns a zero row that could
    be mistaken for a real (if unusual) answer."""
    if _tables is None:
        raise ScoringTableError(
            "scoring table has not been loaded from the engine yet -- "
            "cannot score a pursuit until a fetch succeeds")

    code = question_code.lower()
    key = (answer or "").strip().lower()
    if code == "tm5":
        branch = "dev" if _is_dev(pursuit_type) else "service"
        table = _tables.get("tm5", {}).get(branch, {})
    else:
        table = _tables.get(code, {})
    row = table.get(key)
    return dict(_ZERO_ROW) if row is None else dict(row)


def accumulate(deltas: list[dict]) -> dict:
    total = dict(_ZERO_ROW)
    for d in deltas:
        for k in total:
            total[k] += d.get(k, 0.0)
    return total


def _any_active_client(cur) -> dict | None:
    """GET /v1/scoring-tables is static and identical for every caller --
    which client's key authenticates the request is irrelevant, so this
    just takes whichever active client exists first. Reuses
    fn_list_active_clients() (market_sync.py's own cross-tenant read),
    not a new query."""
    clients = fetch_all(cur, "SELECT * FROM fn_list_active_clients()")
    return clients[0] if clients else None


async def startup_refresh() -> None:
    """Called once from main.py's startup hook, AWAITED -- the first
    real request must never race an empty cache. Does not raise on
    failure (a scoring-table outage should not prevent the rest of the
    app -- staffing, portfolio browsing, anything not touching
    recalculation -- from serving requests); logs loudly instead, and
    lookup() itself raises for whichever request actually needs a table
    that was never loaded."""
    with unscoped_tx() as cur:
        client_row = _any_active_client(cur)
    if client_row is None:
        logger.error("scoring table NOT loaded at startup: no active "
                     "client to authenticate the fetch with")
        return
    try:
        await refresh(client_row)
        logger.info("scoring table loaded at startup (base_score=%s)", BASE_SCORE)
    except ScoringTableError as exc:
        logger.error("scoring table NOT loaded at startup: %s", exc)


async def refresh_loop(interval_seconds: int = CACHE_TTL_SECONDS) -> None:
    """Background safety net -- see module docstring. Runs forever until
    cancelled; a single failed refresh is logged and does not stop the
    loop (the NEXT interval tries again), and never clears an
    already-good cache on failure."""
    while True:
        await asyncio.sleep(interval_seconds)
        try:
            with unscoped_tx() as cur:
                client_row = _any_active_client(cur)
            if client_row is None:
                logger.error("scoring table refresh skipped: no active client")
                continue
            await refresh(client_row)
            logger.info("scoring table refreshed (base_score=%s)", BASE_SCORE)
        except asyncio.CancelledError:
            raise
        except ScoringTableError as exc:
            logger.error("scoring table refresh FAILED: %s", exc)
