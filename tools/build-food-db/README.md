# build-food-db — the bundled food catalog builder

Builds the trimmed, **read-only** `food.sqlite3` that the **Calorie & Nutrition** mini-app ships
as an app asset. This is a **dev-time** step run on an unrestricted machine — **not** a runtime
one. Snappet is on-device only, so the catalog is bundled (no backend/accounts/network); refreshing
it means re-running this script, dropping the new file into `Resources/`, and shipping an app update.

Backs [`pdd/prompts/features/calorie-tracker/RESEARCH.md`](../../pdd/prompts/features/calorie-tracker/RESEARCH.md)
and the Calorie & Nutrition issue. Python 3, **stdlib only** (matches the repo's tooling convention).

## Data sources (both open, downloadable)

| Source | Role | License | Download |
|---|---|---|---|
| **Open Food Facts** | Branded / barcoded products | **ODbL** (attribution required) | https://world.openfoodfacts.org/data (CSV/TSV; or Parquet → CSV) |
| **USDA FoodData Central** | Generic / raw foods | **Public domain** (US gov) | https://fdc.nal.usda.gov/download-datasets/ (CSV bundle) |

> ⚠️ **Licensing:** OFF data is ODbL — bundling it read-only and *displaying* it is a "Produced
> Work" (attribution only; share-alike only triggers if you publicly *publish* a derived database).
> **Do not bundle OFF product images** (CC-BY-SA). USDA FDC is public domain, but branded
> trademarks remain the manufacturers'. The app shows the required attribution + an accuracy
> disclaimer. Confirm before shipping (open question in the issue).

## Usage

```sh
# 1. Open Food Facts CSV/TSV export (gzip ok). Filter to a market to keep it small.
python3 build_food_db.py --off-csv en.openfoodfacts.org.products.csv.gz \
    --country "United States" -o food.sqlite3

# 2. USDA FDC: point at the unzipped CSV bundle dir (food.csv, food_nutrient.csv,
#    branded_food.csv). Default keeps the GENERIC foods (FNDDS + Foundation).
python3 build_food_db.py --fdc-dir ./FoodData_Central_csv -o food.sqlite3

# 3. Both at once (the recommended stack: OFF branded + FDC generic):
python3 build_food_db.py --fdc-dir ./FoodData_Central_csv \
    --off-csv en.openfoodfacts.org.products.csv.gz --country "United States" \
    -o food.sqlite3

# Include FDC branded foods too (much larger):
python3 build_food_db.py --fdc-dir ./FoodData_Central_csv \
    --fdc-data-types survey_fndds_food,foundation_food,branded_food -o food.sqlite3
```

Then drop `food.sqlite3` into `ios/App/Snappet/Resources/` (a `sources` path in `project.yml`, so
it bundles automatically) and the Android `assets/`, and `xcodegen generate`.

## Output schema

A single `foods` table + an FTS5 index for name search. **All macro values are per 100 g**
(`kcal`, grams); `serving_g` is the grams one labelled serving represents (NULL → per-100g only).
The app builds serving options from these (a "100 g" serving, plus a per-serving one when
`serving_g` is set) and computes totals via the pure `ServingMath`.

```
foods(id, name, brand, barcode, source, serving_desc, serving_g,
      kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_g, nutriscore, nova)
idx_foods_barcode  — barcode (GTIN/UPC) lookup
foods_fts          — fts5(name, brand) for search-as-you-type
```

`source` is `off` | `fdc`; `nutriscore` (a..e) and `nova` (1..4) come from OFF only. Sodium is
stored in **grams** (HealthKit's canonical unit; FDC's mg is converted, OFF salt is converted to
sodium ÷ 2.5).

## Keeping the asset small

The full OFF + FDC branded datasets are multi-GB. To keep the bundled asset reasonable:
- `--country` filters OFF to one market.
- Keep only the **generic** FDC data types (the default) and rely on OFF for branded/barcoded items.
- `--no-require-kcal` is **off** by default, so foods with no calorie value are dropped.

Bundle size / market scope is an open product question (see the issue).

## Verification

A stdlib smoke test (synthetic fixtures → build → query / FTS / barcode lookup) confirms the FDC
join, OFF parsing, the sodium mg→g conversion, FTS search and barcode lookup. Building from the
**real** multi-GB exports needs the source files downloaded on an unrestricted machine (the cloud
sandbox firewalls the download hosts), so the production-scale build + final asset size are owed at
that step.
</content>
