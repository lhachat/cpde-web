"""
Shared fee resolution: fee = contract_type's nominal rate + the chosen
P1 option's price_delta. Not protected IP (see ddl/13_bhptw_fee.sql).
Used by both the Black Hat endpoint and the questionnaire Recalculate-
Pwin endpoint so the two computations can never drift apart.

Both halves now come from the engine's live GET /v1/scoring-tables
(scoring.py's fetch/cache) -- engine v0.29+. This retired a real,
three-deep duplication of the same fee data: an old hardcoded
scoring.py copy (removed in the prior scoring migration), a DB-seeded
copy (contract_type.base_fee_rate + question_option.price_delta,
ddl/13_bhptw_fee.sql -- now deprecated, see that file), and this live
table. The P1 delta specifically reuses the SAME p1 table scoring.py
already fetches for Pwin computation (scoring.lookup("p1", ...)), not
a second copy of it.
"""
from __future__ import annotations

from fastapi import HTTPException, status

from . import scoring
from .db import fetch_one


def resolve_fee(cur, contract_type_id, p1_option_id):
    """fee for one (contract_type, P1 option) pair, sourced from the
    live-fetched scoring/fee tables, not a DB-seeded copy.

    Raises HTTPException(400) if either id doesn't resolve to a real
    row, or if the resolved contract type has no matching entry in the
    live fee-rate table (refuses to guess, same discipline the old
    DB-seeded NULL check had). Raises HTTPException(502) if the fee/
    scoring tables themselves haven't been loaded from the engine at
    all -- distinct from "loaded, but this contract type isn't in it".
    """
    row = fetch_one(cur, """
        SELECT ct.label AS contract_label, o.label_text AS p1_label
          FROM contract_type ct, question_option o
         WHERE ct.id = %s AND o.id = %s""", (contract_type_id, p1_option_id))
    if not row:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "Fee configuration is incomplete for this contract type or "
            "price option -- ask an administrator to set it before fee "
            "can be computed.")

    try:
        base_rate = scoring.fee_rate_for_label(row["contract_label"])
        price_delta = scoring.lookup("p1", row["p1_label"])["client_price"]
    except scoring.ScoringTableError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc))

    if base_rate is None:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "Fee configuration is incomplete for this contract type -- "
            "ask an administrator to set it before fee can be computed.")
    return base_rate + price_delta
