# Kilter catalog tooling

Dev-time tooling that produces a Kilter catalog `.sqlite3` a user can **import into the app
themselves** (issue #42). **Snappet ships no catalog** and never downloads one automatically — the
app reads the catalog read-only from on-device storage *after the user imports it*.

> ⚠️ **Snappet no longer redistributes Aurora's catalog inside the app.** These tools run on a
> developer's / user's own machine, under their own acceptance of Aurora Climbing's
> [Terms of Use](https://kilterboardapp.com/terms-of-use). The generated `.sqlite3` is **imported
> at runtime, not committed into the app** — there is no longer a bundled asset in either platform.

## Build a catalog file to import

```sh
pip install boardlib pillow

# 1. Download the full, current Kilter database (~69 MB). Add `-u <username>` to also
#    live-sync the latest community climbs/ascents (needs a Kilter account).
boardlib database kilter full.sqlite3

# 2. Trim it into a small catalog you can import in-app.
python tools/kilter/build_bundled_db.py full.sqlite3 --out kilter.sqlite3 --layouts 1 8 --limit 800
```

Then in the app: open **Kilter Board** → **Import catalog file…** (iOS **Files** picker / Android
**Storage Access Framework**) and pick `kilter.sqlite3`. The app validates the schema
(`KilterCatalogValidator`) and installs it into app storage; from then on browse / detail / log /
illuminate work offline. **Refresh catalog** and **Remove downloaded catalog** live in Kilter
**Settings**.

`build_bundled_db.py` copies all board-geometry / reference tables whole and subsets
`climbs`/`climb_stats`/`climb_cache_fields`/`beta_links` to the `--limit` most-climbed listed
problems on the chosen `--layouts`. Flags:

| flag | default | meaning |
|---|---|---|
| `--layouts` | `1 8` | layout ids to include (1 = Kilter Original, 8 = Homewall) |
| `--limit` | `800` | max climbs, most-climbed first (`0` = no cap → the whole catalog) |

> The script's name is historical (it once built a bundled asset); its output is now a
> **user-importable** file, not an app asset. Don't copy it into `ios/.../Resources` or
> `android/.../assets`.

## Test fixture (synthetic, zero Aurora data)

`build_test_fixture.py` writes a tiny, **fully-synthetic** catalog (`kilter-fixture.sqlite3`) — a
couple of invented layouts, a small hole grid, four made-up climbs — that you can import by hand to
try the flow without `boardlib`. It contains **no Aurora data**. The in-code `KilterCatalogFixture`
(Swift + Kotlin) reproduces the same rows for the unit / instrumented tests, so the three must stay in
sync.

```sh
python tools/kilter/build_test_fixture.py --out tools/kilter/kilter-fixture.sqlite3
```

## Logbook import (not in-app)

Importing your *historical* Kilter-account ascents would need the network (the board hardware stores
no log). The dev path is `boardlib logbook kilter --output logbook.csv`; an opt-in, explicitly-gated
in-app importer remains a future, product-approved item (issue #32, open question 4).
