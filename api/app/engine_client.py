"""
HTTP client for the CDA Pwin engine: POST /v1/run and GET /v1/markets.

Boundary: this app computes tech/mgmt/pp/price/cprice and fee itself
(scoring.py, fee.py -- not protected IP, see the notes there). The
engine's tournament solve (client scores + synthetic competitors -> Pwin)
IS the protected asset; this module's only job is to POST already-
computed inputs and report back exactly what the engine says, including
a solver failure -- never invent or paper over one.

ONE credential path for every engine call, never two: call_run and
call_get_markets (used by market_sync.py) both go through
_engine_headers, which resolves the key exactly once, the same way,
regardless of which endpoint is being called.

REAL PER-CLIENT KEY RESOLUTION. client.engine_secret_ref names an SSM
SecureString parameter (/cda/clients/{client}/products/cpde-core/
key-value); boto3.client("ssm") resolves it with no explicit credential
arguments, picking up whatever the standard AWS credential chain
provides -- an assumed cpdeWebLocalDevRole session locally
(refresh-aws-creds.ps1), a real ECS task role in production. NO
code-level distinction between the two: this is the entire reason that
chain exists. IAM is scoped to exactly /cda/clients/*/products/
cpde-core/* -- this code cannot read any other product's secrets even
if it tried to.

LOCAL DEV: client.engine_base_url in the database is the real production
URL (https://api.cda-us.com). CPDE_ENGINE_URL overrides it -- docker-
compose points it at the cda-engine-local container for local dev.

Resolved keys are cached in-process for CACHE_TTL_SECONDS -- keys do not
rotate mid-session, so re-reading SSM on every single request would be
pure overhead. The cache is invalidated on a 401/403 from the engine
itself (a cached key the engine just rejected is never trusted again
for the remainder of the TTL) and, separately, simply expires after the
TTL regardless -- whichever comes first.

SSM/credential-resolution failure is raised as EngineCredentialError,
distinct from an engine-side failure (timeout, non-2xx from /v1/run
itself) -- see EngineCredentialError's own docstring. Callers must
catch it separately and surface a specific message ("could not resolve
engine credentials for client X: <reason>"), never lump it into a
generic "recalculation failed."
"""
from __future__ import annotations

import os
import time

import boto3
import httpx
from botocore.exceptions import BotoCoreError, ClientError

# A few minutes is plenty -- keys do not rotate mid-session, and this
# keeps a burst of requests for the same client from hitting SSM every
# time. Short enough that a revoked/rotated key is noticed soon.
CACHE_TTL_SECONDS = int(os.environ.get("ENGINE_KEY_CACHE_TTL_SECONDS", 300))

_ssm_client = None
# secret_ref -> (key value, cached_at monotonic seconds)
_key_cache: dict[str, tuple[str, float]] = {}


class EngineCredentialError(RuntimeError):
    """Could not resolve this client's real engine API key -- an SSM/IAM/
    credential problem, NOT an engine-side failure. Kept as a distinct
    exception type specifically so callers can tell "we could not even
    authenticate" apart from "the engine was reachable but errored",
    and say so plainly rather than folding both into one generic
    message."""


def _ssm():
    global _ssm_client
    if _ssm_client is None:
        # No explicit credentials/region kwargs -- the standard AWS
        # credential chain resolves them from the environment, exactly
        # the same way locally (an assumed role's exported session) and
        # in production (an ECS task role). Never add a code-level
        # branch here for "local" vs "production".
        _ssm_client = boto3.client("ssm")
    return _ssm_client


def _resolve_key_from_ssm(secret_ref: str) -> str:
    try:
        resp = _ssm().get_parameter(Name=secret_ref, WithDecryption=True)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "Unknown")
        message = exc.response.get("Error", {}).get("Message", str(exc))
        # ParameterNotFound (the parameter does not exist),
        # AccessDeniedException (IAM denies this path), ExpiredToken /
        # InvalidClientTokenId (local dev credentials expired -- the
        # exact case refresh-aws-creds.ps1 exists to fix) all land here,
        # each with AWS's own real reason, not a guess.
        raise EngineCredentialError(
            f"SSM parameter {secret_ref!r}: {code}: {message}") from exc
    except BotoCoreError as exc:
        # No credentials resolved at all, network unreachable, etc. --
        # a different failure class from a ClientError (AWS responded
        # and said no); this is "AWS was never reached".
        raise EngineCredentialError(
            f"SSM parameter {secret_ref!r}: {type(exc).__name__}: {exc}") from exc
    return resp["Parameter"]["Value"]


