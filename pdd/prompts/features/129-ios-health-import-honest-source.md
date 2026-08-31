# Prompt: Imports name their real source — Apple Health is a shared store, not "the Watch"

**File**: pdd/prompts/features/129-ios-health-import-honest-source.md
**Created**: 2026-08-31
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: device investigation on MrRobot — user: "that climbing workout is not from apple watch",
then "i logged the workout in google health app… can you verify if google health workouts also get
synced with HealthKit?" (they do). Supersedes prompts 127/128, which were built on a wrong model.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Stop the app lying about where an imported workout came from, and stop it mangling imports whose
writer re-syncs them.

Measured on the user's device (237 import anchors): every resolvable workout carries
`bundle=com.apple.health.<watch-uuid>, productType=Watch6,9` — EXCEPT the rows the user complained
about, which are written by **Google Health** (`com.fitbit.FitbitMobile`, `productType
iPhone14,3`) and whose timestamps/durations match the History screenshot exactly (Aug 10 8:00 PM
17m, Aug 21 6:30 PM 180m, Aug 24 7:44 PM 15m; `type=9` = climbing). The app equated "came from
HealthKit" with "came from the Apple Watch" (`isFromAppleWatch == healthKitWorkoutUUID != nil`)
and badged all of them ⌚ under a "From Apple Watch" header.

Two prior attempts failed because they mis-modelled this:
- **127** gated imports on `productType == Watch…`, which would have silently DROPPED the user's
  Google Health workouts — stranding the clips filmed during them. Its `com.snappet` bundle rule
  never matched anything on the device either.
- **128** deleted anchors it couldn't resolve, assuming "unresolvable = user deleted it". On the
  device, unresolvable means **Fitbit rewrote the workout under a new uuid on its next sync** —
  which is also why duplicate rows kept appearing (each re-sync minted a twin). Deleting there
  destroys a real session and its clips.

## Approach

- **Store provenance**: `WorkoutSession.importSourceName` / `.importSourceProductType`, stamped at
  mint from `HKSourceRevision` (name + productType). Mirrored into `WorkoutSessionRow` as
  Optionals with a restored-model assertion (the prompt-07 column-drift rule).
- **Honest predicates**: `isImportedFromHealth` (grouping — any import, no exercises/sets) vs
  `isFromAppleWatch` (⌚ badge — a real Watch productType only). `importSourceLabel` gives
  "Apple Watch" / "Google Health" / neutral "Health" when unknown (pre-129 rows, until backfilled).
- **UI tells the truth**: History header is "Imported from Health" unless every row really is a
  Watch recording; each row reads "<source> · <date>" with a source-appropriate glyph; the detail
  header says "Recorded in Google Health".
- **Import gate simplifies to one rule**: never re-import our OWN recordings (`com.snappet*`).
  Everything else imports whoever wrote it — the lie was the label, never the import.
- **`maintain(anchors:sources:candidates:lookupHealthy:)`** replaces 128's delete-only
  `staleAnchors`: stamp resolvable anchors; **re-link** an orphan to the same workout re-synced
  under a new uuid (start ± 60 s and duration ± 60 s, unclaimed); delete only own-source anchors,
  duplicate non-keepers, and genuinely-vanished anchors — the last ONLY when `lookupHealthy`
  (something resolved), so a denied HealthKit read can never wipe history.

## Output

Changed: `WorkoutModels.swift`, `HealthKitService.swift` (+`workoutIdentities(since:)`),
`WatchWorkoutReconciler.swift`, `WatchWorkoutImportService.swift`, `SnappetBackup.swift`,
`HistorySectionView.swift`, `SessionDetailView.swift`, `WorkoutTrackerModule.swift`,
`ClipsFeedView.swift`. Tests: `WatchWorkoutReconcilerTests` (rewritten gate + maintenance),
new `ImportSourceLabelTests`, `SnappetBackupTests` provenance round trip.

## Acceptance criteria

- [ ] A phone-app-written workout is imported, is NOT `isFromAppleWatch`, and reads its writer's
      name; a Watch recording still reads "Apple Watch"; unknown provenance reads "Health".
- [ ] An orphaned anchor re-links to a re-synced workout instead of being deleted or twinned.
- [ ] Nothing is deleted when the HealthKit lookup resolves nothing.
- [ ] Provenance survives backup → restore (asserted on the restored model).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` + knowledge graph updated.

## Constraints

- No migration: new model fields have inline defaults.
- Never drop a user's workout because of who wrote it; never assert a device we can't prove.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`.
2. Device (MrRobot): relaunch → the four Aug rows read "Google Health", the header stops saying
   "From Apple Watch", genuine Watch rows keep ⌚, and no duplicates re-appear after a Fitbit sync.
