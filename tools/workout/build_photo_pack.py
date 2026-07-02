#!/usr/bin/env python3
"""Build the downloadable exercise guide-photo pack (issue: workout guide photos).

Downloads the Free Exercise DB (public domain, https://github.com/yuhonas/free-exercise-db)
start/end photos for every exercise in the app's bundled `exercises.json`, resizes them, and
packs them into a single versioned container the app streams from a static host — the same
"user-initiated download from a Pages site" posture as the Kilter board catalog, minus the
legal caveats (this dataset is public domain, so re-hosting it is fine).

Output (`--out`, default `exercise-photos/`), ready to upload to the Board Explorer Pages repo:

    exercise-photos/
      manifest.json        # {version, file, sizeBytes, photoCount, exerciseCount, generated}
      photos-v1.spack      # the pack the app downloads once and slices on demand

`.spack` container ("Snappet photo pack", read by `ExercisePhotoPack.swift`):

    magic "SPHOTOS1" (8B) | index length (4B little-endian) | index JSON (UTF-8) | JPEG blobs

    index JSON: {"exercises": {"<exerciseId>": [{"offset": n, "length": n}, ...]}}
    offsets are relative to the first byte after the index (the blob region).

Usage:
    pip install pillow
    python tools/workout/build_photo_pack.py                 # full pack (~873 exercises)
    python tools/workout/build_photo_pack.py --limit 12      # tiny pack for local testing
    python -m http.server -d exercise-photos 8787            # serve it to the simulator
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import io
import json
import struct
import sys
import urllib.request
from pathlib import Path

UPSTREAM = "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main"
MAGIC = b"SPHOTOS1"
PACK_FILENAME = "photos-v1.spack"
DEFAULT_CATALOG = (
    Path(__file__).resolve().parents[2]
    / "ios/App/Snappet/Features/WorkoutTracker/Resources/exercises.json"
)


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "snappet-photo-pack-builder"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def shrink(jpeg: bytes, max_px: int, quality: int) -> bytes:
    from PIL import Image

    img = Image.open(io.BytesIO(jpeg))
    img = img.convert("RGB")
    img.thumbnail((max_px, max_px))
    out = io.BytesIO()
    img.save(out, "JPEG", quality=quality, optimize=True, progressive=True)
    return out.getvalue()


def photo_paths(entry: dict) -> list[str]:
    """Up to two upstream image paths: first (start position) and last (end position)."""
    images = entry.get("images") or []
    if len(images) <= 2:
        return images
    return [images[0], images[-1]]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG,
                    help="app exercises.json — only ids in it are packed (default: iOS bundle copy)")
    ap.add_argument("--out", type=Path, default=Path("exercise-photos"),
                    help="output directory (default: ./exercise-photos)")
    ap.add_argument("--cache", type=Path, default=Path(".photo-pack-cache"),
                    help="download cache so re-runs don't re-fetch originals")
    ap.add_argument("--max-px", type=int, default=640, help="max image dimension (default 640)")
    ap.add_argument("--quality", type=int, default=70, help="JPEG quality (default 70)")
    ap.add_argument("--workers", type=int, default=12, help="parallel downloads (default 12)")
    ap.add_argument("--limit", type=int, default=0,
                    help="pack only the first N exercises (testing; 0 = all)")
    args = ap.parse_args()

    app_ids = [e["id"] for e in json.loads(args.catalog.read_text())]
    upstream = {e["id"]: e for e in json.loads(fetch(f"{UPSTREAM}/dist/exercises.json").decode())}
    ids = [i for i in app_ids if photo_paths(upstream.get(i, {}))]
    skipped = [i for i in app_ids if i not in upstream]
    if args.limit:
        ids = ids[: args.limit]
    print(f"{len(app_ids)} exercises in app catalog → {len(ids)} with upstream photos "
          f"({len(skipped)} unknown upstream)")

    args.cache.mkdir(parents=True, exist_ok=True)

    def prepare(exercise_id: str) -> tuple[str, list[bytes]]:
        blobs = []
        for path in photo_paths(upstream[exercise_id]):
            cached = args.cache / path.replace("/", "__")
            if not cached.exists():
                cached.write_bytes(fetch(f"{UPSTREAM}/exercises/{path}"))
            blobs.append(shrink(cached.read_bytes(), args.max_px, args.quality))
        return exercise_id, blobs

    photos: dict[str, list[bytes]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(prepare, i): i for i in ids}
        for n, fut in enumerate(concurrent.futures.as_completed(futures), 1):
            try:
                exercise_id, blobs = fut.result()
            except Exception as err:  # noqa: BLE001 — report the exercise, keep packing
                print(f"  ! {futures[fut]}: {err}", file=sys.stderr)
                continue
            photos[exercise_id] = blobs
            if n % 50 == 0 or n == len(ids):
                print(f"  {n}/{len(ids)} exercises processed")

    # Deterministic layout: sorted ids, photos in start→end order.
    index: dict[str, list[dict[str, int]]] = {}
    blob = io.BytesIO()
    for exercise_id in sorted(photos):
        entries = []
        for data in photos[exercise_id]:
            entries.append({"offset": blob.tell(), "length": len(data)})
            blob.write(data)
        index[exercise_id] = entries

    index_json = json.dumps({"exercises": index}, separators=(",", ":"), sort_keys=True).encode()
    args.out.mkdir(parents=True, exist_ok=True)
    pack_path = args.out / PACK_FILENAME
    with open(pack_path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<I", len(index_json)))
        f.write(index_json)
        f.write(blob.getvalue())

    photo_count = sum(len(v) for v in index.values())
    manifest = {
        "version": 1,
        "file": PACK_FILENAME,
        "sizeBytes": pack_path.stat().st_size,
        "photoCount": photo_count,
        "exerciseCount": len(index),
        "generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    print(f"\nWrote {pack_path} — {manifest['sizeBytes'] / 1e6:.1f} MB, "
          f"{photo_count} photos across {len(index)} exercises")
    print(f"Upload the '{args.out}' directory to the Board Explorer Pages repo "
          f"(served as .../Snappet/exercise-photos/).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
