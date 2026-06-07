#!/usr/bin/env python3
"""
Build a tiny, fully-synthetic Kilter catalog fixture for tests and manual import.

This file contains **zero Aurora data** — every row (a couple of layouts, a small
invented hole grid, four made-up climbs) is authored here by hand. It exists so the
app's read-only `KilterCatalog` layer, the new `KilterCatalogValidator`, and the
opt-in import flow can be exercised without redistributing Aurora's proprietary
catalog (the whole point of issue #42).

The schema mirrors the columns Aurora's database uses (table/column *structure* is
not the proprietary data — the climb rows are), so a fixture built here loads through
the exact same reader the app ships. Output is deterministic (no randomness), so the
checked-in `kilter-fixture.sqlite3` is reproducible:

    python3 tools/kilter/build_test_fixture.py --out tools/kilter/kilter-fixture.sqlite3

The same synthetic catalog is reproduced in code by `KilterCatalogFixture` (Swift) and
`KilterCatalogFixture` (Kotlin) for the unit / instrumented tests, which can't read a
checked-in binary across the test↔app process boundary. Keep the three in sync.
"""
import argparse
import os
import sqlite3

# Required tables, in the exact shape Aurora's DB uses (DDL only — structure, not data).
DDL = {
    "difficulty_grades": """
        CREATE TABLE difficulty_grades (
            difficulty INT UNSIGNED NOT NULL PRIMARY KEY,
            boulder_name TEXT NOT NULL,
            route_name TEXT NOT NULL,
            is_listed BOOLEAN NOT NULL
        )""",
    "layouts": """
        CREATE TABLE layouts (
            id INT UNSIGNED NOT NULL PRIMARY KEY,
            product_id INT UNSIGNED NOT NULL,
            name TEXT NOT NULL,
            instagram_caption TEXT NOT NULL,
            is_mirrored BOOLEAN NOT NULL,
            is_listed BOOLEAN NOT NULL,
            password TEXT NULL DEFAULT NULL,
            created_at TEXT NOT NULL
        )""",
    "holes": """
        CREATE TABLE holes (
            id INT UNSIGNED NOT NULL PRIMARY KEY,
            product_id INT UNSIGNED NOT NULL,
            name TEXT NOT NULL,
            x INT NOT NULL,
            y INT NOT NULL,
            mirrored_hole_id INT UNSIGNED NULL DEFAULT NULL,
            mirror_group INT UNSIGNED NOT NULL DEFAULT 0
        )""",
    "placement_roles": """
        CREATE TABLE placement_roles (
            id INT UNSIGNED NOT NULL PRIMARY KEY,
            product_id INT UNSIGNED NOT NULL,
            position INT UNSIGNED NOT NULL,
            name TEXT NOT NULL,
            full_name TEXT NOT NULL,
            led_color TEXT NOT NULL,
            screen_color TEXT NOT NULL
        )""",
    "placements": """
        CREATE TABLE placements (
            id INT UNSIGNED NOT NULL PRIMARY KEY,
            layout_id INT UNSIGNED NOT NULL,
            hole_id INT UNSIGNED NOT NULL,
            hold_id INT UNSIGNED NOT NULL,
            rotation INT NOT NULL,
            default_placement_role_id INT UNSIGNED NULL DEFAULT NULL
        )""",
    "product_sizes": """
        CREATE TABLE product_sizes (
            id INT UNSIGNED NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT
        )""",
    "leds": """
        CREATE TABLE leds (
            id INT UNSIGNED NOT NULL PRIMARY KEY,
            product_size_id INT UNSIGNED NOT NULL,
            hole_id INT UNSIGNED NOT NULL,
            position INT UNSIGNED NOT NULL
        )""",
    "product_sizes_layouts_sets": """
        CREATE TABLE product_sizes_layouts_sets (
            id INT UNSIGNED NOT NULL PRIMARY KEY,
            product_size_id INT UNSIGNED NOT NULL,
            layout_id INT UNSIGNED NOT NULL,
            set_id INT UNSIGNED NOT NULL,
            image_filename TEXT NOT NULL,
            is_listed BOOLEAN NOT NULL
        )""",
    "climbs": """
        CREATE TABLE climbs (
            uuid TEXT NOT NULL PRIMARY KEY,
            layout_id INT UNSIGNED NOT NULL,
            setter_id INT UNSIGNED NOT NULL,
            setter_username TEXT NOT NULL,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            hsm INT UNSIGNED NOT NULL,
            edge_left INT UNSIGNED NOT NULL,
            edge_right INT UNSIGNED NOT NULL,
            edge_bottom INT UNSIGNED NOT NULL,
            edge_top INT UNSIGNED NOT NULL,
            angle INT NULL DEFAULT NULL,
            frames_count INT UNSIGNED NOT NULL DEFAULT 1,
            frames_pace INT UNSIGNED NOT NULL DEFAULT 0,
            frames TEXT NOT NULL,
            is_draft BOOLEAN NOT NULL DEFAULT 0,
            is_listed BOOLEAN NOT NULL,
            created_at TEXT NOT NULL
        )""",
    "climb_stats": """
        CREATE TABLE climb_stats (
            climb_uuid TEXT NOT NULL,
            angle INT UNSIGNED NOT NULL,
            display_difficulty FLOAT UNSIGNED NOT NULL,
            benchmark_difficulty FLOAT UNSIGNED NULL DEFAULT NULL,
            ascensionist_count INT UNSIGNED NOT NULL,
            difficulty_average FLOAT UNSIGNED NOT NULL,
            quality_average FLOAT UNSIGNED NOT NULL,
            fa_username TEXT NOT NULL,
            fa_at TEXT NOT NULL,
            PRIMARY KEY (climb_uuid, angle)
        )""",
    "climb_cache_fields": """
        CREATE TABLE climb_cache_fields (
            climb_uuid TEXT NOT NULL PRIMARY KEY,
            ascensionist_count INT UNSIGNED NULL DEFAULT NULL,
            display_difficulty FLOAT UNSIGNED NULL DEFAULT NULL,
            quality_average FLOAT UNSIGNED NULL DEFAULT NULL
        )""",
    "beta_links": """
        CREATE TABLE beta_links (
            climb_uuid TEXT NOT NULL,
            link TEXT NOT NULL,
            foreign_username TEXT NULL DEFAULT NULL,
            angle INT NULL DEFAULT NULL,
            thumbnail TEXT NULL DEFAULT NULL,
            is_listed BOOLEAN NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (climb_uuid, link)
        )""",
}

