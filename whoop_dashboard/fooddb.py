"""Local 'common foods' database from USDA FoodData Central (SR Legacy).

Public-domain reference data (no API key) so you can search foods and get calories +
macros offline — no Nutritionix needed. Run once:

    python -m whoop_dashboard build-food-db

It downloads ~6 MB, parses per-100 g nutrients (+ a typical serving size), and fills the
local `foods` table (~7,800 common whole foods). Search is then served from /api/food/search.
"""

from __future__ import annotations

import csv
import io
import os
import zipfile

import httpx

from . import store

SR_LEGACY_URL = (
    "https://fdc.nal.usda.gov/fdc-datasets/"
    "FoodData_Central_sr_legacy_food_csv_2018-04.zip"
)
# USDA nutrient numbers (stable across dataset versions) -> our macro keys. Amounts are per 100 g.
_MACRO_NBR = {"208": "kcal", "203": "protein", "205": "carb", "204": "fat"}


def build(progress=None) -> int:
    """Download + parse SR Legacy and replace the local `foods` table. Returns the count."""
    def note(m):
        if progress:
            progress(m)

    note("Downloading USDA SR Legacy food data (~6 MB)…")
    # httpx (vs urllib) so SSL verification uses certifi's CA bundle — the framework
    # Python on macOS otherwise fails with CERTIFICATE_VERIFY_FAILED.
    resp = httpx.get(SR_LEGACY_URL, timeout=180, follow_redirects=True)
    resp.raise_for_status()
    zf = zipfile.ZipFile(io.BytesIO(resp.content))

    def rows_of(basename):
        # The CSVs sit under a top-level folder; match by exact file name so
        # "nutrient.csv" never picks up "food_nutrient.csv".
        name = next(n for n in zf.namelist() if os.path.basename(n) == basename)
        return csv.DictReader(io.TextIOWrapper(zf.open(name), encoding="utf-8-sig"))

    note("Parsing nutrients…")
    nid_key = {}  # nutrient_id -> macro key (derived from the stable nutrient_nbr)
    for r in rows_of("nutrient.csv"):
        key = _MACRO_NBR.get((r.get("nutrient_nbr") or "").strip())
        if key:
            nid_key[(r.get("id") or "").strip()] = key

    names = {}  # fdc_id -> description
    for r in rows_of("food.csv"):
        fid = (r.get("fdc_id") or "").strip()
        desc = (r.get("description") or "").strip()
        if fid and desc:
            names[fid] = desc

    macros = {}  # fdc_id -> {kcal, protein, carb, fat}
    for r in rows_of("food_nutrient.csv"):
        key = nid_key.get((r.get("nutrient_id") or "").strip())
        if not key:
            continue
        fid = (r.get("fdc_id") or "").strip()
        if fid not in names:
            continue
        try:
            macros.setdefault(fid, {})[key] = float(r.get("amount") or 0)
        except ValueError:
            pass

    note("Parsing serving sizes…")
    serving = {}  # fdc_id -> grams of a typical portion (first listed with a weight)
    for r in rows_of("food_portion.csv"):
        fid = (r.get("fdc_id") or "").strip()
        if fid not in names or fid in serving:
            continue
        try:
            g = float(r.get("gram_weight") or 0)
        except ValueError:
            continue
        if g > 0:
            serving[fid] = round(g, 1)

    out = []
    for fid, name in names.items():
        m = macros.get(fid)
        if not m or m.get("kcal") is None:  # require at least calories
            continue
        out.append((int(fid), name, m.get("kcal"), m.get("protein"),
                    m.get("carb"), m.get("fat"), serving.get(fid)))

    note(f"Saving {len(out)} foods…")
    store.replace_foods(out)
    return len(out)
