# Feature prompt: Opt-in exercise library download

**Prompt ID**: exercises-dataset-snappet  
**Branch**: `claude/exercises-dataset-snappet-6n8h1z`  
**Status**: Implemented 2026-06-30

## Problem

The bundled catalog ships 873 exercises from the Free Exercise DB. A richer dataset
([hasaneyldrm/exercises-dataset](https://github.com/hasaneyldrm/exercises-dataset)) has
1,324 exercises **with animated GIF demos** — a quality bar the bundled catalog doesn't reach.

Bundling the full 1,324 GIFs (~500 MB) and images (~15 MB) inside the app binary is impractical.
Silently fetching from a third-party CDN would violate the on-device-only constraint.

## Solution

Mirror the Kilter catalog pattern (decisions.md 2026-06-05):
- Host the converted dataset on `harshal2802/Snappet` (the Snappet web repo).
- The mobile app ships the 873 bundled exercises as-is (zero regression for existing users).
- An opt-in "Download exercise library" banner in the Library section surfaces the extra
  1,324 exercises. The user taps it once; the JSON (~800 KB) is fetched and cached locally.
  Animated GIFs are loaded lazily per exercise detail, via Safari link (no binary dependency).

## Scope

**One job**: wire the opt-in download + surface downloaded exercises in the browse/search/detail
UI. No changes to the bundled exercises.json. No new SwiftData models.

## Acceptance criteria

1. Library section shows "Download exercise library" banner when the opt-in library is not installed.
2. Tapping the banner opens `ExerciseLibraryImportView` with a progress indicator.
3. After download, `ExerciseResolver.allMerged` includes both bundled (873) + downloaded (1,324).
4. Filter/search/Spotlight work on the merged catalog.
5. `ExerciseDetailView` shows a thumbnail (`AsyncImage`) and a "Watch animated demo" link (Safari)
   for exercises that have `imageURL` / `gifURL`.
6. Removing the library from the import view returns to the bundled-only state.
7. `SpotlightIndexer` re-run after a download also indexes the downloaded exercises.
8. No network requests until the user explicitly taps "Download".

## What was built

- `experiments/exercises-convert/convert.py` — one-time Python script: transforms
  hasaneyldrm/exercises-dataset format → Snappet Exercise schema (field mapping,
  `ext-` id prefix, `gifURL`/`imageURL` as absolute URLs to the Snappet web repo).
  Run this once and commit the output to `harshal2802/Snappet/exercises-dataset/data/exercises.json`.
- `ExerciseLibraryStore` — manages `AppSupport/ExerciseLibrary/catalog.json` + sidecar meta.
- `ExerciseLibraryProvider` — `ExerciseCatalogProvider` protocol + `NetworkExerciseCatalogProvider`
  + `ExerciseCatalogInstaller` (@Observable) + `ExerciseLibraryValidator`.
- `ExerciseLibraryImportView` — opt-in gate sheet + `ExerciseLibraryDownloadBanner` (inline row).
- `Exercise` struct — `gifURL: String?`, `imageURL: String?` (optional, lenient decode).
- `ExerciseCatalog` — `downloaded: [Exercise]` + `reloadDownloaded()`.
- `ExerciseResolver.allMerged` — includes `ExerciseCatalog.downloaded`.
- `ExerciseDetailView` — Demo section with `AsyncImage` + GIF Safari link.
- `WorkoutLibraryView` — download banner row (shown when library not installed).
- `WorkoutHomeView` — `showingLibraryImport` state + `didChangeNotification` observer.
- `SpotlightIndexer` — indexes bundled + downloaded exercises.

## Web repo setup (manual, one-time)

In `harshal2802/Snappet`:
1. Run `experiments/exercises-convert/convert.py` (see its README).
2. Commit the output as `exercises-dataset/data/exercises.json`.
3. Commit the images/GIFs as `exercises-dataset/images/` and `exercises-dataset/videos/`.
4. Optionally copy `index.html` from the source repo as a mini-app browser.

The mobile app downloads from:
`https://raw.githubusercontent.com/harshal2802/Snappet/main/exercises-dataset/data/exercises.json`

## Decisions

- **Narrow network exception** (mirrors Kilter): One user-initiated GET to the Snappet web repo.
  No analytics, no background sync, no user data uploaded. See decisions.md 2026-06-30.
- **GIF via Safari link, not inline**: Inline GIF animation requires either a third-party library
  or a custom UIViewRepresentable + manual GIF decoder — overkill for v1. Safari link is zero-dep
  and still surfaces the animated demo. Inline GIF is a follow-on.
- **IDs prefixed `ext-`**: Avoids any collision with the 873 bundled exercises whose ids are
  underscore-slugs (`3_4_Sit-Up`). The downloaded exercises are `ext-0001`, `ext-0002`, etc.
- **No SwiftData model**: The downloaded catalog is a plain JSON file on disk managed by
  `ExerciseLibraryStore`. No schema version bump, no migration.
