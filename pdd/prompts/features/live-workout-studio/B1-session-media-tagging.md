# Prompt: session media tagging (photos/videos shot during a workout)

**File**: pdd/prompts/features/live-workout-studio/B1-session-media-tagging.md
**Created**: 2026-06-01
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `live-workout-studio/PLAN.md` → Track B → **B1** (the video-studio data foundation).
**Source**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15); `RESEARCH.md` §3.4.
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`, `snappet-core-schema.md`.

## Goal

Let a WorkoutTracker session collect the **photos/videos taken during it** — auto-discovered by
capture-time window and/or manually added — stored as **session-scoped tags** and shown in the session
summary. This is the user's "see the video/photos taken during the same workout". It is the data
foundation B2 (enriched summary), B3 (clip editor), and B4 (highlight generation) build on.

## Context the implementer needs

- A `WorkoutSession` (`Features/WorkoutTracker/WorkoutModels.swift`) already has `id`/`startedAt`/
  `completedAt` — the only inputs B1 needs (no dependency on Track A or the watch).
- The flagship Reels app's `Services/PhotoLibraryService.swift` already does **time-window PHAsset
  discovery** + the `creationDate → offset` mapping + `.limited`-access handling, with a **±90 s pad**.
  **Reuse those patterns**, now keyed on the `WorkoutSession` interval instead of an `HKWorkout`.
- `Services/MediaPicker.swift` is the PHPicker (`photoLibrary: .shared()`, returns `assetIdentifier`s) —
  the limited-access / manual-add fallback. Reuse it.
- `NSPhotoLibraryUsageDescription` already exists in the app `Info.plist` (from the Reels app).
- SwiftData `@Model`s register in the single `Core/SnappetCore.swift` `SnappetSchema.models` line, keyed
  by `UUID` FK (no `@Relationship`) — the suite convention.
- Modules don't nest a `NavigationStack`; `SessionDetailView` is pushed into the App Library's stack.

## Approach

Respect the layering rule — `HighlightEngine` stays platform-free (grep-verify); platform I/O in
`Services/`; the new `@Model` in the feature folder, registered centrally.

1. **`@Model SessionMedia`** (`Features/WorkoutTracker/`): `id: UUID`, `sessionID: UUID` (FK to
   `WorkoutSession.id`, NOT a relationship), `localIdentifier: String` (PHAsset id), `kind` (photo/video
   as a raw string), `offsetSec: Double` (capture time relative to `startedAt`, clamped ≥ 0),
   `durationSec: Double?`, `addedManually: Bool`, `createdAt: Date`. Register it in `SnappetSchema.models`.
2. **`SessionMediaService`** (`Services/`): auto-discover PHAssets whose `creationDate ∈ [startedAt,
   completedAt] ± pad` (reuse `PhotoLibraryService`'s window logic + `.limited` handling), each mapped to a
   `SessionMedia` (offset clamped ≥ 0). Skip assets already tagged for that session (dedupe by
   `localIdentifier`). Manual-add path via `MediaPicker` (`addedManually = true`) + a remove. **Isolate the
   pure mapping** (creationDate + interval → in-window predicate / offset / dedupe) as testable static
   funcs so it is unit-testable without Photos.
3. **UI** — in `SessionDetailView`, add a **tagged-media gallery** section: thumbnails via
   `PHImageManager`, ordered by `offsetSec`, with a "+Ns" offset badge + a video play glyph; an "Add
   photos/videos" PHPicker button; long-press remove; and a "Find media from this workout" auto-discovery
   action that also fires once on first appear (silently, full-access only). Request Photos access
   value-first (reuse `requestAccess`). Keep the view thin; no nested `NavigationStack`.
4. Query `SessionMedia` for the session via `@Query` with a `#Predicate` on `sessionID`.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/SessionMedia.swift` — the `@Model`.
- `ios/App/Snappet/Services/SessionMediaService.swift` — discovery + manual-add + the pure mapping.
- `ios/App/Snappet/Features/WorkoutTracker/SessionDetailView.swift` — gallery section + thumbnail view.
- `ios/App/Snappet/Core/SnappetCore.swift` — `SessionMedia.self` in `SnappetSchema.models` (one edit).
- `ios/App/Snappet/Core/AppModel.swift` — own + inject `SessionMediaService`.
- `ios/App/SnappetTests/SessionMediaMappingTests.swift` — pure-mapping unit tests.
- `pdd/context/decisions.md` — the B1 shape + reuse + device-pending entry.

## Acceptance criteria

- [ ] `SessionMedia` registered in `SnappetSchema.models`; keyed by `sessionID` FK (no `@Relationship`).
- [ ] Auto-discovery returns assets in `[startedAt, completedAt] ± pad`, offset = clamped seconds since
      `startedAt`, deduped by `localIdentifier`; `.limited` access routes to the PHPicker.
- [ ] The pure mapping (window predicate incl. ±pad boundaries, offset clamp, dedupe) is unit-tested in
      `SnappetTests` with no Photos.
- [ ] `SessionDetailView` shows the gallery (thumbnails, offset badge, video glyph) + add/remove; empty
      state on the simulator (no Photos).
- [ ] No platform import added to `HighlightEngine` (grep-verified).
- [ ] App + watch schemes build for their sims (Swift 6); `SnappetTests` + `WorkoutWalkthroughTests` green;
      `HighlightEngine` 18/18.

## Constraints

- On-device only; no backend/network/accounts. `PHImageRequestOptions.isNetworkAccessAllowed = false`.
- `.limited` Photos access can't be scanned by time window → PHPicker fallback (don't assume full-library).
- SwiftData: additive `@Model` + one `SnappetSchema.models` line; UUID FK, no `@Relationship`.
- Swift 6 strict concurrency; `@MainActor` UI; bridge PhotoKit callbacks with continuations.
- State verification honestly: model + service + UI + pure mapping are verified by build/tests, but **live
  auto-discovery + thumbnails need a device with media** — the simulator has none. A clean build is **not**
  verified Photos discovery.