# A 5x5 hole grid on coordinates 4,8,12,16,20 (board extent 16x16).
COORDS = [4, 8, 12, 16, 20]
NOW = "2024-01-01 00:00:00"

# Synthetic placement roles: (id, name, screen_color, led_color). The reader maps role ids
# 12/13/14/15 to start/middle/finish/foot. `start` deliberately has a different led_color vs
# screen_color (mirrors real Kilter data) so the board uses led_color, not the on-screen colour.
ROLES = [
    (12, "start", "00DD00", "00FF00"),
    (13, "middle", "00FFFF", "00FFFF"),
    (14, "finish", "FF00FF", "FF00FF"),
    (15, "foot", "FFA500", "FFA500"),
]

# Two synthetic board sizes for layout 1: size 1 maps hole H -> LED position H; size 2 maps
# H -> H + SIZE_TWO_OFFSET (a different physical address), so tests prove the wrong size lights
# the wrong holds.
SIZE_TWO_OFFSET = 1000

# Four invented climbs on layout 1. frames are "p<placement>r<role>" tokens; placement
# ids equal hole ids (1..25) for layout 1 (see build()). Pure fiction.
CLIMBS = [
    ("11111111-1111-4111-8111-111111111111", "Test Problem Alpha", "fixtureSetter",
     "p1r12p13r13p25r14", [(40, 15.0, 250, 2.6), (25, 12.0, 90, 2.1)]),
    ("22222222-2222-4222-8222-222222222222", "Test Problem Bravo", "fixtureSetter",
     "p5r12p13r13p21r14", [(40, 20.0, 120, 2.9), (30, 18.0, 60, 2.4)]),
    ("33333333-3333-4333-8333-333333333333", "Test Problem Charlie", "anotherSetter",
     "p3r12p7r13p19r13p23r14", [(40, 24.0, 45, 1.8)]),
    ("44444444-4444-4444-8444-444444444444", "Test Problem Delta", "anotherSetter",
     "p2r12p14r13p24r14", [(25, 10.0, 300, 3.0), (40, 16.0, 200, 2.7)]),
]


