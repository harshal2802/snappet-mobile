# Kilter catalog tooling

Dev-time tooling that produces the bundled, read-only Kilter catalog the app ships
(`ios/App/Snappet/Resources/kilter.sqlite3` and
`android/app/src/main/assets/kilter.sqlite3`). The app never downloads anything at
runtime — this is how the asset is *refreshed* between releases.

## Refresh the bundled catalog

```sh
pip install boardlib pillow

# 1. Download the full, current Kilter database (~69 MB). Add `-u <username>` to also
#    live-sync the latest community climbs/ascents (needs a Kilter account).
boardlib database kilter full.sqlite3

# 2. Trim it into the small bundled asset and drop it in both platform asset dirs.
python tools/kilter/build_bundled_db.py full.sqlite3 \
    --out android/app/src/main/assets/kilter.sqlite3 \
    --layouts 1 8 --limit 800
cp android/app/src/main/assets/kilter.sqlite3 ios/App/Snappet/Resources/kilter.sqlite3
```

`build_bundled_db.py` copies all board-geometry / reference tables whole and subsets
`climbs`/`climb_stats`/`climb_cache_fields`/`beta_links` to the `--limit` most-climbed
listed problems on the chosen `--layouts`. Flags:

| flag | default | meaning |
|---|---|---|
| `--layouts` | `1 8` | layout ids to include (1 = Kilter Original, 8 = Homewall) |
| `--limit` | `800` | max climbs, most-climbed first (`0` = no cap → the whole catalog) |

> ⚠️ Redistributing the catalog inside the app is gated on a licensing/attribution
> decision (issue #32, open question 2) — confirm before shipping a public build.

## Logbook import (not in-app)

Importing your *historical* Kilter-account ascents would need the network (the board
hardware stores no log), which conflicts with Snappet's on-device-only rule. The dev
path is `boardlib logbook kilter --output logbook.csv`; an opt-in, explicitly-gated
in-app importer remains a future, product-approved item (issue #32, open question 4).
