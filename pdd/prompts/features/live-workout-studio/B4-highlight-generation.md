# Prompt: Engine-driven highlight generation (WorkoutTracker ↔ HighlightEngine bridge)

**File**: pdd/prompts/features/live-workout-studio/B4-highlight-generation.md
**Created**: 2026-06-01
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `live-workout-studio/PLAN.md` → Track B → **B4** (builds on B1 tagged media, B2 `hrSeries`,
B3 editor/`VideoStudio`; feeds B5 share/save).
**Source**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15); `RESEARCH.md` §3.6.
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (2026-05-30/31 engine + `ReelExporter`
+ pin/order; 2026-06-01 A–B entries).

## Goal

From a finished session's **HR series** (B2 `hrSeries`) + **tagged video clips** (B1 `SessionMedia`) + the
user's **selection**, generate a highlight reel using the **EXISTING** `HighlightEngine` — the user's
"generate highlight videos based on user selection". This finally connects the set-logger to the proven
flagship algorithm. **No engine change.**

## Context the implementer needs

- `HighlightEngine` (pure, platform-free, **UNCHANGED**): `Workout`/`HRSample`/`MediaItem`/`Activity`/
  `Highlight` (`Model.swift`), the `HighlightSelector.select(workout:config:)` pipeline, and
  `ReelPlanner.plan(highlights:media:pinnedIds:order:)` → `ReelPlan` (`ReelPlan.swift`). The planner pins by
  **highlight** id and treats pinned highlights as **budget-exempt** (decisions.md 2026-05-30).
- `AppModel` already wires the engine: `app.engine` (HR selector + `ReelPlanner(targetDuration: 30)`) and
  `app.reelPlan(for:media:pinnedIds:order:)`. **Reuse these** — keep engine access on the `@MainActor`.
- `Services/ReelExporter.swift` turns a `ReelPlan` into a video on-device: `makeComposition(for:) async ->
  sending AVMutableComposition` (reused for BOTH `AVPlayer` preview and export) + `export(_:)`. **Reuse it
  to render** — don't reimplement reel stitching.
- B1 `SessionMedia` (`localIdentifier`, `kind`, `offsetSec`, `durationSec?`) is the tagged-clip source; B2
  `WorkoutSession.hrSeries: [HRPoint]` (`t`/`bpm`, `startedAt`-relative) is the HR source. `WorkoutActivityMapping`
  already maps a routine's sport/category for the live path (HK direction); B4 needs the **engine `Activity`** direction.
- Layering rule: `HighlightEngine` stays platform-free (grep-verify). Modules don't nest a `NavigationStack`
  — the generation UI is a **sheet** (which may own its own stack).

## Approach

1. **Pure bridge** — `Features/WorkoutTracker/SessionHighlightInput.swift` (an `enum` of static mappers + a
   plain-value `Clip` struct, **no SwiftData/AVFoundation/Photos**, unit-testable with no device):
   - `hrSamples(from: [HRPoint]) -> [HRSample]` — 1:1 (`t`/`bpm`).
   - `mediaItem(from: Clip, defaultDuration:) -> MediaItem?` — video → `.video` (`id = localIdentifier`,
     `startOffset = offsetSec` clamped ≥ 0, `duration = durationSec ?? default`); a video with no resolvable
     duration **and** no default is **skipped** (windowless); photo → `.photo` (duration `0`, Ken-Burns still).
   - `activity(sport:category:) -> Activity` — `SportTag` (stronger) then dominant `ExerciseCategory` →
     engine `Activity`, defaulting to `.strength` (generic gym). Targets the engine's coarse `Activity`, not
     `HKWorkoutActivityType` (keeps the engine platform-free) — mirrors `WorkoutActivityMapping`'s *direction*.
   - `makeWorkout(hrSeries:clips:duration:sport:category:)` → `Workout`; `pinnedIds(forSelected:) -> Set<String>`.
