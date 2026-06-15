"""Local 'common + branded foods' database from USDA FoodData Central.

Public-domain reference data (no API key) so you can search foods offline — including
branded grocery products (e.g. "Mission Carb Balance" tortillas) — and get calories +
macros. Build once:

    python -m whoop_dashboard build-food-db

It downloads two datasets — SR Legacy (~6 MB whole foods) and Branded (~440 MB grocery
products) — and parses per-100 g nutrients + serving sizes into a SEPARATE foods.sqlite3
with an FTS5 search index (~1.9 M foods, ~1 GB on disk). Search is served from
/api/food/search. The build streams the CSVs through on-disk SQLite staging (low memory)
and is idempotent: it rebuilds foods.sqlite3 from scratch and only swaps it in on success.
"""

from __future__ import annotations

import csv
import io
import os
import sqlite3
import zipfile

import httpx

from . import config

SR_LEGACY_URL = (
    "https://fdc.nal.usda.gov/fdc-datasets/"
    "FoodData_Central_sr_legacy_food_csv_2018-04.zip"
)
BRANDED_URL = (
    "https://fdc.nal.usda.gov/fdc-datasets/"
    "FoodData_Central_branded_food_csv_2025-04-24.zip"
)
# USDA nutrient numbers -> macro key. Amounts in food_nutrient.csv are per 100 g.
_MACRO_NBR = {"208": "kcal", "203": "protein", "205": "carb", "204": "fat"}
_GRAM_UNITS = {"g", "grm", "gram", "grams"}
_BATCH = 50_000

# csv accepts very long fields (some branded ingredient lists are huge).
csv.field_size_limit(10_000_000)


def _download(url: str, dest, note) -> None:
    note(f"Downloading {os.path.basename(url)} …")
    try:
        with httpx.stream("GET", url, timeout=600, follow_redirects=True) as r:
            r.raise_for_status()
            with open(dest, "wb") as f:
                for chunk in r.iter_bytes(1 << 20):
                    f.write(chunk)
    except httpx.HTTPError as e:
        raise RuntimeError(
            f"Food DB download failed ({os.path.basename(url)}). "
            "Check your connection and re-run `python -m whoop_dashboard build-food-db`."
        ) from e


def _member(zf: zipfile.ZipFile, basename: str):
    name = next((n for n in zf.namelist() if os.path.basename(n) == basename), None)
    if name is None:
        raise RuntimeError(
            f"'{basename}' not found in the USDA archive (the dataset layout may have changed)."
        )
    return zf.open(name)


def _reader(zf, basename):
    """(csv.reader, {column_name: index}) for a member CSV — fast positional access."""
    f = io.TextIOWrapper(_member(zf, basename), encoding="utf-8-sig")
    rd = csv.reader(f)
    header = next(rd)
    return rd, {h: i for i, h in enumerate(header)}


def _num(s):
    s = (s or "").strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def _macro_ids(zf) -> dict:
    """macro key -> nutrient_id, derived from this archive's nutrient.csv."""
    rd, ix = _reader(zf, "nutrient.csv")
    ni, nbr = ix["id"], ix["nutrient_nbr"]
    out = {}
    for row in rd:
        if nbr >= len(row):
            continue
        key = _MACRO_NBR.get(row[nbr].strip())
        if key and key not in out:
            out[key] = row[ni].strip()
    return out


def _stage(con, zip_path, note, has_brand: bool) -> None:
    """Stream one archive's food / branded_food / food_nutrient CSVs into staging tables."""
    whole = 0 if has_brand else 1  # SR Legacy = curated whole foods; Branded = grocery products
    with zipfile.ZipFile(zip_path) as zf:
        id_to_macro = {nid: key for key, nid in _macro_ids(zf).items()}  # nutrient_id(str) -> macro

        note(f"  reading {os.path.basename(zip_path)} (foods)…")
        rd, ix = _reader(zf, "food.csv")
        fi, di = ix["fdc_id"], ix["description"]
        batch = []
        for row in rd:
            if di >= len(row):
                continue
            fid, desc = row[fi].strip(), row[di].strip()
            if fid and desc:
                batch.append((int(fid), desc, whole))
                if len(batch) >= _BATCH:
                    con.executemany("INSERT OR IGNORE INTO bld.s_food(fdc_id,name,is_whole) VALUES(?,?,?)", batch)
                    batch.clear()
        if batch:
            con.executemany("INSERT OR IGNORE INTO bld.s_food(fdc_id,name,is_whole) VALUES(?,?,?)", batch)

        if has_brand:
            note("  reading brands + serving sizes…")
            rd, ix = _reader(zf, "branded_food.csv")
            fi = ix["fdc_id"]
            bo, bn = ix.get("brand_owner"), ix.get("brand_name")
            ss, su, hh = ix.get("serving_size"), ix.get("serving_size_unit"), ix.get("household_serving_fulltext")

            def cell(row, i):
                return row[i].strip() if (i is not None and i < len(row)) else ""

            batch = []
            for row in rd:
                if fi >= len(row) or not row[fi].strip():
                    continue
                brand = cell(row, bo) or cell(row, bn) or None
                unit = cell(row, su).lower()
                size = _num(cell(row, ss))
                serving_g = size if (size and unit in _GRAM_UNITS) else None
                serving_text = cell(row, hh) or None
                batch.append((int(row[fi]), brand, serving_g, serving_text))
                if len(batch) >= _BATCH:
                    con.executemany(
                        "INSERT OR IGNORE INTO bld.s_bf(fdc_id,brand,serving_g,serving_text) VALUES(?,?,?,?)", batch)
                    batch.clear()
            if batch:
                con.executemany(
                    "INSERT OR IGNORE INTO bld.s_bf(fdc_id,brand,serving_g,serving_text) VALUES(?,?,?,?)", batch)

        note("  reading nutrients (large file — a few minutes)…")
        rd, ix = _reader(zf, "food_nutrient.csv")
        fi, ti, ai = ix["fdc_id"], ix["nutrient_id"], ix["amount"]
        batch = []
        for row in rd:
            if ti >= len(row):
                continue
            macro = id_to_macro.get(row[ti])
            if macro is None:
                continue
            amt = _num(row[ai]) if ai < len(row) else None
            if amt is None:  # present-but-blank amount stays NULL, not 0
                continue
            batch.append((int(row[fi]), macro, amt))
            if len(batch) >= _BATCH:
                con.executemany("INSERT INTO bld.s_fn(fdc_id,macro,amount) VALUES(?,?,?)", batch)
                batch.clear()
        if batch:
            con.executemany("INSERT INTO bld.s_fn(fdc_id,macro,amount) VALUES(?,?,?)", batch)
        con.commit()


