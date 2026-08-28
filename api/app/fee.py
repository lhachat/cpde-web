"""
Shared fee resolution: fee = contract_type.base_fee_rate + the chosen P1
option's price_delta. Not protected IP (see ddl/13_bhptw_fee.sql). Used by
both the Black Hat endpoint and the questionnaire Recalculate-Pwin
endpoint so the two computations can never drift apart.
"""
from __future__ import annotations

from fastapi import HTTPException, status

from .db import fetch_one


def resolve_fee(cur, contract_type_id, p1_option_id):
    """fee for one (contract_type, P1 option) pair.

    Raises HTTPException(400) if either side of the config is NULL --
    refuses to guess rather than silently compute a wrong fee.
    """
    row = fetch_one(cur, """
        SELECT ct.base_fee_rate, o.price_delta
          FROM contract_type ct, question_option o
         WHERE ct.id = %s AND o.id = %s""", (contract_type_id, p1_option_id))
    if not row or row["base_fee_rate"] is None or row["price_delta"] is None:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "Fee configuration is incomplete for this contract type or "
            "price option -- ask an administrator to set it before fee "
            "can be computed.")
    return row["base_fee_rate"] + row["price_delta"]