2. **Generate** — `Features/WorkoutTracker/SessionHighlightViewModel.swift` (`@MainActor @Observable`): snapshot
   the `@Model`s into `[HRPoint]` + `[Clip]` on the `@MainActor`, bridge → `Workout`, run **`app.engine.selector
   .select(workout:config: .preset(for:))`** → `[Highlight]`, expand the user's selected **clip** ids to the
   **highlight** ids on those clips (budget-exempt pins), `app.reelPlan(for:media:pinnedIds:)` → `ReelPlan`,
   then **`ReelExporter.makeComposition`** → an `AVPlayer` preview. The non-Sendable `@Model` never crosses
   into the engine/exporter.
3. **UI** — `Features/WorkoutTracker/SessionHighlightView.swift` (a **sheet** owning its own `NavigationStack`):
   a clip-selection list (toggle which tagged **videos** to include, default = all), a **Generate** action, and
   an inline `VideoPlayer` preview of the result. Opened from a **"Generate highlight"** button in
   `SessionDetailView`'s media section, **enabled only when the session has a tagged video**. Views thin.
4. **B3 `ClipEdit`s** are **NOT** applied to the reel segments in B4 (deferred — see decisions): B4 generates
   from the raw tagged clips. Reel-level per-segment edit integration is a B5/later concern.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/SessionHighlightInput.swift` — the pure bridge mapping.
- `ios/App/Snappet/Features/WorkoutTracker/SessionHighlightViewModel.swift` — bridge → engine → plan → preview.
- `ios/App/Snappet/Features/WorkoutTracker/SessionHighlightView.swift` — the selection + generate + preview sheet.
- `ios/App/Snappet/Features/WorkoutTracker/SessionDetailView.swift` — "Generate highlight" entry + sport/category wiring.
- `ios/App/Snappet/Features/WorkoutTracker/WorkoutTrackerModule.swift` — pass the routine's `sport` into the detail view.
- `ios/App/SnappetTests/SessionHighlightInputTests.swift` — pure bridge-mapping unit tests.
- `pdd/context/decisions.md` — the B4 bridge design + device-pending entry.

## Acceptance criteria

- [ ] The bridge is a pure value-mapping (no SwiftData/AVFoundation/Photos import); unit-tested in `SnappetTests`:
      `hrSeries → [HRSample]` 1:1, `Clip → MediaItem` (offset/kind/duration, default-when-nil, skip-when-windowless,
      photos vs videos), activity mapping, selected-clip-ids → `pinnedIds`.
- [ ] Generation runs the **EXISTING** `app.engine` selector + `ReelPlanner` and renders via **`ReelExporter`** —
      no engine change, no reel-stitch reimplementation.
- [ ] Selected clips become budget-exempt pins (expanded to the highlight ids on those clips).
- [ ] "Generate highlight" is disabled with no tagged video; the sheet owns its own `NavigationStack`; views thin.
- [ ] No platform import added to `HighlightEngine` (`git diff ios/HighlightEngine` empty).
- [ ] App + watch schemes build; `SnappetTests` + `WorkoutWalkthroughTests` green; `HighlightEngine` 18/18.

## Constraints

- On-device only; no backend/network/accounts. Reuse `ReelExporter` (`isNetworkAccessAllowed = true` there is
  iCloud-fetch for the user's own clips, on-device-only otherwise — unchanged).
- Swift 6 strict concurrency: engine access stays on the `@MainActor`; the `@Model`s are snapshotted into plain
  `[HRPoint]`/`[Clip]` on the `@MainActor` caller; the exporter's `Box`/`sending` discipline is reused as-is.
- No new `@Model` (the inputs already exist: `WorkoutSession.hrSeries`, `SessionMedia`) → no `SnappetSchema.models` change.
- State verification honestly: the bridge mapping + `ReelPlan` generation + the UI wiring are verified by
  build/tests; the **rendered highlight video** needs real video on a device (the sim has no Photos/video) — a
  clean build is **not** a verified rendered reel. The walkthrough sim session has no media/HR, so "Generate
  highlight" stays disabled there — assert it doesn't crash the summary.
