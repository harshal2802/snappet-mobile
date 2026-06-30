# exercises-convert

Converts the [hasaneyldrm/exercises-dataset](https://github.com/hasaneyldrm/exercises-dataset)
(1,324 exercises with animated GIFs) into Snappet's Exercise JSON schema for hosting on the
[harshal2802/Snappet](https://github.com/harshal2802/Snappet) web repo.

## What it produces

`snappet-exercises.json` — a JSON array of exercises in the exact format `ExerciseCatalog` loads,
extended with optional `gifURL` and `imageURL` fields (absolute URLs pointing to the Snappet web repo).

This file goes to `harshal2802/Snappet → exercises-dataset/data/exercises.json`.
The images/GIFs live at `exercises-dataset/images/` and `exercises-dataset/videos/`.

## Web repo setup (one-time)

1. Clone `hasaneyldrm/exercises-dataset` locally.
2. Run this script (see below) to produce `snappet-exercises.json`.
3. In `harshal2802/Snappet`:
   - Copy `snappet-exercises.json` to `exercises-dataset/data/exercises.json`
   - Copy `images/` to `exercises-dataset/images/`
   - Copy `videos/` to `exercises-dataset/videos/`
   - Optionally copy `index.html` as the mini-app browser.
4. Commit and push.

The mobile app will download from:
`https://raw.githubusercontent.com/harshal2802/Snappet/main/exercises-dataset/data/exercises.json`

## Running the script

```sh
# From the exercises-dataset repo (fetches live from GitHub):
python3 convert.py

# From a local clone:
python3 convert.py \
  --source /path/to/exercises-dataset/data/exercises.json \
  --out snappet-exercises.json

# Custom host (if you mirror elsewhere):
python3 convert.py --base-url https://example.com/exercises
```

## Field mapping

| Source field | Snappet field | Notes |
|---|---|---|
| `id` | `id` (prefixed `ext-`) | `ext-0001` avoids collisions with bundled catalog |
| `name` | `name` | Direct |
| `body_part` | `category` | Mapped: waist/back/chest/arms/shoulders/legs → `strength`; cardio → `cardio` |
| `target` | `primaryMuscles[0]` | Normalized to Snappet Muscle enum raw values |
| `muscle_group` | `primaryMuscles[1]` | Added if different from target |
| `secondary_muscles[]` | `secondaryMuscles[]` | Normalized |
| `equipment` | `equipment` | `body weight` → `body only`; unmapped → `other` |
| `instruction_steps.en[]` | `instructions[]` | English steps only |
| `image` | `imageURL` | Absolute URL to Snappet web repo |
| `gif_url` | `gifURL` | Absolute URL to Snappet web repo |
| *(absent)* | `level` | Defaults to `beginner` |
| *(absent)* | `force`, `mechanic` | Defaults to `null` |

## Output size

- 1,324 exercises as JSON text: ~800 KB (compressed: ~200 KB)
- Images (`images/`): ~15 MB total
- Animated GIFs (`videos/`): ~500 MB total (large — users download lazily per exercise)
