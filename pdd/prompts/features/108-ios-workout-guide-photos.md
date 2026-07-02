# Prompt: Workout guide photos — Kilter-style downloadable pack

**File**: pdd/prompts/features/108-ios-workout-guide-photos.md
**Created**: 2026-07-02
**Project type**: Native iOS feature (Swift / SwiftUI) + dev-time python tooling — code lands in this repo.
**Chain**: Gym Tracker line (09 → workout-redesign E0–E7). First exercise-media prompt.
**Source**: User request — "workout app is missing guide photo for each workout … instead of shipping
this data along with the app I want to follow a Kilter-like setup."
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Give every catalog exercise its start/end guide photos — in the exercise detail and in the guided
player's "How to" card — **without adding a byte to the app binary**. Delivery copies the Kilter
catalog/generator posture: a strictly user-initiated, one-time download of a single pack from the
user's own static Pages host, cached in Application Support, fully offline afterward, removable
from Workout Settings. The photos are the Free Exercise DB's own images (public domain, the same
dataset `exercises.json` is built from), so unlike Kilter there is no legal caveat to re-hosting.

## Context the implementer needs

- `ExerciseCatalog.swift` ships 873 exercises from the Free Exercise DB with the upstream `images`
  field deliberately stripped; the UI shows category SF Symbols. Exercise ids are upstream ids, so
  photos can key on `Exercise.id` with no model change.
- The download pattern to mirror is `KilterGeneratorAssets` (manifest GET → streamed download with
  progress → Application Support → idempotent → `remove()`), and the observable install phase to
  mirror is `KilterCatalogInstaller.Phase`.
- iOS has no built-in unzip/untar, and JPEGs don't compress further — so the pack is a purpose-built
  container (`.spack`): `"SPHOTOS1"` magic + 4-byte LE index length + index JSON + concatenated
  JPEGs. Parsing/slice math must be platform-free so it unit-tests without a simulator.
- Custom exercises have no upstream photos; the no-pack app must be byte-for-byte the current UX.

## Approach

- **Tool**: `tools/workout/build_photo_pack.py` — downloads upstream JSON + images, resizes to
  ≤640 px JPEG q70, writes `exercise-photos/{manifest.json, photos-v1.spack}` for the Board
  Explorer Pages repo (served at `…/Snappet/exercise-photos/`). `--limit N` builds a tiny pack for
  local testing against `python -m http.server`.
- **Pure logic**: `Features/WorkoutTracker/ExercisePhotoPack.swift` — header/index parsing with
  typed errors, bounds-checked absolute byte ranges, `PhotoPackManifest`.
- **Edge**: `Services/ExercisePhotoStore.swift` — download/validate/install/remove + slot reads
  (`FileHandle` range read + bounded `NSCache`); host overridable via the `workout.photos.host`
  default. `ExercisePhotoInstaller` (@MainActor @Observable singleton) is the one phase both
  surfaces render.
- **UI**: detail-view pager (`TabView(.page)`, START/END badges) or download CTA
  (`ExerciseDetailView`), photo strip in the player's "How to" card (no CTA mid-workout), and a
  "Guide photos" management section in `WorkoutSettingsView`.
- Wireframes first (standing preference): `docs/ux-research/workout-guide-photos/wireframes.html`.

## Output

- `tools/workout/build_photo_pack.py`, `tools/workout/README.md`
- `ios/App/Snappet/Features/WorkoutTracker/ExercisePhotoPack.swift`
- `ios/App/Snappet/Services/ExercisePhotoStore.swift`
- `ios/App/Snappet/Features/WorkoutTracker/ExerciseGuidePhotoViews.swift`
- Edits: `ExerciseDetailView.swift`, `WorkoutPlayerView.swift`, `WorkoutSettingsView.swift`
- `ios/App/SnappetTests/ExercisePhotoPackTests.swift`
- `docs/ux-research/workout-guide-photos/wireframes.{html,png}`
- `docs/knowledge-graph/data.js` node + edges; `pdd/context/decisions.md` entry

## Acceptance criteria

- [ ] No photo bytes ship in the app bundle; nothing touches the network without an explicit tap.
- [ ] Download CTA (detail + Settings) installs the pack once; photos then render offline in the
      detail pager and the player "How to" strip.
- [ ] Remove (Settings) restores the exact pre-feature UX; custom exercises never show a CTA.
- [ ] A truncated/corrupt download never replaces a good pack (validate-before-adopt) and surfaces
      a readable error.
- [ ] Pack format round-trips between the python writer and the Swift reader (unit-tested).
- [ ] App changes type-check against the iOS SDK (Swift 6, 0 warnings); unit suite green.
- [ ] `decisions.md` updated (container format, hosting posture, slice-on-demand).

## Constraints

- On-device only; the sole network egress is the user-initiated pack/manifest GET to the
  configured static host — no analytics, nothing uploaded (same posture as `KilterAuroraSync`).
- `HighlightEngine` untouched. Pure logic stays platform-free.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — pack roundtrip/corruption tests + full suite.
2. Local e2e: `build_photo_pack.py --limit 12` → `python -m http.server -d exercise-photos 8787` →
   set `workout.photos.host` to the local URL on the simulator → download in Workout Settings →
   verify pager, player strip, Update, Remove; relaunch offline and photos still render.
3. Publish the full pack to the Pages repo (user step), then re-verify with the default host on
   device (MrRobot).
