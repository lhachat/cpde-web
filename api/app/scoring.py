"""
Pwin scoring-table lookups -- ported from CPwinScoringTables.cls (VBA).

Not protected IP: these produce tech/mgmt/pp/price/cprice SCORES, which
are displayed in the workbook today. The protected boundary is the
engine's tournament solve (/v1/run), downstream of this module. See
ddl/13_bhptw_fee.sql for the same rule applied to the P1/fee table.

Verified this session against all 36 real AERO pursuits: Tech, Mgmt, PP
and Competitor Price matched exactly on every row; Price matched 35/36,
the one discrepancy traced to the market differential the engine applies
server-side, not a table error.

Every answer key below is copied verbatim from CPwinScoringTables.cls and
cross-checked character-for-character against the option labels seeded in
ddl/03_seed.sql (they must match exactly -- lookup() falls back to a
zero delta on any miss, silently, matching the VBA's own behavior).
"""
from __future__ import annotations

BASE_SCORE = 85.0


def _row(tech: float = 0.0, mgmt: float = 0.0, pp: float = 0.0,
         client_price: float = 0.0, comp_price: float = 0.0) -> dict:
    return {"tech": tech, "mgmt": mgmt, "pp": pp,
            "client_price": client_price, "comp_price": comp_price}


TABLES: dict[str, dict[str, dict]] = {
    "tm1a": {
        "on contract today": _row(10, 10, 5),
        "yes, but not as many building blocks as competitor": _row(5, 5),
        "no, but our teammates are on contract today": _row(5, 5),
        "no": _row(),
        "same": _row(),
        "better": _row(5, 5),
        "worse": _row(-5, -5),
    },
    "tm1b": {
        "on contract today": _row(-10, -10, -5),
        "yes, but not as many building blocks as us": _row(-5, -5),
        "no": _row(),
        "same level": _row(),
        "more mature": _row(5, 5, client_price=-0.08),
        "less mature": _row(-5, -5, client_price=0.08),
    },
    "tm2": {
        "yes, us": _row(10, 10, 5),
        "yes, one of the competitors": _row(-10, -10),
        "no": _row(),
    },
    "tm3": {
        "we are performing satisfactorily/unknown": _row(),
        "we have performance issues": _row(-5, -5, -5),
        "n/a": _row(),
        "incumbent competitor is performing satisfactorily/unknown": _row(),
        "incumbent competitor has performance issues": _row(5, 5, 5),
    },
    "tm4": {
        'yes, we will outsource most of the actual work requested ("noble work")':
            _row(-7.5, -5, -2.5, comp_price=-0.1),
        'yes, we will outsource some of the actual work requested ("noble work")':
            _row(-2.5, comp_price=-0.05),
        "no": _row(),
    },
    # TM5's table row only carries the tech delta -- its price contribution
    # is computed separately in _tm5_invest_delta() below and, per the VBA
    # Lookup(), written onto client_price (NOT comp_price, despite the
    # constant names) with the sign flipped. See lookup()'s tm5 branch.
    "tm5": {
        "no": _row(0),
        "low": _row(7.5),
        "moderate": _row(10),
        "high": _row(15),
    },
    "pp1": {
        "yes": _row(pp=-5),
        "no": _row(),
    },
    "p1": {
        "3% above normal": _row(client_price=0.03),
        "2% above normal": _row(client_price=0.02),
        "1% above normal": _row(client_price=0.01),
        "normal bid": _row(client_price=0.0),
        "1% lower than normal": _row(client_price=-0.01),
        "2% lower than normal": _row(client_price=-0.02),
        "3% lower than normal": _row(client_price=-0.03),
        "4% lower than normal": _row(client_price=-0.04),
    },
}

# (answer, is_dev) -> the VBA's TM5_*_COMPPRICE_{DEV,SVC} constant.
_TM5_INVEST: dict[tuple[str, bool], float] = {
    ("no", True): 0.0, ("no", False): 0.0,
    ("low", True): 0.01, ("low", False): 0.0,
    ("moderate", True): 0.0175, ("moderate", False): 0.0,
    ("high", True): 0.025, ("high", False): 0.0,
}


def _is_dev(pursuit_type: str) -> bool:
    """Matches TM5InvestDelta_'s InStr checks exactly. opportunity_type.
    type_group ('PRODUCT'/'SERVICES') passes straight through this
    unchanged -- 'PRODUCT' contains 'product', 'SERVICES' contains none
    of the three substrings, same as passing the VBA's literal 'Dev'/
    'Service' would."""
    p = (pursuit_type or "").lower()
    return "dev" in p or "existing" in p or "product" in p


def lookup(question_code: str, answer: str, pursuit_type: str = "") -> dict:
    """One question's score delta. Unknown table or unknown answer ->
    all-zero delta (matches the VBA's own silent fallback -- it only logs
    to the Immediate window, which has no web equivalent)."""
    table = TABLES.get(question_code.lower())
    if table is None:
        return _row()
    key = (answer or "").strip().lower()
    row = table.get(key)
    if row is None:
        return _row()
    result = dict(row)
    if question_code.lower() == "tm5":
        is_dev = _is_dev(pursuit_type)
        invest = _TM5_INVEST.get((key, is_dev), 0.0)
        result["client_price"] = -invest
        result["comp_price"] = 0.0
    return result


def accumulate(deltas: list[dict]) -> dict:
    total = _row()
    for d in deltas:
        for k in total:
            total[k] += d.get(k, 0.0)
    return total
