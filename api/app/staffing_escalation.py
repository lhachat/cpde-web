"""
Labor cost escalation -- ported from
cda_engine/models/staffing/staffing_escalation.py and staffing_config.py.

The same B&P dollar budget buys fewer hours as labor rates rise, so
variable-category FTE in an out year is divided by the cumulative
escalation factor since the base year. Static categories
(labor_category.is_static) are exempt -- their own cost basis does not
inflate the same way.

resolve_escalation_rate's priority order matches the engine exactly:
    1. Client-provided rate for that exact year.
    2. Generic fallback rate for that exact year.
    3. Rate for the most recent year <= requested year (flat hold).
    4. Rate for the earliest known year (if year precedes all known rates).
"""
from __future__ import annotations

ESCALATION_BASE_YEAR = 2026

GENERIC_ESCALATION_RATES: dict[int, float] = {
    2026: 0.0283,
    2027: 0.054,
    2028: 0.0265,
    2029: 0.0196,
    2030: 0.0193,
    2031: 0.0203,
}


def resolve_escalation_rate(year: int, client_rates: dict[int, float] | None) -> float:
    rates = dict(GENERIC_ESCALATION_RATES)
    if client_rates:
        rates.update({k: v for k, v in client_rates.items() if v is not None})

    if year in rates:
        return rates[year]

    available_years = sorted(y for y in rates if y <= year)
    if available_years:
        return rates[available_years[-1]]

    return rates[min(rates)]


def compute_cumulative_escalation_factor(
    target_year: int,
    client_rates: dict[int, float] | None,
    base_year: int = ESCALATION_BASE_YEAR,
) -> float:
    """Compound escalation from base_year up to (but not including)
    target_year. 1.0 when target_year <= base_year."""
    if target_year <= base_year:
        return 1.0
    factor = 1.0
    for yr in range(base_year, target_year):
        factor *= 1.0 + resolve_escalation_rate(yr, client_rates)
    return factor


def apply_escalation_to_fte(
    base_fte: float,
    target_year: int,
    client_rates: dict[int, float] | None,
    base_year: int = ESCALATION_BASE_YEAR,
) -> float:
    """Divide base_fte by the cumulative escalation factor for target_year.
    Unchanged when factor <= 0 or target_year <= base_year."""
    factor = compute_cumulative_escalation_factor(target_year, client_rates, base_year)
    if factor <= 0:
        return base_fte
    return base_fte / factor
