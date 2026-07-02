# Workout guide-photo pack tooling

Builds the **exercise guide-photo pack** the app offers as a one-time download (Gym Tracker →
exercise detail / Workout Settings → "Guide photos"). The photos are the start/end position shots
from the [Free Exercise DB](https://github.com/yuhonas/free-exercise-db) (public domain) — the same
dataset the bundled `exercises.json` catalog comes from, so ids match 1:1. **Snappet ships no
photos in the binary**; the app streams this pack once from a static host and reads it offline
forever after — the same posture as the Kilter board-catalog download (`board-data/`), just with a
simpler legal story since this dataset is public domain and fine to re-host.

## Build

```sh
pip install pillow
python tools/workout/build_photo_pack.py            # full pack (~873 exercises, prints final size)
```

Output in `exercise-photos/`:

- `photos-v1.spack` — one container: `SPHOTOS1` magic + JSON index + concatenated resized JPEGs.
  The app (`ExercisePhotoPack.swift`) parses the index and slices photos out with range reads —
  no unzip step, no thousands of loose files.
- `manifest.json` — `{version, file, sizeBytes, photoCount, exerciseCount, generated}`; the app
  GETs this first to show the real size on the download button.

## Publish

Upload the `exercise-photos/` directory to the **Snappet Board Explorer** GitHub Pages repo so it
serves at `https://harshal2802.github.io/Snappet/exercise-photos/` (the app's default host,
`workoutPhotoPackHost`). The host is overridable in-app via the `workout.photos.host` default —
handy for testing against a local server:

```sh
python tools/workout/build_photo_pack.py --limit 12   # small pack for a quick loop
python -m http.server -d exercise-photos 8787         # then point the app at http://<mac-ip>:8787/
```

Re-running is cheap: originals are cached in `.photo-pack-cache/`. Bump `PACK_FILENAME` /
`version` together if the format ever changes; the app checks `manifest.json`'s `version`.
