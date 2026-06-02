# Kilter Board mini-app — data research & integration notes

Research backing the "Add a Kilter Board mini-app" issue. Captures **where the climb data comes
from**, **what's in it**, and **how it maps onto Snappet's mini-app architecture** under the
on-device-only constraint. One prompt = one job; this is the research half, the issue is the plan.

## 1. The data source

The Kilter Board climb catalog ships inside the official Android app's APK as a SQLite database at
`assets/db.sqlite3`. The community tool [`boardlib`](https://github.com/lemeryfertitta/BoardLib)
automates pulling and syncing it:

```sh
pip install boardlib                       # also needs Pillow: pip install Pillow
boardlib database kilter kilter.sqlite3    # download the seed DB (no login)
# Optional live sync of community climbs/ascents (requires a Kilter account):
boardlib database kilter kilter.sqlite3 -u <username>
```

`boardlib` downloads the APK bundle from apkpure, unzips `assets/db.sqlite3`, then (with `-u`) calls
the Aurora sync API to top up the shared tables.

**Note on this environment:** apkpure is not reachable from the sandbox (network policy blocks all
non-GitHub/PyPI hosts → `403`). The analysis below was done against an equivalent **complete Kilter
`db.sqlite3` snapshot** (≈69 MB, 102,690 climbs) obtained from a GitHub-hosted mirror. For a
**current** snapshot, run `boardlib` from an unrestricted machine — the schema is identical.

## 2. What's in the database (snapshot analyzed)

33 tables. The ones that matter for a browse/log/illuminate app:

| Table | Rows | What it is |
|---|---|---|
| `climbs` | 102,690 | Every problem. `frames` encodes the holds (see §3). `layout_id`, `is_listed`, `setter_username`, `name`. |
| `climb_stats` | 116,271 | Per-`(climb_uuid, angle)`: `display_difficulty`, `ascensionist_count`, `quality_average`, `benchmark_difficulty`. |
| `climb_cache_fields` | 64,765 | Denormalized `display_difficulty`/`quality`/`ascensionist_count` for fast list rendering. |
| `difficulty_grades` | 39 | Maps `difficulty` (int) → `boulder_name` (`"7a/V6"`) and `route_name`. |
| `holes` | 3,294 | Physical hole grid per product, with `x`/`y` board coordinates. |
| `holds` / `placements` | 3,294 / 3,773 | A `placement` ties a `hole` + `hold` + `rotation` to a `layout`. |
| `placement_roles` | 30 | Hold role → colors. Kilter (product 1): `start`=`00FF00`, `middle`=`00FFFF`, `finish`=`FF00FF`, `foot`=`FFA500` (`led_color` + `screen_color`). |
| `leds` | 7,632 | Per-`(product_size, hole)` LED `position` index — the key for **Bluetooth board illumination**. |
| `layouts` | 8 | e.g. `1`=Kilter Board Original, `8`=Kilter Board Homewall. |
| `products` / `product_sizes` | 7 / 21 | Board models + physical sizes (`12 x 14 Commercial`, `8 x 12 Home`, …). |
| `product_sizes_layouts_sets` | 40 | Joins size×layout×set → the **board background `image_filename`** to render under the holds. |
| `beta_links` | 19,766 | Instagram/YouTube beta video URLs per climb. |
| `sets` | 11 | Bolt-Ons / Screw-Ons / Mainline / Auxiliary / Kickboard. |

Listed climbs: **87,608** total — **79,050** on Kilter Original (layout 1), **7,848** on Homewall
(layout 8). Angles span **0°–70°** in 5° steps. ~40 board background images referenced.

## 3. The `frames` encoding (how a climb is drawn)

`climbs.frames` is a string of `p<placement_id>r<role_id>` tokens, one per lit hold. Example
(*"You Don't Know Me"*, 11,209 ascents, ~V3 @ 40°):

```
p1096r15 p1113r15 p1149r12 p1200r13 … p1392r14
        │       │        │
        │       │        └ role 12 = start  (green 00FF00)
        │       └ role 13 = middle (cyan 00FFFF)
        └ role 15 = foot   (orange FFA500)   (14 = finish, magenta FF00FF)
```

To render or illuminate a climb:

1. Parse `frames` → `[(placement_id, role_id)]`.
2. `placements.id → hole_id, hold_id, rotation`; `holes.id → x, y` (board coords).
3. `role_id → placement_roles` → `screen_color` (UI dot) / `led_color` (BLE).
4. For the board's Bluetooth LEDs: `leds` (by `product_size_id` + `hole_id`) → `position`.

Grade for display: `climb_stats.display_difficulty` (rounded) → nearest `difficulty_grades.difficulty`
→ `boulder_name`. Difficulty is **per angle**, so the UI needs an angle selector.

## 4. Fit with Snappet's constraints

- **On-device only (no network).** The catalog is static reference data → **bundle a `db.sqlite3`
  snapshot as a read-only app asset** and open it read-only. No runtime sync, accounts, or analytics.
  Refresh is a **developer-time** step (re-run `boardlib`, drop in the new asset, ship an update).
- **The board itself is Bluetooth LE** — local, on-device, no backend. Lighting up a climb is an
  optional Phase-2 add-on; Phase 1 ships fully usable with on-screen rendering only.
- **User data** (sends/projects/likes) goes in the **shared SnappetCore store** (SwiftData / Room),
  *separate* from the read-only catalog DB — keyed by `climb_uuid`. Activity is logged via
  `core.log(module:action:summary:metric:)` so the Home dashboard aggregates it like every other app.

## 5. How a mini-app wires into the suite (from CONTRIBUTING + code)

**iOS:** feature folder `Features/Kilter/` → vend `enum KilterModule { static var module: AppModule }`
→ append to `ModuleRegistry.all` → append any `@Model` types to `SnappetSchema.models`
(`Core/SnappetCore.swift`) → `xcodegen generate`. Root view is pushed into the App Library's
`NavigationStack` (no own `NavigationStack`).

**Android:** package `feature/kilter/` → append `AppModule(...)` to `core/ModuleRegistry.all` →
append `@Entity` types + DAO to `core/SnappetDatabase` → mirror the iOS flow.

Bundled-asset wiring: add the `.sqlite3` (+ board background PNGs) under `Snappet/Resources/`
(already a `sources` path in `project.yml`, so it bundles automatically) and Android `assets/`.
</content>
