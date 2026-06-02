# Architecture Decisions

## ADR-001 — Bundled open food database vs. commercial nutrition API

**Context — issue #33 (Calorie & Nutrition tracker, Phase 1 MVP)**

The nutrition tracker needs a food catalog: names, macro-nutrients per 100 g,
barcodes for scan-to-log. Two families of options were evaluated.

### Options considered

| | Bundled open DB | Commercial API (e.g. Nutritionix, Edamam) |
|---|---|---|
| Offline | Full — no network ever | None — API call required per query |
| Cost | Free | Paid tier above free quota |
| License | ODbL (OFF) + Public Domain (USDA FDC) | Per-ToS; caching usually forbidden |
| Data size | ~30 MB trimmed export | Zero (streamed) |
| Snappet ground rule | On-device-only | Violates "no backend" rule |
| Barcode lookup | SQLite `WHERE code = ?` | API call |
| Privacy | Zero telemetry | Queries leave device |

### Decision

**Bundle a trimmed SQLite export** derived from two public-domain sources:

* **Open Food Facts (OFF)** — worldwide product database, licensed ODbL 1.0.
  Bundling the dataset read-only makes Snappet a *Produced Work* under ODbL;
  attribution is required (footer in-app), share-alike is **not** triggered
  because we do not publicly distribute a derived database.
  OFF product images are **not** bundled (they carry separate per-image terms).

* **USDA FoodData Central (FDC)** — U.S. government data, public domain
  (17 U.S.C. § 105). No license restrictions.

A 17-item seed dataset is committed alongside the code to keep CI and simulator
builds working before the full trimmed export is bundled.

### Consequences

* Every lookup is an `O(log n)` SQLite b-tree seek — no latency, no quota.
* Attribution footer is required in-app on both iOS and Android
  (`"Data: Open Food Facts (ODbL) · USDA FDC (Public Domain)"`).
* The trimmed export (~30 MB) must be committed under `assets/food.sqlite3`
  (Android) and the iOS bundle before the first production release.
* If a commercial API is later desired (richer data, images), it must operate
  as a *supplement* — cache locally, never require network for core logging.
