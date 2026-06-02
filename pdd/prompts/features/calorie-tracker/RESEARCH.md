# Calorie & Nutrition Tracker — data-source research + mini-app plan

**Research date:** 2026-06-02
**Branch:** `claude/calorie-tracking-research-gNVuK`
**Status:** research + proposal (no code yet). Backs the GitHub issue of the same name.

> **Goal.** Decide which food/nutrition database to build a **calorie- and diet-tracking
> mini-app** on, and design how that app fits Snappet's **on-device-only** suite (no backend,
> no accounts, no network sync — [CONTRIBUTING ground rule #1](https://github.com/harshal2802/snappet-mobile/blob/main/CONTRIBUTING.md)).

---

## TL;DR — recommendation

**Bundle an offline, open food database rather than calling a paid online API.** The proven open
stack — used by **every actively-maintained open-source calorie tracker** (wger, OpenNutriTracker,
Waistline, FoodYou) — is:

1. **Open Food Facts (OFF)** — ODbL-licensed, ~3M **branded/barcoded** products (EAN/UPC). This is the
   barcode-scan path.
2. **USDA FoodData Central (FDC)** — US-government **public-domain**, strong on **generic/raw foods**
   (an apple, "100 g chicken breast") that OFF covers poorly.
3. *(optional, per market)* national composition tables — **CIQUAL** (France, Licence Ouverte) and
   **UK CoFID** (OGL v3) — to deepen generic-food coverage.

This mirrors the **Kilter Board** precedent already accepted into the suite ([#32](https://github.com/harshal2802/snappet-mobile/issues/32)):
ship a **trimmed, read-only SQLite snapshot** as a bundled app asset (built dev-time, refreshed by
shipping an app update), keep the user's own logs in **SnappetCore**, and write nutrition to
**HealthKit / Health Connect**. Barcode lookup runs **on-device** against the bundled DB; an *optional,
explicitly opt-in* online OFF call can fill scan-misses (the one network exception, same bucket as
Kilter's logbook import).

**Commercial APIs (Nutritionix / Edamam / FatSecret / Spoonacular) are rejected** for Snappet: they are
**API-only** (no downloadable dataset → can't go offline), **cost money** (e.g. Nutritionix enterprise
~$1,850/mo), often **forbid permanent caching/storage** of results, and **require the network** — each of
which fights the on-device-only ethos.

---

## 1. The constraint that decides everything

Snappet is **on-device only**: "No backend, no accounts, no network sync, no analytics. Health and media
data never leave the device" (`README.md`, `pdd/context/project.md` constraints). That single rule
eliminates the entire category of **online nutrition APIs** as a *core* dependency and points squarely at
a **bundled offline dataset** — which only open, downloadable data can provide.

So the research question collapses to: **which food data is (a) openly licensed for commercial bundling,
(b) downloadable as a full dataset, and (c) good enough on coverage/quality for calorie tracking?**

---

## 2. Options compared

| Source | Open / license | Downloadable dataset? | Barcode | Coverage strength | Cost | Fit for Snappet |
|---|---|---|---|---|---|---|
| **Open Food Facts** | ✅ ODbL (data) + DbCL + CC-BY-SA (images) | ✅ MongoDB / JSONL / CSV / **Parquet**, daily | ✅ EAN/UPC (its core key) | Branded/packaged, **EU-strong**, US weaker | Free | ✅ **core (branded)** |
| **USDA FoodData Central** | ✅ US-gov **public domain** | ✅ CSV / JSON | ⚠️ via `gtinUpc` search (Branded) | **Generic/raw foods**, lab-grade micros, US-centric | Free | ✅ **core (generic)** |
| **CIQUAL (FR)** | ✅ Licence Ouverte | ✅ Excel / XML | ❌ (search by name) | French generic foods, rich micros | Free | ➕ optional (FR) |
| **UK CoFID** | ✅ OGL v3 | ✅ Excel | ❌ | UK generic foods | Free | ➕ optional (UK) |
| **FooDB** | ⚠️ "free" but license unconfirmed | ✅ (research dumps) | ❌ | **Food chemistry/compounds, not servings** | Free | ❌ research-only |
| **Open Food Repo (CH)** | ✅ CC (variant unconfirmed) | partial | ✅ | **Switzerland-only**, maybe stale | Free | ❌ niche |
| **CalorieKing** | ❌ proprietary | ❌ | ✅ | US branded/restaurant | Paid license | ❌ |
| **MyFitnessPal** | ❌ proprietary, partner-only | ❌ | ✅ | Huge, crowdsourced | Closed | ❌ |
| **Nutritionix** | ❌ commercial API | ❌ | ✅ | **US restaurants + NLP parsing** | ~$1,850/mo enterprise | ❌ online-only |
| **Edamam** | ❌ commercial API | ❌ | ✅ (UPC) | Generic + grocery, NLP | Paid tiers | ❌ online-only |
| **FatSecret** | ❌ commercial API | ❌ | ✅ (Premier tier) | **~1.9M, strong international** | Free Basic / paid Premier | ❌ online-only |
| **Spoonacular** | ❌ commercial API | ❌ | ⚠️ partial | Recipes / meal-planning | Points quota | ❌ online-only |

**Convergent real-world signal.** Every actively-maintained FOSS calorie tracker uses **OFF + USDA FDC**:
- **wger** (AGPL) — imports OFF (`extras/open-food-facts`).
- **OpenNutriTracker** (GPLv3, Flutter) — OFF + a curated USDA FDC subset.
- **Waistline** (GPLv3, Android) — OFF + USDA FDC (user-supplied FDC key for generic foods).
- **FoodYou** (Kotlin, Android) — OFF-based.

None rely on FooDB, FoodRepo, CalorieKing, or MyFitnessPal. That's strong evidence OFF + FDC is the
validated open stack.

---

## 3. Open Food Facts — the detail that matters

- **License (verbatim from the API docs):** database structure → **ODbL v1.0**; contents → **DbCL v1.0**;
  product **images** → **CC-BY-SA 3.0**.
- **What ODbL means for a closed-source paid app:**
  - Commercial use is **explicitly allowed**; ODbL is a *database* licence, not a software copyleft — **your
    app code stays proprietary.**
  - **Attribution is mandatory:** credit like *"Data from Open Food Facts — https://world.openfoodfacts.org —
    licensed under ODbL."*
  - **Share-alike applies to a *Derived Database*, not to your app.** Bundling OFF data read-only and
    **displaying** it to users is a **Produced Work** → attribution only, no copyleft. Share-alike only
    bites if you **publicly publish a database** derived from OFF (a normal app doesn't).
  - **Images** are CC-BY-SA → **avoid bundling OFF product photos** (use manufacturer/your own imagery, or
    none) to dodge per-image share-alike + depicted-trademark issues.
  - **No warranty** → add a *"nutrition data may be inaccurate"* disclaimer (matters for a health app).
- **Coverage:** ~**2.9–3M+** food products *(SDK READMEs disagree — Dart says 2.9M, Swift/Kotlin say a stale
  1.9M; verify on the live data page)*. Keyed on **barcodes (EAN-13/8, UPC-A/E)** — exactly the scan path a
  tracker needs. **EU-strong, US weaker.** Fundamentally a **branded/packaged** DB; **raw/generic foods are
  thin** → pair with FDC.
- **Quality:** crowdsourced + AI-enriched. Exposes `data_quality_tags`, `completeness`, `states_tags`
  (e.g. `nutrition-facts-completed`) to filter low-confidence rows. Computes **Nutri-Score** + **NOVA**
  (processing class) + Eco-Score for free. Nutrition stored **per-100 g** (`*_100g`) with **per-serving**
  (`*_serving`, `serving_size`) when present.
- **Bulk exports (the path we use):** **MongoDB / JSONL / CSV / Parquet** (Parquet pushed daily to Hugging
  Face `openfoodfacts/product-database`), regenerated **daily**. Full DB is multi-GB — **filter to target
  market + needed fields** (barcode, name, brand, `nutriments`, serving, Nutri-Score, NOVA) → compact SQLite.
- **API (only for the optional online fallback):** read endpoint
  `GET /api/v2/product/{barcode}.json`; **no auth for reads** but a **custom `User-Agent`** is required
  (`Snappet/<version> (harshal2064@gmail.com)`); **rate limit 15 reads/min/IP** (per end-user IP for a
  mobile app). v3 is current; v2 still supported. **For anything beyond occasional lookups, use the bulk
  export, not the API.**
- **SDK maturity (important):** the official **Swift SDK is unmaintained** ("looking-for-maintainer"); the
  **Kotlin SDK is early/v0-only/unpublished**; the old **Android app is legacy** (the live app is Flutter
  `smooth-app`). → For both platforms, **call the v2 REST endpoint directly** (`URLSession`+`Codable` /
  Retrofit+kotlinx.serialization) and scan with **Vision/VisionKit** (iOS) / **ML Kit** (Android), keeping
  parsing pure and unit-testable — which matches Snappet's "thin platform I/O in `Services/`" convention.

## 4. USDA FoodData Central — the generic-foods complement

- **License:** US-federal work → **effectively public domain**, free for commercial use, **no attribution
  required** (USDA requests a citation). **Caveat:** Branded Foods come via a GS1/1WorldSync partnership —
  the **nutrient data** is public domain but brand **names/logos/trademarks** remain the manufacturers'.
- **Data types:** Foundation Foods, SR Legacy (frozen ~7,700), Survey/**FNDDS** (~5,000, ideal for generic
  calorie tracking), **Branded** (~1.5–2M, carry **`gtinUpc`**), Experimental.
- **Quality:** Foundation/SR Legacy are lab-analyzed with **100+ nutrients**; FNDDS has complete macros +
  common micros; Branded is "as submitted" (label panel only, sparse micros). For a calorie/macro tracker,
  **FNDDS + Branded** give good calorie/macro coverage; Foundation/SR for rich micros.
- **Distribution:** full **CSV/JSON** downloads at `fdc.nal.usda.gov/download-datasets/`. Branded updates
  **monthly**; the consolidated download historically ~twice a year. Branded CSV is multi-GB → **pre-trim
  columns** (description, brand, serving, calories, macros, GTIN) before bundling.
- **API (optional):** `https://api.nal.usda.gov/fdc/v1/` (`/foods/search`, `/food/{fdcId}`), free
  `api.data.gov` key, **~1,000 req/hr/key** (DEMO_KEY ~30/hr) — *figures from prior knowledge, confirm on the
  API guide*. No barcode endpoint, but search the UPC string with `dataType=Branded`. **Don't ship the key
  in the binary** — but for Snappet we prefer the **offline bundled subset** and avoid the API/key entirely.

> ⚠️ **Verification note.** During this research run the web tools were degraded (WebSearch `529`, WebFetch
> `403`). HealthKit/Health Connect (§6) and Open Food Facts (§3) were verified against primary sources;
> several **USDA FDC** figures (exact record counts, file sizes, API rate limits, release cadence) and the
> **commercial-API** prices/terms (§5) are **directionally correct but flagged** — confirm against the live
> pages before relying on them. Key URLs are listed in §8.

## 5. Why not the commercial APIs

All four (Nutritionix, Edamam, FatSecret, Spoonacular) are **API-only with no downloadable dataset**, so they
**cannot power an offline app** — a hard requirement here. On top of that:
- **Cost:** Nutritionix enterprise ~**$1,850/mo** (confirmed this session); FatSecret barcode is a paid
  Premier feature; Edamam/Spoonacular tiers escalate.
- **Storage/caching restrictions:** Nutritionix and Edamam historically **forbid permanently storing** their
  food DB (you may keep a user's own logged entry, not replicate the database) — incompatible with a local
  cache. FatSecret relaxes this on Premier; Spoonacular is most permissive.
- **Network dependency + accounts/keys** → violates Snappet's on-device-only rule.

They're only worth revisiting if Snappet ever relaxes the on-device rule for a specific market (e.g.
Nutritionix's US restaurant-menu data + natural-language logging is genuinely best-in-class) — captured as an
open question, not a plan.

## 6. HealthKit & Health Connect — where the numbers live

Snappet is health-first, so the tracker should **write nutrition to the OS health store** (the system of
record + interop with Apple Health / other apps) and **read energy burned** to compute a net-calorie budget.
All identifiers below are **verified against the SDK headers / AndroidX source.**

**Apple HealthKit (iOS + watchOS 2.0+):** every nutrient is a cumulative `HKQuantityType`. Canonical units:
energy **kcal**, water **mL**, **all** solid nutrients (incl. sodium/caffeine) **grams** (display sodium/
caffeine as mg).
- **Energy + macros:** `dietaryEnergyConsumed` (kcal), `dietaryProtein`, `dietaryCarbohydrates`,
  `dietaryFiber`, `dietarySugar`, `dietaryFatTotal`, `dietaryFatSaturated`, `dietaryFatMono/Polyunsaturated`,
  `dietaryCholesterol` (all g).
- **Electrolytes/other:** `dietarySodium`, `dietaryPotassium` (g), `dietaryWater` (mL), `dietaryCaffeine` (g).
- **Vitamins/minerals:** full set (`dietaryVitaminA…K`, `dietaryCalcium`, `dietaryIron`, …) all in **g**.
- **A meal = one `HKCorrelation` of type `HKCorrelationTypeIdentifierFood`** whose objects are the per-nutrient
  `HKQuantitySample`s; name in metadata (`HKMetadataKeyFoodType`). Authorization is **per-type, split
  read/write** (`requestAuthorization(toShare:read:)`), Info.plist needs `NSHealthUpdateUsageDescription` +
  `NSHealthShareUsageDescription`. You **can't query read-grant status** → treat absent data == denied.
- **Net-calorie budget (convention, not an Apple API):**
  `net = dietaryEnergyConsumed − (basalEnergyBurned + activeEnergyBurned)`. `basalEnergyBurned` is often
  sparse → many apps compute BMR themselves (Mifflin–St Jeor) and use only `activeEnergyBurned` from
  HealthKit. Read **aggregated** values via `HKStatisticsCollectionQuery` (`.cumulativeSum`) to avoid
  double-counting multiple sources.
- **watchOS:** same store auto-syncs to phone; keep watch logging to **one-tap presets** (water, coffee,
  favorites) via complications / Smart Stack / App Intents.

**Android Health Connect:** one **`NutritionRecord`** *is* the meal (an interval record carrying all nutrients
as optional `Energy`/`Mass` fields + `name` + `mealType`). `MealType`: `BREAKFAST=1, LUNCH=2, DINNER=3,
SNACK=4, UNKNOWN=0`. Permissions `READ_NUTRITION` / `WRITE_NUTRITION`. Parity with HealthKit is broad; HC has
extra fields HK lacks (`transFat`, `unsaturatedFat`, `folicAcid`, `energyFromFat`).

Reference Swift save pattern (belongs in `Services/`, **never** in `HighlightEngine`):

```swift
let store = HKHealthStore()
let energy  = HKQuantityType(.dietaryEnergyConsumed)
let protein = HKQuantityType(.dietaryProtein)
let carbs   = HKQuantityType(.dietaryCarbohydrates)
let fat      = HKQuantityType(.dietaryFatTotal)
let foodType = HKCorrelationType(.food)

try await store.requestAuthorization(
    toShare: [foodType, energy, protein, carbs, fat],
    read:    [foodType, energy, protein, carbs, fat])

let g = HKUnit.gram()
let samples: Set<HKSample> = [
    HKQuantitySample(type: energy,  quantity: .init(unit: .kilocalorie(), doubleValue: kcal),    start: date, end: date),
    HKQuantitySample(type: protein, quantity: .init(unit: g, doubleValue: proteinG),             start: date, end: date),
    HKQuantitySample(type: carbs,   quantity: .init(unit: g, doubleValue: carbsG),               start: date, end: date),
    HKQuantitySample(type: fat,     quantity: .init(unit: g, doubleValue: fatG),                 start: date, end: date),
]
let meal = HKCorrelation(type: foodType, start: date, end: date,
                         objects: samples, metadata: [HKMetadataKeyFoodType: name])
try await store.save(meal)
```

---

## 7. How the mini-app fits Snappet (architecture)

Follows the CONTRIBUTING **"Adding a mini-app"** recipe and the **Kilter Board** ([#32](https://github.com/harshal2802/snappet-mobile/issues/32))
bundled-read-only-DB precedent.

- **Bundled catalog (read-only).** A trimmed `food.sqlite3` (OFF branded subset + USDA FDC generic subset,
  built dev-time) under `Snappet/Resources/`, opened **read-only**. **No runtime sync.** Refresh = rebuild
  the asset, ship an app update. **Keep it out of SwiftData** — it's reference data, not user data.
- **User data in SnappetCore.** New `@Model` types (`FoodLogEntry`, `CustomFood`, `NutritionGoal`) keyed by
  `UUID` foreign keys (suite convention), appended to the single `SnappetSchema.models` line. Every meaningful
  action calls `core.log(module: "nutrition", action:, summary:, metric:)` so the **Home dashboard** aggregates
  calories alongside the rest of the suite.
- **Health store I/O in `Services/`** (`NutritionHealthService` on iOS) — thin, `@unchecked Sendable` wrapper
  over `HKHealthStore` like the existing `HealthKitService`; **pure mapping/formatting/budget math isolated**
  into value types (`NutritionBudget`, `MacroSplit`, `ServingMath`) so they unit-test in `SnappetTests` with
  **no device** (the same discipline that keeps `HighlightEngine` platform-free).
- **Barcode scanning on-device:** Vision/VisionKit `DataScannerViewController` (iOS) / ML Kit (Android) →
  look up the GTIN in the bundled DB. **Optional, opt-in** online OFF lookup (custom User-Agent, 15/min) fills
  scan-misses — the single explicit network exception, gated + off by default (mirrors Kilter's logbook
  open question).
- **Reuse:** Swift Charts for trends (like Home/Workout summaries), the **Snappet Pulse** design system +
  motion tokens ([#30](https://github.com/harshal2802/snappet-mobile/issues/30)), and the watchOS companion +
  App Intents patterns already in the repo.

---

## 8. Screens — "how the app would look"

1. **App Library → Fitness:** a **"Nutrition"** tile (`fork.knife` SF Symbol, fitness category) vended by
   `NutritionModule.module`.
2. **Today / Diary (home of the app):** a **calorie-budget ring** (consumed vs. budget; net accounts for
   `active + basal` burned from HealthKit), **macro bars** (protein / carb / fat vs. targets), **meal sections**
   (Breakfast / Lunch / Dinner / Snacks) each listing logged items with kcal, a **water tracker**, and a
   prominent **＋ Add food** / **scan** entry.
3. **Add food:** search the bundled DB (debounced, name search), **Scan barcode**, **Recent** + **Favorites**,
   **Quick-add calories**, and **Create custom food** — pick a meal slot.
4. **Food detail:** nutrition facts (per-serving + per-100 g), **serving-size selector + quantity**, computed
   totals, **Nutri-Score / NOVA** badge (from OFF) when present, **Add to diary**. ODbL attribution footer.
5. **Goals / setup:** daily **calorie target** + **macro split** + **weight goal** (deficit/surplus), derived
   from HealthKit `basal+active` or a Mifflin–St Jeor BMR from age/weight/height/sex; choose units.
6. **History / trends:** daily intake over time, 7-day average vs. budget, macro adherence, optional weight
   trend (Swift Charts) — mirrors the Workout/Pomodoro history screens; flows to the Home dashboard.
7. **Settings:** units, **HealthKit/Health Connect sync** toggle, the **opt-in online barcode lookup** toggle,
   and data-source **attribution** (OFF/ODbL + USDA FDC citation) + accuracy disclaimer.
8. **watchOS:** one-tap **log water / favorite meal**, a daily-budget **complication**, App-Intent "log a glass
   of water."

---

## 9. Suggested phasing

- **Phase 1 (MVP):** bundled OFF+FDC subset · search + food detail + serving math · log to meals (SnappetCore)
  · calorie-budget ring + macro bars · History screen · Home-dashboard logging · HealthKit **write** (food
  correlation) · UI tests. iOS first, Android mirror.
- **Phase 2:** on-device **barcode scanning** · HealthKit **read** of active/basal energy → live net budget ·
  Goals/BMR setup · water tracking · watchOS quick-log + complication.
- **Phase 3:** catalog-refresh tooling (committed script that builds the trimmed SQLite from OFF Parquet +
  FDC CSV) · optional national tables (CIQUAL/CoFID) per market · optional opt-in online OFF fallback ·
  Nutri-Score/NOVA surfacing · recipe/meal builder.

## 10. Open questions (need a product call before shipping)

1. **Data redistribution licensing** — bundling OFF (ODbL attribution; share-alike only on a *published*
   derived DB — bundling+displaying is a Produced Work) + USDA FDC (public domain; brand trademarks remain
   owners') inside the app. Confirm attribution UI + that we don't ship OFF **images** (CC-BY-SA). **Same
   product-call bucket as Kilter #32.11.2.**
2. **Bundle size / market scope** — full OFF+FDC is multi-GB; trim to which market(s) (US? EU? both?) and which
   completeness threshold to keep the asset small.
3. **Online fallback** — allow the opt-in online OFF barcode lookup at all (a network exception to the
   on-device rule), or stay 100% offline and prompt the user to add a missing product manually?
4. **HealthKit as system-of-record vs. mirror** — write-through to HealthKit always, or make it an opt-in sync?

---

## 11. Key sources

- **Open Food Facts:** API docs https://openfoodfacts.github.io/openfoodfacts-server/api/ · terms
  https://world.openfoodfacts.org/terms-of-use · ODbL https://opendatacommons.org/licenses/odbl/1.0/ ·
  data exports https://world.openfoodfacts.org/data · Parquet https://huggingface.co/datasets/openfoodfacts/product-database
- **USDA FoodData Central:** https://fdc.nal.usda.gov/ · downloads https://fdc.nal.usda.gov/download-datasets/ ·
  API guide https://fdc.nal.usda.gov/api-guide/ · FAQ/licensing https://fdc.nal.usda.gov/faq/
- **National tables:** CIQUAL https://ciqual.anses.fr/ (Licence Ouverte) · UK CoFID
  https://www.gov.uk/government/publications/composition-of-foods-integrated-dataset-cofid (OGL v3)
- **HealthKit:** nutrition identifiers https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier ·
  correlation https://developer.apple.com/documentation/healthkit/hkcorrelation · auth
  https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data
- **Health Connect:** `NutritionRecord` https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/NutritionRecord ·
  data types https://developer.android.com/health-and-fitness/health-connect/data-types
- **FOSS trackers (data-source signal):** wger https://github.com/wger-project/wger ·
  OpenNutriTracker https://github.com/simonoppowa/OpenNutriTracker · Waistline https://github.com/davidhealey/waistline
- **Commercial (rejected, for reference):** Nutritionix https://developer.nutritionix.com/ · FatSecret
  https://platform.fatsecret.com/api-editions · Edamam https://developer.edamam.com/food-database-api ·
  Spoonacular https://spoonacular.com/food-api/pricing
</content>
</invoke>