def build(progress=None) -> int:
    """Download + parse SR Legacy + Branded into foods.sqlite3 (FTS5). Returns the count."""
    def note(m):
        if progress:
            progress(m)

    sr = config.DATA_DIR / "_sr_legacy.zip"
    br = config.DATA_DIR / "_branded.zip"
    out_db = config.DATA_DIR / "_foods_new.sqlite3"   # build here, swap in on success
    build_db = config.DATA_DIR / "_foods_build.sqlite3"
    for p in (out_db, build_db):
        if p.exists():
            p.unlink()

    _download(SR_LEGACY_URL, sr, note)
    _download(BRANDED_URL, br, note)

    con = sqlite3.connect(out_db)
    try:
        con.executescript(
            """
            PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=FILE;
            CREATE TABLE foods (
                fdc_id INTEGER PRIMARY KEY, name TEXT NOT NULL, brand TEXT,
                kcal_100g REAL, protein_100g REAL, carb_100g REAL, fat_100g REAL,
                serving_g REAL, serving_text TEXT, is_whole INTEGER
            );
            """
        )
        con.execute("ATTACH DATABASE ? AS bld", (str(build_db),))
        con.executescript(
            """
            PRAGMA bld.journal_mode=OFF; PRAGMA bld.synchronous=OFF;
            CREATE TABLE bld.s_food(fdc_id INTEGER PRIMARY KEY, name TEXT, is_whole INTEGER);
            CREATE TABLE bld.s_bf(fdc_id INTEGER PRIMARY KEY, brand TEXT, serving_g REAL, serving_text TEXT);
            CREATE TABLE bld.s_fn(fdc_id INTEGER, macro TEXT, amount REAL);
            """
        )

        _stage(con, sr, note, has_brand=False)
        _stage(con, br, note, has_brand=True)

        note("Joining foods + nutrients…")
        con.execute("CREATE INDEX bld.ix_fn ON s_fn(fdc_id)")
        con.execute(
            """
            INSERT INTO foods (fdc_id, name, brand, kcal_100g, protein_100g, carb_100g, fat_100g, serving_g, serving_text, is_whole)
            SELECT f.fdc_id, f.name, b.brand, k.kcal, k.protein, k.carb, k.fat, b.serving_g, b.serving_text, f.is_whole
            FROM bld.s_food f
            LEFT JOIN bld.s_bf b ON b.fdc_id = f.fdc_id
            JOIN (
                SELECT fdc_id,
                       MAX(CASE WHEN macro='kcal'    THEN amount END) AS kcal,
                       MAX(CASE WHEN macro='protein' THEN amount END) AS protein,
                       MAX(CASE WHEN macro='carb'    THEN amount END) AS carb,
                       MAX(CASE WHEN macro='fat'     THEN amount END) AS fat
                FROM bld.s_fn GROUP BY fdc_id
            ) k ON k.fdc_id = f.fdc_id
            WHERE k.kcal IS NOT NULL
            """
        )

        note("Building search index (FTS5)…")
        con.executescript(
            """
            CREATE VIRTUAL TABLE foods_fts USING fts5(
                name, brand, content='foods', content_rowid='fdc_id', tokenize='porter unicode61');
            INSERT INTO foods_fts(rowid, name, brand) SELECT fdc_id, name, COALESCE(brand,'') FROM foods;
            """
        )
        n = con.execute("SELECT COUNT(*) FROM foods").fetchone()[0]
        con.execute("DETACH DATABASE bld")
        con.commit()
    finally:
        con.close()

    os.replace(out_db, config.FOODS_DB_PATH)  # atomic swap-in
    for p in (sr, br, build_db):
        try:
            p.unlink()
        except OSError:
            pass
    note(f"Saved {n:,} foods.")
    return n
