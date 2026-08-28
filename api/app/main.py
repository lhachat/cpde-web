"""
CPDE web API.

Run locally:
    pip install -r requirements.txt
    uvicorn app.main:app --reload --port 8000

Then open http://localhost:8000/docs
"""
from __future__ import annotations

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
from .db import close_pool, pool
from .routers import bhptw, bootstrap, portfolio, recalc, staffing, write

app = FastAPI(title="CPDE API", version="0.2.0")

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


@app.on_event("startup")
def _startup() -> None:
    pool()


@app.on_event("shutdown")
def _shutdown() -> None:
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
