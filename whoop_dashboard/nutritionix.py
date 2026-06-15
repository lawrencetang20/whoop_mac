"""Nutritionix natural-language food lookup.

Turns a plain-English phrase ("2 eggs and a slice of toast") into per-food calorie +
macro estimates via Nutritionix's free Natural Language endpoint. This is the
MyFitnessPal-style experience without MyFitnessPal's closed API.

Used by the dashboard's "log food" box: we parse the phrase here, the user confirms,
then the items are saved to the local food_log. Optional — manual entry works without
any API key. See config.NUTRITIONIX_* and README for getting a free key.
"""

from __future__ import annotations

import httpx

from . import config

NATURAL_URL = "https://trackapi.nutritionix.com/v2/natural/nutrients"


class NutritionixError(RuntimeError):
    """Raised when lookup can't be performed (not configured, or the API failed)."""


def _round(v, ndigits=0):
    if v is None:
        return None
    return round(v, ndigits) if ndigits else round(v)


def lookup(query: str) -> list[dict]:
    """Parse a food phrase into a list of items with calories + macros.

    Each item: {name, serving, calories, protein_g, carbs_g, fat_g, source}.
    Raises NutritionixError if keys are missing or the request fails."""
    query = (query or "").strip()
    if not query:
        return []
    if not config.nutritionix_configured():
        raise NutritionixError(
            "Nutritionix API keys not set. Add NUTRITIONIX_APP_ID / NUTRITIONIX_APP_KEY "
            "to .env to look up calories automatically, or enter calories manually."
        )

    headers = {
        "x-app-id": config.NUTRITIONIX_APP_ID,
        "x-app-key": config.NUTRITIONIX_APP_KEY,
        "Content-Type": "application/json",
    }
    try:
        with httpx.Client(timeout=15) as client:
            resp = client.post(NATURAL_URL, json={"query": query}, headers=headers)
    except httpx.HTTPError as e:
        raise NutritionixError(f"Could not reach Nutritionix: {e}") from e

    if resp.status_code == 401:
        raise NutritionixError("Nutritionix rejected the API keys (check NUTRITIONIX_APP_ID/KEY).")
    if resp.status_code == 404:
        raise NutritionixError(f"Nutritionix didn't recognize any food in “{query}”.")
    if resp.status_code != 200:
        raise NutritionixError(f"Nutritionix error {resp.status_code}.")

    foods = resp.json().get("foods", []) or []
    items = []
    for f in foods:
        qty = f.get("serving_qty")
        unit = f.get("serving_unit")
        grams = f.get("serving_weight_grams")
        serving = " ".join(str(x) for x in (qty, unit) if x is not None)
        if grams:
            serving = f"{serving} ({_round(grams)} g)".strip()
        items.append({
            "name": (f.get("food_name") or "food").title(),
            "serving": serving or None,
            "calories": _round(f.get("nf_calories")),
            "protein_g": _round(f.get("nf_protein")),
            "carbs_g": _round(f.get("nf_total_carbohydrate")),
            "fat_g": _round(f.get("nf_total_fat")),
            "source": "nutritionix",
        })
    return items
