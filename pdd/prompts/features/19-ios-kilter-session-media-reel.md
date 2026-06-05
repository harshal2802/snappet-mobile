# Prompt: Kilter session — per-climb media, full-length uncapped reels, studio parity

**File**: pdd/prompts/features/19-ios-kilter-session-media-reel.md
**Created**: 2026-06-05
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follow-up to `18-ios-kilter-rich-session.md` (Kilter rich session).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Close three gaps the user hit using the Kilter rich session: (1) media isn't shown *per climb*, (2) the
highlight reel trims clips and caps total length, (3) less editing control than the workout studio. Deliver
all three by **reusing** the workout media/studio components, which are domain-agnostic.

## Context the implementer needs

- Every Kilter clip is already tagged to a climb via `SessionMedia.assignedClimbUUID`
  (`KilterSessionManager.discoverMedia`), but `KilterSessionDetailView` only showed a session-wide count.
- The reel length limit lives in four places: `ReelPlanner(targetDuration: 30)` (total cap),
  `HighlightConfig.clipLeadSec/clipTrailSec` (per-clip trim), `maxHighlights`, and `photoStill`. The user
  wants full-length clips + no cap, applied to **both** workout and Kilter (their choice).
- `ClipEditorView(media:)`, `StudioEditorView(project:context:)`, and `ReelView` have no workout-specific
  coupling — keyed by `SessionMedia` / `StudioProject` / `Highlight[]`. `SessionMediaThumb` is already public.
  `ReelView`/`ReelViewModel` were the only piece tied to `WorkoutSummary`.

## Approach

- **Engine**: `HighlightConfig.fullClips` (default false) + `fullLength()`; `HighlightSelector` emits one
  full-length, deduped-by-media segment per featured clip when set; `ReelPlanner.targetDuration` → `Double?`
  (`nil` = uncapped). `AppModel.engine` uses `targetDuration: nil`; `ReelViewModel.generate` passes
  `.preset(for: activity).fullLength()`.
- **Reel reuse**: generalize `ReelViewModel`/`ReelView` to a `ReelSource { id, activity, title, start,
  makeWorkout(model, manualMedia) }`; keep `ReelView(summary:)` as a back-compat shim; add
  `ReelSource.kilterSession(_:media:)` (built via `KilterWorkoutBuilder`).
- **Kilter UI** (`KilterSessionDetailView`): per-climb media strips in the timeline + an Unassigned strip
  (pure `KilterMediaGrouping`), reuse `SessionMediaThumb`; "Move to climb…" reassign; tap a video →
  `ClipEditorView`; "Open studio" → seed a `StudioProject(sessionID: kilterSession.id, …)` → `StudioEditorView`;
  "Highlight reel" → the shared `ReelView`.

## Acceptance criteria

- [x] Each logged climb shows its tagged photos/videos in the summary; clips are reassignable between climbs.
- [x] The reel plays full-length clips with no length cap (workout + Kilter).
- [x] Tapping a clip opens the trim/speed/crop/text editor; the multi-clip Studio opens for a session.
- [x] `HighlightEngine` `swift test` green (21); `xcodebuild test` green (267); app + widget + watch build.
- [x] No platform imports added to `HighlightEngine`; engine defaults (and their tests) unchanged.
- [x] `decisions.md` + knowledge graph updated.

## Constraints

- On-device only; selector stays pluggable. Engine defaults preserve old behavior (full-length is opt-in via
  config). Verify honestly: clip-editor/studio/reel render + export need a device with real footage.

## Test plan

1. `cd ios/HighlightEngine && swift test` — full-clip dedupe + full-length window + nil-budget.
2. `cd ios/App && xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
3. Device: open a session summary → per-climb strips, reassign, clip editor, studio, and a full-length reel.
