# Prompt: Open Snappet to the OS — Spotlight indexing + deep-link routing (Phase 4 of 4)

**File**: pdd/prompts/features/57-ios-os-integration-spotlight.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → OS integration (iOS)
**Source**: GitHub issue [#81](https://github.com/harshal2802/snappet-mobile/issues/81)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The last phase of #81: make Snappet's content findable in **Spotlight**. Index the exercise catalog and
the user's created climbs as `CSSearchableItem`s whose tap deep-links straight to the right screen —
satisfying the AC "searching an exercise or climb name in Spotlight deep-links to its screen." Spotlight
results reuse the `snappet://` routing the QR/widget/Siri paths already use, so there's one routing
brain.

## Context the implementer needs

- **The deep-link routing brain exists**: `SnappetDeepLink` (URL→route) + `RootShell.onOpenURL` +
  `SuiteRouter`. Spotlight reuses it — a `CSSearchableItem`'s `uniqueIdentifier` IS the `snappet://`
  URL, and a Spotlight tap arrives via `.onContinueUserActivity(CSSearchableItemActionType)` carrying
  that identifier, which we turn back into a URL and route through the SAME handler as `onOpenURL`.
- **Created climbs need NO new route**: `KilterCreatedClimb.uuid` + the existing
  `snappet://kilter/climb/<uuid>?angle=<n>` route (`KilterClimbLink`, `pendingKilterClimb`,
  `KilterDeepLinkRouting` — which already resolves user-created climbs). Index them with that URL.
- **Exercises** are the value type `Exercise` (`WorkoutModels.swift`: `id: String`, `name`, `subtitle`)
  from `ExerciseCatalog.all` (873 built-ins). The gym tracker already navigates to one via
  `.navigationDestination(for: Exercise.self)` → `ExerciseDetailView` (WorkoutTrackerModule). A new
  `snappet://exercise/<id>` route resolves the `Exercise` from the catalog and pushes it after opening
  the `workout-log` module (the two-level deep-link pattern Home's Kilter card uses).
- **Journal entries are deferred** (recorded): `JournalEntry` has no stable id, so indexing them needs a
  schema migration (+ `SnappetBackup` row) — out of scope for this phase; the AC is exercise/climb.
- CoreSpotlight indexing works on the simulator; an actual Spotlight tap → `onContinueUserActivity` is
  device-verified. The `snappet://` scheme is already registered (Info.plist).

## Approach

1. **`Snappet/Spotlight/SpotlightItemSpec.swift`** — a **pure** `SpotlightItemSpec` (identifier =
   `snappet://` URL, domain, title, description, keywords) + `SpotlightCatalog` builders
   (`exerciseSpec(_:)` from an `Exercise`; `createdClimbSpec(uuid:name:setter:angle:)` via
   `KilterClimbLink`). Unit-tested — no CoreSpotlight, no device.
2. **`Snappet/Spotlight/SpotlightIndexer.swift`** — the CoreSpotlight edge: build `CSSearchableItem`s
   from the specs (catalog exercises + a `KilterCreatedClimb` fetch) and
   `CSSearchableIndex.default().indexSearchableItems`. Indexed once on launch; gated off under
   `-uiTest*` (don't pollute the device index / waste work in tests).
3. **`SnappetDeepLink.exercise(id:)`** — parse `snappet://exercise/<id>` (pure, unit-tested).
4. **`RootShell`** — extract the `onOpenURL` switch into `handle(_ url:)`; add the `.exercise` case
   (resolve `ExerciseCatalog.all` → `open(module: "workout-log")` + `push(exercise)`); add
   `.onContinueUserActivity(CSSearchableItemActionType)` → identifier → URL → `handle`. Index on `.task`.

## Output

- `ios/App/Snappet/Spotlight/SpotlightItemSpec.swift`, `ios/App/Snappet/Spotlight/SpotlightIndexer.swift` — new.
- `ios/App/Snappet/Features/Kilter/KilterDeepLink.swift` — `SnappetDeepLink.exercise(id:)`.
- `ios/App/Snappet/Features/Shell/RootShell.swift` — `handle(_:)`, `.exercise`, `onContinueUserActivity`, index on launch.
- `ios/App/SnappetTests/SpotlightIndexTests.swift` — spec building + the exercise route parse.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`; check the #100 box.

## Acceptance criteria

- [ ] Exercises + created climbs are indexed as `CSSearchableItem`s (built by the pure, tested spec).
- [ ] `xcrun simctl openurl snappet://exercise/<id>` opens the exercise's detail; a created climb's
      `snappet://kilter/climb/<uuid>` opens the climb (existing path).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6); full sim suite green.
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated (Spotlight reuses the URL routing; journal-entry indexing deferred).

## Constraints

- On-device only; no backend/network/accounts. CoreSpotlight is a local index.
- Reuse the `snappet://` routing — the Spotlight identifier IS the deep-link URL; one routing brain.
- Verify honestly: the real Spotlight search result + the tap→`onContinueUserActivity` round-trip are
  device-confirmed; the sim verifies the spec building, the route parse, the index call, and
  `simctl openurl` routing.

## Test plan

1. `cd ios/App && xcodegen generate` clean; app + widget build (`build-for-testing`).
2. Unit (sim): `SpotlightIndexTests` (exercise/climb spec ids + fields; `snappet://exercise/<id>` parse).
3. Full sim suite green (this phase changes app routing → run `SnappetUITests` too).
4. Deep link (sim): `xcrun simctl openurl snappet://exercise/<a-real-catalog-id>` opens the detail.
5. Device-pending: real Spotlight indexing visibility + a Spotlight-result tap.
