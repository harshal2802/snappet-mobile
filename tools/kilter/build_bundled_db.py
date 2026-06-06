#!/usr/bin/env python3
"""
Build a small, read-only Kilter catalog `.sqlite3` a user can IMPORT into Snappet.

Snappet ships no catalog (issue #42) — it never redistributes Aurora's data. This
tool trims the full Kilter database (≈69 MB, ~100k climbs, downloaded with `boardlib`;
see RESEARCH.md) into a small, self-contained `kilter.sqlite3` the user imports via the
app's "Import catalog file…" flow (iOS Files / Android SAF). The app then reads it
read-only from on-device storage:

  * ALL board-geometry / reference tables are copied whole (they're tiny and the
    renderer + grade mapping need every row): difficulty_grades, products,
    product_sizes, layouts, sets, product_sizes_layouts_sets, products_angles,
    placement_roles, holes, holds, placements, leds.
  * climbs / climb_stats / climb_cache_fields / beta_links are restricted to the
    most-climbed *listed* problems on the chosen layouts (default: Kilter
    Original + Homewall), capped to --limit so the file stays a few MB.

The output is a USER-IMPORTABLE file, NOT an app asset — do not commit it into
ios/.../Resources or android/.../assets. Run it on your own machine under your own
acceptance of Aurora's Terms of Use.

Usage:
    pip install boardlib pillow
    boardlib database kilter full.sqlite3
    python tools/kilter/build_bundled_db.py full.sqlite3 --out kilter.sqlite3 \
        --layouts 1 8 --limit 800
    # then import kilter.sqlite3 in-app: Kilter Board -> Import catalog file...
"""
import argparse
import sqlite3
import sys

# Copied verbatim — small enough that subsetting buys nothing and the renderer /
# grade mapping touch every row.
FULL_TABLES = [
    "difficulty_grades", "products", "product_sizes", "layouts", "sets",
    "product_sizes_layouts_sets", "products_angles", "placement_roles",
    "holes", "holds", "placements", "leds",
]
# Subset to the picked climbs (keyed by climb_uuid / uuid).
CLIMB_TABLES = {
    "climbs": "uuid",
    "climb_stats": "climb_uuid",
    "climb_cache_fields": "climb_uuid",
    "beta_links": "climb_uuid",
}


def ddl_for(src, table):
    row = src.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    if not row:
        sys.exit(f"error: source DB has no table '{table}'")
    return row[0]


def copy_table(src, dst, table, where=None):
    dst.execute(ddl_for(src, table))
    rows = src.execute(f"SELECT * FROM {table}" + (f" WHERE {where}" if where else "")).fetchall()
    if rows:
        placeholders = ",".join("?" * len(rows[0]))
        dst.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)
    return len(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="full kilter db.sqlite3 from `boardlib database kilter`")
    ap.add_argument("--out", required=True, help="output bundled kilter.sqlite3 path")
    ap.add_argument("--layouts", type=int, nargs="+", default=[1, 8],
                    help="layout ids to include (default: 1=Original 8=Homewall)")
    ap.add_argument("--limit", type=int, default=800,
                    help="max climbs, most-climbed first (default 800; 0 = no cap)")
    args = ap.parse_args()

    src = sqlite3.connect(args.source)
    # Fresh output file.
    import os
    if os.path.exists(args.out):
        os.remove(args.out)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    dst = sqlite3.connect(args.out)

    layout_csv = ",".join(str(i) for i in args.layouts)
    pick_sql = f"""
        SELECT c.uuid FROM climbs c
        JOIN climb_stats cs ON cs.climb_uuid = c.uuid
        WHERE c.is_listed = 1 AND c.layout_id IN ({layout_csv}) AND c.frames_count = 1
        GROUP BY c.uuid
        ORDER BY MAX(cs.ascensionist_count) DESC
    """
    if args.limit > 0:
        pick_sql += f" LIMIT {args.limit}"
    picked = [r[0] for r in src.execute(pick_sql).fetchall()]
    if not picked:
        sys.exit("error: no climbs matched — check --layouts against the source DB")
    uuid_list = "(" + ",".join("'" + u.replace("'", "''") + "'" for u in picked) + ")"

    with dst:
        for t in FULL_TABLES:
            n = copy_table(src, dst, t)
            print(f"  {t:32s} {n}")
        for t, key in CLIMB_TABLES.items():
            n = copy_table(src, dst, t, where=f"{key} IN {uuid_list}")
            print(f"  {t:32s} {n}  (subset)")
    dst.execute("VACUUM")
    dst.commit()
    size_mb = os.path.getsize(args.out) / 1e6
    print(f"\nwrote {args.out}: {len(picked)} climbs, {size_mb:.2f} MB")


if __name__ == "__main__":
    main()
