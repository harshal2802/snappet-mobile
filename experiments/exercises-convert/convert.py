#!/usr/bin/env python3
"""
Convert the hasaneyldrm/exercises-dataset format into Snappet's Exercise JSON schema.

Usage:
    python3 convert.py [--source <url-or-path>] [--base-url <base>] [--out <file>]

Defaults:
    --source  https://raw.githubusercontent.com/hasaneyldrm/exercises-dataset/main/data/exercises.json
    --base-url  https://raw.githubusercontent.com/harshal2802/Snappet/main/exercises-dataset
    --out  snappet-exercises.json

The output file is the JSON array to place at:
    harshal2802/Snappet → exercises-dataset/data/exercises.json

Each exercise id is prefixed "ext-" so it never collides with the 873 bundled exercises.
The bundled catalog stays in the app; this file is the OPT-IN download.
"""

import json
import sys
import urllib.request
import argparse
from pathlib import Path

DEFAULT_SOURCE = (
    "https://raw.githubusercontent.com/hasaneyldrm/exercises-dataset/main/data/exercises.json"
)
DEFAULT_BASE_URL = (
    "https://raw.githubusercontent.com/harshal2802/Snappet/main/exercises-dataset"
)

# body_part (new dataset) → ExerciseCategory raw value (Snappet)
BODY_PART_TO_CATEGORY: dict[str, str] = {
    "waist": "strength",
    "back": "strength",
    "chest": "strength",
    "upper arms": "strength",
    "lower arms": "strength",
    "shoulders": "strength",
    "upper legs": "strength",
    "lower legs": "strength",
    "neck": "strength",
    "cardio": "cardio",
}

# target / muscle_group names (new dataset) → Muscle raw value (Snappet)
MUSCLE_MAP: dict[str, str] = {
    "abs": "abdominals",
    "abdominals": "abdominals",
    "abductors": "abductors",
    "adductors": "adductors",
    "biceps": "biceps",
    "calves": "calves",
    "chest": "chest",
    "forearms": "forearms",
    "glutes": "glutes",
    "hamstrings": "hamstrings",
    "lats": "lats",
    "lower back": "lower back",
    "middle back": "middle back",
    "neck": "neck",
    "quads": "quadriceps",
    "quadriceps": "quadriceps",
    "shoulders": "shoulders",
    "traps": "traps",
    "triceps": "triceps",
    # approximate mappings
    "spine": "lower back",
    "hip flexors": "abdominals",
    "serratus anterior": "chest",
    "levator scapulae": "traps",
    "delts": "shoulders",
}

# equipment (new dataset) → Equipment raw value (Snappet)
EQUIPMENT_MAP: dict[str, str] = {
    "body weight": "body only",
    "dumbbell": "dumbbell",
    "barbell": "barbell",
    "cable": "cable",
    "machine": "machine",
    "band": "bands",
    "resistance band": "bands",
    "kettlebell": "kettlebells",
    "medicine ball": "medicine ball",
    "exercise ball": "exercise ball",
    "foam roll": "foam roll",
    "e-z curl bar": "e-z curl bar",
    "ez curl bar": "e-z curl bar",
}


def map_muscle(name: str) -> str | None:
    return MUSCLE_MAP.get(name.strip().lower())


def map_equipment(raw: str | None) -> str | None:
    if not raw:
        return None
    return EQUIPMENT_MAP.get(raw.strip().lower(), "other")


def extract_instructions(entry: dict) -> list[str]:
    """Pull English instructions from instruction_steps.en, falling back to instructions."""
    steps = entry.get("instruction_steps", {})
    if isinstance(steps, dict):
        en = steps.get("en", [])
        if isinstance(en, list) and en:
            return [str(s) for s in en]
    # some entries have top-level instructions as a plain list
    raw = entry.get("instructions")
    if isinstance(raw, list):
        return [str(s) for s in raw]
    if isinstance(raw, dict):
        en = raw.get("en", [])
        if isinstance(en, list):
            return [str(s) for s in en]
    return []


def convert_entry(entry: dict, base_url: str) -> dict:
    raw_id = str(entry.get("id", "")).zfill(4)
    name = entry.get("name", "").strip()

    # Media paths use whatever filename the source provides.
    image_path = entry.get("image", "")
    gif_path = entry.get("gif_url", "")
    # Normalise paths like "images/0001-abc.jpg" → absolute URL.
    image_url = f"{base_url}/{image_path}" if image_path else None
    gif_url = f"{base_url}/{gif_path}" if gif_path else None

    body_part = (entry.get("body_part") or entry.get("category") or "").strip().lower()
    category = BODY_PART_TO_CATEGORY.get(body_part, "strength")

    target = (entry.get("target") or "").strip().lower()
    muscle_group = (entry.get("muscle_group") or "").strip().lower()
    secondary_raw = entry.get("secondary_muscles") or []

    primary_muscles: list[str] = []
    if m := map_muscle(target):
        primary_muscles.append(m)
    if muscle_group and muscle_group != target:
        if m := map_muscle(muscle_group):
            if m not in primary_muscles:
                primary_muscles.append(m)

    secondary_muscles: list[str] = []
    for s in secondary_raw:
        if m := map_muscle(str(s)):
            if m not in primary_muscles and m not in secondary_muscles:
                secondary_muscles.append(m)

    equipment = map_equipment(entry.get("equipment"))

    out: dict = {
        "id": f"ext-{raw_id}",
        "name": name,
        "force": None,
        "level": "beginner",
        "mechanic": None,
        "equipment": equipment,
        "primaryMuscles": primary_muscles,
        "secondaryMuscles": secondary_muscles,
        "instructions": extract_instructions(entry),
        "category": category,
    }
    if image_url:
        out["imageURL"] = image_url
    if gif_url:
        out["gifURL"] = gif_url
    return out


def load_source(source: str) -> list[dict]:
    if source.startswith("http://") or source.startswith("https://"):
        print(f"Fetching {source} …", file=sys.stderr)
        with urllib.request.urlopen(source) as resp:
            return json.loads(resp.read())
    else:
        return json.loads(Path(source).read_text())


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", default=DEFAULT_SOURCE)
    ap.add_argument("--base-url", default=DEFAULT_BASE_URL)
    ap.add_argument("--out", default="snappet-exercises.json")
    args = ap.parse_args()

    entries = load_source(args.source)
    print(f"Loaded {len(entries)} exercises from source.", file=sys.stderr)

    converted = [convert_entry(e, args.base_url.rstrip("/")) for e in entries]
    converted.sort(key=lambda e: e["name"].lower())

    out_path = Path(args.out)
    out_path.write_text(json.dumps(converted, indent=2, ensure_ascii=False))
    print(f"Wrote {len(converted)} exercises → {out_path}", file=sys.stderr)

    # Quick stats
    with_gif = sum(1 for e in converted if e.get("gifURL"))
    with_muscles = sum(1 for e in converted if e.get("primaryMuscles"))
    print(f"  with gifURL: {with_gif}", file=sys.stderr)
    print(f"  with primaryMuscles: {with_muscles}", file=sys.stderr)
    categories = {}
    for e in converted:
        categories[e["category"]] = categories.get(e["category"], 0) + 1
    print(f"  categories: {categories}", file=sys.stderr)


if __name__ == "__main__":
    main()
