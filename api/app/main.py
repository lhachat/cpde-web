"""
CPDE web API.

Run locally:
    pip install -r requirements.txt
    uvicorn app.main:app --reload --port 8000

Then open http://localhost:8000/docs
"""
from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .auth import (DEV_LOGIN_ENABLED, SESSION_COOKIE, Principal,
                   create_session, current_principal, destroy_session,
                   lookup_user)
from . import scoring
from .db import close_pool, pool
from .market_sync import market_sync_loop
from .routers import bhptw, bootstrap, portfolio, recalc, staffing, write

# Nothing in this app configured logging before market_sync.py existed --
# every logger.info/error call was silently dropped by the root logger's
# default WARNING level. INFO here so a background job's run summary
# actually reaches `docker logs`, not just uvicorn's own access log.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("cpde")

app = FastAPI(title="CPDE API", version="0.4.0")

# Locked to the local dev origin. allow_credentials with a wildcard origin is
# rejected by browsers and would be wrong anyway -- the session cookie must
# only travel to known origins.
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.environ.get(
        "CPDE_ORIGINS", "http://localhost:5173,http://localhost:8000").split(","),
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["Content-Type"],
)

app.include_router(portfolio.router)
app.include_router(staffing.router)
app.include_router(bootstrap.router)
app.include_router(write.router)
app.include_router(bhptw.router)
app.include_router(recalc.router)


_market_sync_task: asyncio.Task | None = None
_scoring_refresh_task: asyncio.Task | None = None


@app.on_event("startup")
async def _startup() -> None:
    global _market_sync_task, _scoring_refresh_task
    pool()

    # AWAITED, not fire-and-forget -- the scoring table must be loaded
    # before the first real Recalculate Pwin request needs it, not
    # racing a background task. If the engine is unreachable right now,
    # startup_refresh() logs loudly and leaves the cache empty rather
    # than raising here -- the rest of the app (staffing, portfolio
    # browsing, anything not touching recalculation) must still be able
    # to start and serve requests; only recalculation itself fails
    # (loudly, via ScoringTableError) until a later refresh succeeds.
    await scoring.startup_refresh()
    _scoring_refresh_task = asyncio.create_task(scoring.refresh_loop())

    # OFF by default IN THIS CODE, deliberately -- but that default was
    # for the gate that used to exist here (blocked on the engine
    # team's three-layer client-config migration). That gate is now
    # CONFIRMED CLEAR for all three real clients (cda-internal,
    # collins-aerospace, empower-ai) -- see market_sync.py's own
    # docstring for the verification history. docker-compose.yml
    # already sets MARKET_SYNC_ENABLED=true for local dev.
    #
    # THERE IS NO SEPARATE PRODUCTION DEPLOYMENT YET (cpdeWebTaskRole
    # exists but is inert, no ECS task attached). Whoever builds that
    # deployment: set MARKET_SYNC_ENABLED=true in its env config FROM
    # DAY ONE. The code-level default here stays "false" only so a
    # future environment that forgets to set ANY value fails safe
    # (disabled, not silently syncing) rather than fails open --
    # that is not the same thing as "off is the intended production
    # state". Do not treat this default as something that still needs
    # deciding; it was already decided and is documented here so it
    # does not need rediscovering as a gap.
    if os.environ.get("MARKET_SYNC_ENABLED", "false").lower() == "true":
        _market_sync_task = asyncio.create_task(market_sync_loop())
    else:
        logger.info("market sync disabled (MARKET_SYNC_ENABLED not set)")


@app.on_event("shutdown")
def _shutdown() -> None:
    if _market_sync_task is not None:
        _market_sync_task.cancel()
    if _scoring_refresh_task is not None:
        _scoring_refresh_task.cancel()
    close_pool()


# Serve the UI from the API origin. Same-origin means the session cookie is
# sent without CORS negotiation, and there is no second server to run.
_UI = Path(__file__).resolve().parent.parent / "static"
if _UI.is_dir():
    app.mount("/static", StaticFiles(directory=str(_UI)), name="static")

    @app.get("/", include_in_schema=False)
    def index():
        return FileResponse(str(_UI / "index.html"))


@app.get("/health")
def health():
    return {"status": "ok"}


class LoginRequest(BaseModel):
    # Deliberately NOT EmailStr: it rejects reserved TLDs like .test and
    # applies deliverability rules that reject valid corporate addresses.
    # Format is not an auth control -- the lookup is.
    email: str = Field(min_length=3, max_length=254)


@app.post("/api/login")
def login(body: LoginRequest, response: Response):
    """DEV LOGIN. No password -- this is a local stub.

    Note what it does NOT accept: a client_id. The tenant is derived from the
    user record, server-side. Production swaps this for an IdP redirect and
    nothing downstream changes.
    """
    if not DEV_LOGIN_ENABLED:
        raise HTTPException(status.HTTP_404_NOT_FOUND)
    principal = lookup_user(body.email)
    if principal is None:
        # Same message for unknown user and inactive user.
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid login")
    token = create_session(principal)
    response.set_cookie(
        SESSION_COOKIE, token,
        httponly=True,      # not readable from JavaScript
        samesite="lax",     # not sent on cross-site POSTs
        secure=os.environ.get("CPDE_SECURE_COOKIE", "0") == "1",
        max_age=8 * 3600,
        path="/",
    )
    return {"email": principal.email, "client_code": principal.client_code,
            "display_name": principal.display_name,
            "roles": list(principal.roles)}


@app.post("/api/logout")
def logout(response: Response,
           p: Principal = Depends(current_principal),
           ):
    response.delete_cookie(SESSION_COOKIE, path="/")
    return {"ok": True}
