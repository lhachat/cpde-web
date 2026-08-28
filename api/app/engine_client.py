"""
HTTP client for the CDA Pwin engine's POST /v1/run.

Boundary: this app computes tech/mgmt/pp/price/cprice and fee itself
(scoring.py, fee.py -- not protected IP, see the notes there). The
engine's tournament solve (client scores + synthetic competitors -> Pwin)
IS the protected asset; this module's only job is to POST already-
computed inputs and report back exactly what the engine says, including
a solver failure -- never invent or paper over one.

LOCAL DEV: client.engine_base_url in the database is the real production
URL (https://api.cda-us.com). CPDE_ENGINE_URL overrides it -- docker-
compose points it at the cda-engine-local container for local dev.

No AWS SSM/IAM secret resolution exists in this environment yet.
CPDE_ENGINE_API_KEY, if set, is sent as x-api-key; if unset, no key is
sent at all. That is not a bypass invented here -- runtime/api.py's own
docstring documents this as the engine's normal behavior for an
unresolved client ("the default engine config is used transparently").
Wiring real per-client SSM secret resolution is separate follow-up work,
not something to fake here.
"""
from __future__ import annotations

import os

import httpx


def resolve_engine_url(client_row: dict) -> str:
    return os.environ.get("CPDE_ENGINE_URL") or client_row["engine_base_url"]


def resolve_engine_api_key() -> str | None:
    return os.environ.get("CPDE_ENGINE_API_KEY") or None


async def call_run(client_row: dict, payload: dict) -> dict:
    """POST /v1/run. Raises on transport failure (connection refused,
    timeout, non-2xx) -- the caller decides how to surface that; this
    function never swallows an error into a fabricated result."""
    url = resolve_engine_url(client_row).rstrip("/") + "/v1/run"
    headers = {}
    key = resolve_engine_api_key()
    if key:
        headers["x-api-key"] = key
    if client_row.get("engine_client_code"):
        headers["x-cda-client-id"] = client_row["engine_client_code"]
    async with httpx.AsyncClient(timeout=20) as http:
        r = await http.post(url, json=payload, headers=headers)
        r.raise_for_status()
        return r.json()
