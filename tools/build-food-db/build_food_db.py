#!/usr/bin/env python3
"""Build the trimmed, read-only ``food.sqlite3`` bundled by the Calorie & Nutrition mini-app.

This is a **dev-time** tool (run on an unrestricted machine), not a runtime step — the app
ships the resulting SQLite as a read-only asset under ``ios/App/Snappet/Resources/`` (and the
Android ``assets/``). Refreshing the catalog = re-run this, drop in the new file, ship an app
update. See ``README.md`` and ``pdd/prompts/features/calorie-tracker/RESEARCH.md``.

Sources (both open, downloadable):
  * Open Food Facts (branded/barcoded) — ODbL. CSV/TSV export from
    https://world.openfoodfacts.org/data  (``--off-csv``).
  * USDA FoodData Central (generic foods) — public domain. The CSV bundle from
    https://fdc.nal.usda.gov/download-datasets/  (``--fdc-dir`` containing ``food.csv``,
    ``food_nutrient.csv``, and optionally ``branded_food.csv``).

Stdlib only (csv, sqlite3, gzip, argparse) so it runs anywhere Python 3 is installed and stays
in step with the repo's "stdlib only, reproducible" tooling convention. All stored macro values
are **per 100 g** (kcal, grams); ``serving_g`` is the grams one labelled serving represents
(NULL when unknown). The app derives serving totals from these.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import os
import sqlite3
import sys

# FDC nutrient ids we keep (per the FDC ``nutrient.csv`` taxonomy).
FDC_NUTRIENTS = {
    1008: "kcal",       # Energy (kcal)
    1003: "protein_g",  # Protein
    1004: "fat_g",      # Total lipid (fat)
    1005: "carbs_g",    # Carbohydrate, by difference
    1079: "fiber_g",    # Fiber, total dietary
    2000: "sugar_g",    # Total Sugars
    1063: "sugar_g",    # Sugars, Total (alt id)
    1093: "sodium_g",   # Sodium, Na (stored in g; FDC reports mg → /1000)
}

SCHEMA = """
CREATE TABLE foods (
    id           TEXT UNIQUE NOT NULL,   -- 'off-<barcode>' | 'fdc-<fdcId>'
    name         TEXT NOT NULL,
    brand        TEXT,
    barcode      TEXT,                   -- GTIN/UPC (nullable; OFF + FDC branded only)
    source       TEXT NOT NULL,          -- 'off' | 'fdc'
    serving_desc TEXT,
    serving_g    REAL,                   -- grams per labelled serving (NULL → per-100g only)
    kcal         REAL,                   -- all macro values below are PER 100 g
    protein_g    REAL,
    carbs_g      REAL,
    fat_g        REAL,
    fiber_g      REAL,
    sugar_g      REAL,
    sodium_g     REAL,
    nutriscore   TEXT,                   -- OFF Nutri-Score grade a..e
    nova         INTEGER                 -- OFF NOVA group 1..4
);
CREATE INDEX idx_foods_barcode ON foods(barcode);
CREATE VIRTUAL TABLE foods_fts USING fts5(name, brand, content='foods', content_rowid='rowid');
"""


def _open_text(path: str):
    """Open a possibly-gzipped CSV/TSV as text."""
    if path.endswith(".gz"):
        return gzip.open(path, mode="rt", encoding="utf-8", newline="")
    return open(path, mode="rt", encoding="utf-8", newline="")


def _to_float(value: str):
    try:
        f = float(value)
        return f if f == f else None  # drop NaN
    except (TypeError, ValueError):
        return None


# --------------------------------------------------------------------------- Open Food Facts


def load_off(path: str, country: str | None, require_kcal: bool):
    """Yield trimmed food rows from an Open Food Facts CSV/TSV export.

    OFF's export is tab-separated with ``*_100g`` nutrient columns. We keep rows that have a
    name and (optionally) a calorie value, filtered to ``country`` when given.
    """
    kept = 0
    with _open_text(path) as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            name = (row.get("product_name") or "").strip()
            code = (row.get("code") or "").strip()
            if not name or not code:
                continue
            if country and country.lower() not in (row.get("countries_en") or "").lower():
                continue
            kcal = _to_float(row.get("energy-kcal_100g"))
            if require_kcal and kcal is None:
                continue
            # OFF stores sodium in g/100g already (salt is separate); prefer sodium_100g.
            sodium = _to_float(row.get("sodium_100g"))
            if sodium is None:
                salt = _to_float(row.get("salt_100g"))
                sodium = (salt / 2.5) if salt is not None else None  # salt → sodium
            serving_g = _to_float(row.get("serving_quantity"))
            nova = _to_float(row.get("nova_group"))
            yield {
                "id": f"off-{code}",
                "name": name[:200],
                "brand": (row.get("brands") or "").strip()[:120] or None,
                "barcode": code,
                "source": "off",
                "serving_desc": (row.get("serving_size") or "").strip()[:60] or None,
                "serving_g": serving_g,
                "kcal": kcal,
                "protein_g": _to_float(row.get("proteins_100g")),
                "carbs_g": _to_float(row.get("carbohydrates_100g")),
                "fat_g": _to_float(row.get("fat_100g")),
                "fiber_g": _to_float(row.get("fiber_100g")),
                "sugar_g": _to_float(row.get("sugars_100g")),
                "sodium_g": sodium,
                "nutriscore": (row.get("nutriscore_grade") or "").strip().lower()[:1] or None,
                "nova": int(nova) if nova is not None else None,
            }
            kept += 1
    print(f"  OFF: kept {kept} products", file=sys.stderr)


# --------------------------------------------------------------------------- USDA FoodData Central


def load_fdc(directory: str, data_types: set[str], require_kcal: bool):
    """Yield trimmed food rows from a USDA FDC CSV bundle.

    Joins ``food.csv`` (id/description/data_type) with ``food_nutrient.csv`` (amounts per 100 g)
    and, when present, ``branded_food.csv`` (brand/GTIN/serving). ``food_nutrient.csv`` is large
    (millions of rows) but is streamed and filtered to the nutrient ids we keep.
    """
    food_path = os.path.join(directory, "food.csv")
    fn_path = os.path.join(directory, "food_nutrient.csv")
    branded_path = os.path.join(directory, "branded_food.csv")

    # 1. food.csv → {fdc_id: (description, data_type)}, filtered to wanted data types.
    foods: dict[str, tuple[str, str]] = {}
    with _open_text(food_path) as fh:
        for row in csv.DictReader(fh):
            dt = (row.get("data_type") or "").strip()
            if data_types and dt not in data_types:
                continue
            foods[row["fdc_id"]] = ((row.get("description") or "").strip(), dt)
    print(f"  FDC: {len(foods)} foods in selected data types {sorted(data_types) or '[all]'}", file=sys.stderr)

    # 2. branded_food.csv → brand / gtin / serving (optional).
    branded: dict[str, dict] = {}
    if os.path.exists(branded_path):
        with _open_text(branded_path) as fh:
            for row in csv.DictReader(fh):
                fid = row["fdc_id"]
                if fid not in foods:
                    continue
                serving_g = _to_float(row.get("serving_size"))
                unit = (row.get("serving_size_unit") or "").strip().lower()
                branded[fid] = {
                    "brand": (row.get("brand_owner") or "").strip()[:120] or None,
                    "barcode": (row.get("gtin_upc") or "").strip() or None,
                    "serving_g": serving_g if unit in ("g", "") else None,
                }

    # 3. food_nutrient.csv → accumulate the nutrients we keep, per fdc_id.
    nutrients: dict[str, dict] = {}
    with _open_text(fn_path) as fh:
        for row in csv.DictReader(fh):
            fid = row.get("fdc_id")
            if fid not in foods:
                continue
            nid = _to_float(row.get("nutrient_id"))
            if nid is None or int(nid) not in FDC_NUTRIENTS:
                continue
            amount = _to_float(row.get("amount"))
            if amount is None:
                continue
            key = FDC_NUTRIENTS[int(nid)]
            if key == "sodium_g":
                amount = amount / 1000.0  # FDC sodium is mg/100g → g/100g
            nutrients.setdefault(fid, {})[key] = amount

    kept = 0
    for fid, (description, _dt) in foods.items():
        n = nutrients.get(fid, {})
        if require_kcal and "kcal" not in n:
            continue
        b = branded.get(fid, {})
        yield {
            "id": f"fdc-{fid}",
            "name": description[:200],
            "brand": b.get("brand"),
            "barcode": b.get("barcode"),
            "source": "fdc",
            "serving_desc": (f"{int(b['serving_g'])} g" if b.get("serving_g") else "100 g"),
            "serving_g": b.get("serving_g"),
            "kcal": n.get("kcal"),
            "protein_g": n.get("protein_g"),
            "carbs_g": n.get("carbs_g"),
            "fat_g": n.get("fat_g"),
            "fiber_g": n.get("fiber_g"),
            "sugar_g": n.get("sugar_g"),
            "sodium_g": n.get("sodium_g"),
            "nutriscore": None,
            "nova": None,
        }
        kept += 1
    print(f"  FDC: kept {kept} foods", file=sys.stderr)


# --------------------------------------------------------------------------- build


COLUMNS = ["id", "name", "brand", "barcode", "source", "serving_desc", "serving_g",
           "kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sodium_g",
           "nutriscore", "nova"]


def build(out_path: str, rows) -> int:
    if os.path.exists(out_path):
        os.remove(out_path)
    con = sqlite3.connect(out_path)
    con.executescript(SCHEMA)
    placeholders = ",".join("?" for _ in COLUMNS)
    insert = f"INSERT OR IGNORE INTO foods ({','.join(COLUMNS)}) VALUES ({placeholders})"
    count = 0
    batch = []
    for row in rows:
        batch.append([row.get(c) for c in COLUMNS])
        if len(batch) >= 5000:
            con.executemany(insert, batch)
            count += len(batch)
            batch = []
    if batch:
        con.executemany(insert, batch)
        count += len(batch)
    # Populate the FTS index from the content table, then optimize + compact.
    con.execute("INSERT INTO foods_fts(rowid, name, brand) SELECT rowid, name, brand FROM foods")
    con.commit()
    con.execute("VACUUM")
    con.commit()
    con.close()
    return count


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the bundled food.sqlite3 from OFF + USDA FDC.")
    ap.add_argument("--off-csv", help="Open Food Facts CSV/TSV export (.csv/.tsv/.gz)")
    ap.add_argument("--fdc-dir", help="Directory with FDC food.csv / food_nutrient.csv / branded_food.csv")
    ap.add_argument("--fdc-data-types", default="survey_fndds_food,foundation_food",
                    help="Comma-separated FDC data_type values to keep (default: generic foods). "
                         "Add 'branded_food' to include branded items.")
    ap.add_argument("--country", help="Filter OFF to a country tag (e.g. 'United States')")
    ap.add_argument("--no-require-kcal", action="store_true",
                    help="Keep foods even when no calorie value is present")
    ap.add_argument("-o", "--out", default="food.sqlite3", help="Output SQLite path")
    args = ap.parse_args()

    if not args.off_csv and not args.fdc_dir:
        ap.error("provide at least one of --off-csv / --fdc-dir")

    require_kcal = not args.no_require_kcal
    data_types = {t.strip() for t in args.fdc_data_types.split(",") if t.strip()}

    def all_rows():
        if args.fdc_dir:
            print("Loading USDA FoodData Central…", file=sys.stderr)
            yield from load_fdc(args.fdc_dir, data_types, require_kcal)
        if args.off_csv:
            print("Loading Open Food Facts…", file=sys.stderr)
            yield from load_off(args.off_csv, args.country, require_kcal)

    print(f"Building {args.out}…", file=sys.stderr)
    n = build(args.out, all_rows())
    size_mb = os.path.getsize(args.out) / (1024 * 1024)
    print(f"Done: {n} foods → {args.out} ({size_mb:.1f} MB)", file=sys.stderr)
    print("Attribution required: Open Food Facts (ODbL) + USDA FoodData Central.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