def resolve_engine_api_key_for_client(client_row: dict) -> str:
    """The real per-client engine API key, SSM-resolved and cached.
    Raises EngineCredentialError with the client code and the real
    underlying reason on any failure -- never returns an empty or fake
    key that would silently reach the engine as "no key sent"."""
    client_code = client_row.get("code") or client_row.get("engine_client_code") or "?"
    secret_ref = client_row.get("engine_secret_ref")
    if not secret_ref:
        raise EngineCredentialError(
            f"could not resolve engine credentials for client {client_code}: "
            f"no engine_secret_ref configured")

    now = time.monotonic()
    cached = _key_cache.get(secret_ref)
    if cached is not None and (now - cached[1]) < CACHE_TTL_SECONDS:
        return cached[0]

    try:
        value = _resolve_key_from_ssm(secret_ref)
    except EngineCredentialError as exc:
        raise EngineCredentialError(
            f"could not resolve engine credentials for client {client_code}: {exc}"
        ) from exc
    _key_cache[secret_ref] = (value, now)
    return value


def invalidate_engine_api_key_cache(client_row: dict) -> None:
    """Called after a 401/403 from the engine itself -- a key the engine
    just rejected must never be trusted again for the rest of the TTL.
    The next call re-reads SSM instead of repeating the same rejected
    key."""
    secret_ref = client_row.get("engine_secret_ref")
    if secret_ref:
        _key_cache.pop(secret_ref, None)


def resolve_engine_url(client_row: dict) -> str:
    return os.environ.get("CPDE_ENGINE_URL") or client_row["engine_base_url"]


def _engine_headers(client_row: dict) -> dict:
    """Headers shared by every engine call -- ONE resolution path for
    the key, reused by call_run and call_get_markets alike, so there is
    never a second, drifting way of authenticating to the engine.
    Raises EngineCredentialError before any HTTP call is attempted if
    the key cannot be resolved -- a credential failure and an engine
    failure must never be indistinguishable to the caller."""
    headers = {"x-api-key": resolve_engine_api_key_for_client(client_row)}
    if client_row.get("engine_client_code"):
        headers["x-cda-client-id"] = client_row["engine_client_code"]
    return headers


async def call_run(client_row: dict, payload: dict) -> dict:
    """POST /v1/run. Raises EngineCredentialError if the key cannot be
    resolved (before any request is sent), or httpx's own exception on
    transport failure (connection refused, timeout, non-2xx) -- the
    caller decides how to surface each; this function never swallows
    either into a fabricated result. A 401/403 specifically invalidates
    the cached key before re-raising, so a rejected key is never reused
    for the rest of its TTL."""
    url = resolve_engine_url(client_row).rstrip("/") + "/v1/run"
    headers = _engine_headers(client_row)
    async with httpx.AsyncClient(timeout=20) as http:
        r = await http.post(url, json=payload, headers=headers)
        if r.status_code in (401, 403):
            invalidate_engine_api_key_cache(client_row)
        r.raise_for_status()
        return r.json()


async def call_get_markets(client_row: dict) -> list[str]:
    """GET /v1/markets -- market display names for this client, used by
    market_sync.py. Same resolve_engine_api_key_for_client as call_run
    via _engine_headers -- no separate credential mechanism.

    Raises EngineCredentialError or httpx's own exception, same
    separation as call_run -- never returns an empty list on failure,
    which a caller could mistake for "the engine genuinely reports zero
    markets" and flag every local market as a result.

    NOTE on the engine's own response shape (read directly from
    cda_engine/runtime/api.py get_markets, not assumed): it returns
    bare display-name strings, {"markets": [...]}, with no code or id
    of any kind, and on its OWN config-resolution failure it degrades
    to a 200 with a placeholder ({"markets": ["Market 1"]}) rather than
    an error -- a real per-client key that fails to resolve on the
    engine side is therefore NOT distinguishable from a genuinely
    single-market client from cpde-web's side alone. That is an engine-
    side behavior, not something this function can compensate for."""
    url = resolve_engine_url(client_row).rstrip("/") + "/v1/markets"
    headers = _engine_headers(client_row)
    async with httpx.AsyncClient(timeout=20) as http:
        r = await http.get(url, headers=headers)
        if r.status_code in (401, 403):
            invalidate_engine_api_key_cache(client_row)
        r.raise_for_status()
        body = r.json()
        return body.get("markets", [])


async def call_get_scoring_tables(client_row: dict) -> dict:
    """GET /v1/scoring-tables -- the full TM1a-P1 scoring table, used by
    scoring.py. Static response, identical for every caller (no per-
    client resolution) -- client_row here is only for authenticating
    the request (any active client's key works equally), same shared
    credential path as every other engine call.

    Raises EngineCredentialError or httpx's own exception, same
    separation as call_run/call_get_markets -- never returns a partial
    or default table on failure."""
    url = resolve_engine_url(client_row).rstrip("/") + "/v1/scoring-tables"
    headers = _engine_headers(client_row)
    async with httpx.AsyncClient(timeout=20) as http:
        r = await http.get(url, headers=headers)
        if r.status_code in (401, 403):
            invalidate_engine_api_key_cache(client_row)
        r.raise_for_status()
        return r.json()