def build(out_path):
    if os.path.exists(out_path):
        os.remove(out_path)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    db = sqlite3.connect(out_path)
    with db:
        for ddl in DDL.values():
            db.execute(ddl)

        # Grades 1..39 with synthetic combined labels (same "font/V" shape the app expects).
        for d in range(1, 40):
            db.execute("INSERT INTO difficulty_grades VALUES (?,?,?,?)",
                       (d, f"{d}a/V{max(0, d // 3)}", f"route{d}", 1))

        # Two layouts (only layout 1 carries climbs; layout 2 proves the picker lists
        # only layouts that actually have listed climbs).
        db.execute("INSERT INTO layouts VALUES (1,1,'Test Wall A','',0,1,NULL,?)", (NOW,))
        db.execute("INSERT INTO layouts VALUES (2,1,'Test Wall B','',0,1,NULL,?)", (NOW,))

        # placement_roles columns: id, product_id, position, name, full_name, led_color, screen_color
        for role_id, name, screen, led in ROLES:
            db.execute("INSERT INTO placement_roles VALUES (?,?,?,?,?,?,?)",
                       (role_id, 1, role_id, name, name, led, screen))

        db.execute("INSERT INTO product_sizes VALUES (1,'5 x 5','Test Small')")
        db.execute("INSERT INTO product_sizes VALUES (2,'5 x 5','Test Large')")

        # 5x5 holes + a placement per hole on layout 1 (placement id == hole id), plus an LED per
        # hole on each of two product sizes (size 2's positions are offset, to test size selection).
        hid = 0
        for row, y in enumerate(COORDS):
            for col, x in enumerate(COORDS):
                hid += 1
                db.execute("INSERT INTO holes VALUES (?,?,?,?,?,NULL,0)",
                           (hid, 1, f"{chr(65 + row)}{col + 1}", x, y))
                db.execute("INSERT INTO placements VALUES (?,?,?,?,?,NULL)", (hid, 1, hid, hid, 0))
                db.execute("INSERT INTO leds VALUES (?,?,?,?)", (hid, 1, hid, hid))
                db.execute("INSERT INTO leds VALUES (?,?,?,?)",
                           (hid + 10000, 2, hid, hid + SIZE_TWO_OFFSET))
        db.execute("INSERT INTO product_sizes_layouts_sets VALUES (1,1,1,1,'test.png',1)")
        db.execute("INSERT INTO product_sizes_layouts_sets VALUES (2,2,1,1,'test.png',1)")

        for uuid, name, setter, frames, stats in CLIMBS:
            db.execute(
                "INSERT INTO climbs VALUES (?,?,?,?,?,'',0,?,?,?,?,NULL,1,0,?,0,1,?)",
                (uuid, 1, 1, setter, name, 4, 20, 4, 20, frames, NOW))
            best = max(stats, key=lambda s: s[2])  # cache fields mirror the most-climbed angle
            db.execute("INSERT INTO climb_cache_fields VALUES (?,?,?,?)",
                       (uuid, best[2], best[1], best[3]))
            for angle, diff, ascents, quality in stats:
                db.execute("INSERT INTO climb_stats VALUES (?,?,?,NULL,?,?,?,?,?)",
                           (uuid, angle, diff, ascents, diff, quality, setter, NOW))
            db.execute("INSERT INTO beta_links VALUES (?,?,NULL,NULL,NULL,1,?)",
                       (uuid, f"https://example.test/{name.split()[-1].lower()}", NOW))
    db.execute("VACUUM")
    db.commit()
    db.close()
    print(f"wrote {out_path}: {len(CLIMBS)} synthetic climbs, "
          f"{os.path.getsize(out_path)} bytes")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="tools/kilter/kilter-fixture.sqlite3",
                    help="output fixture path")
    build(ap.parse_args().out)
