# Prompt: Close the set-logging loop — prefill from last session, edit completed sets, search history

**File**: pdd/prompts/features/45-ios-set-logging-loop.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 2 (tracker QoL)
**Source**: GitHub issue [#73](https://github.com/harshal2802/snappet-mobile/issues/73)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The tracker forgets what you lifted and won't let you fix mistakes. Set 1 of every exercise
starts blank — `prefillInputs()` only looks within the current session, then a usually-nil
routine target (StarterRoutines ship none) — and there is no "Last time: 3×8 @ 60 kg"
reference at the moment the user picks today's weight. Once a session ends, sets are
read-only forever: a fat-fingered 1000 kg permanently corrupts PRs, the 8-week volume chart,
and per-exercise progress (all derive from stored `SetLog` values via `WorkoutMath` /
`WorkoutProgress`), and the only remedy is deleting the entire session — HR series and
tagged media included. And History — a flat month-grouped list — has no search, filter, or
sort. Close all three holes.

## Context the implementer needs

- `WorkoutPlayerView.prefillInputs()` prefers `ex.sets.prefix(setIndex)` then falls back to
  `ex.targetWeight` / `targetReps`. No cross-session lookup exists anywhere; the player
  doesn't receive history. `WorkoutHomeView` already computes `history` (completed-only,
  newest-first via `@Query`) and passes it to other sections — hand it to the player too.
- `SessionDetailView`'s set tiles (`SetTileRow`, inside `SessionMediaSection`) are
  display-only; only media is mutable. `SessionExercise.sets` is a Codable composite array
  on the `@Model` `WorkoutSession`, so edits rewrite the array value and `context.save()`.
  Per-set media and HR-effort lookups key on `(exercise UUID, set index)` — edits must never
  add/remove/reorder sets or those keys desync.
- The live player's input sanity is exactly: reps `Int(trimmed)`, weight `Double` accepting
  a decimal comma; non-numeric → nil. Share one parser so the edit mode can't drift.
- Search precedent: `ExerciseBrowserView` (`.searchable` on the bare `List` + chip filters),
  `JournalRootView`, `KilterRootView`. History keeps its value-based `NavigationLink`
  (documented quirk — a Button never fired there).
- A freeform session can carry the same `exerciseId` twice — aggregate every occurrence
  (the `WorkoutMath` review-fix rule).

## Approach

1. **Cross-session prefill + hint — pure.** New `LastSetLookup` (enum, no SwiftData/UI):
   input prior sessions + `exerciseId`, output `LastTime { reps, weight, unit, hint }`. The
   most recent **completed** session with a usable completed reps/weight set decides; the
   prefill mirrors that session's last completed set; the hint summarizes all of them
   ("Last time: 3×8 @ 60 kg", "8/8/6" mixed reps, "55–60 kg" range, bodyweight omits
   weight). Wire into `prefillInputs()` between the current-session set (still wins) and
   the routine-target fallback; render the hint under the Target line.
2. **Edit completed sets — pure core, thin view.** New `SessionSetEditing` (enum):
   `drafts(for:)` builds text drafts for completed `.repsWeight` sets; `apply(drafts:to:)`
   parses them back via shared `SetMeasure.parseReps`/`parseWeight` (extracted from the
   player) touching only `actualReps`/`actualWeight`. `SessionDetailView` gets an
   Edit / Save / Cancel toolbar; while editing, each completed tile swaps to reps × weight
   fields (shared keypad focus + Done toolbar, the player's pattern). Save rewrites
   `session.exercises` + saves; `@Observable`/`@Query` propagate to PRs/volume/progress.
3. **History search + chip.** `.searchable` on the History list matching `routineName`,
   plus a horizontal routine-chip row (distinct names, most recent first, shown when >1);
   filtering is the pure `HistorySearch`. Filtered-empty state shows
   `ContentUnavailableView.search`.

## Output

- New: `Features/WorkoutTracker/LastSetLookup.swift`, `SessionSetEditing.swift`.
- Modified: `WorkoutPlayerView.swift` (history param, prefill chain, hint, shared parser),
  `WorkoutTrackerModule.swift` (pass history), `SessionDetailView.swift` (edit mode),
  `HistorySectionView.swift` (search + chips + `HistorySearch`), `SetMeasure.swift`
  (`parseReps`/`parseWeight`).
- Tests: `SnappetTests/LastSetLookupTests.swift`, `SessionSetEditingTests.swift` (incl. an
  in-memory SwiftData round-trip — container held as a property, the EXC_BREAKPOINT gotcha),
  `HistorySearchTests.swift`; parser cases in `SetMeasureTests.swift`.
- `docs/knowledge-graph/data.js`: wt-player / wt-session-detail / wt-history descs updated;
  `wt-last-set-lookup` + `wt-set-editing` model nodes + links.
- `pdd/context/decisions.md` entry.

## Acceptance criteria

- [ ] Repeating a routine prefills weight/reps from the previous session and shows a
      "Last time" hint under the target.
- [ ] A completed session's reps/weight can be corrected and PRs/volume/progress reflect
      the fix (recompute from the stored values).
- [ ] History search finds sessions by routine name; a routine chip filters with one tap.
- [ ] Prefill/lookup logic covered in `SnappetTests` without a simulator.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine` (untouched).
- [ ] `decisions.md` updated if a non-obvious choice was made.

## Constraints

- On-device only; no backend/network/accounts.
- Edit mode is reps/weight only: duration/climb sets and never-completed sets stay
  read-only; sets cannot be added/removed (media + HR keys depend on indices).
- The orchestrator runs the simulator suite — this change ships with `xcodegen generate`
  verified only.

## Test plan

1. `cd ios/App && xcodegen generate`, then
   `xcodebuild test -scheme Snappet -only-testing:SnappetTests/LastSetLookupTests
   -only-testing:SnappetTests/SessionSetEditingTests -only-testing:SnappetTests/HistorySearchTests
   -only-testing:SnappetTests/SetMeasureTests …` (orchestrator).
2. By hand on the sim: finish a routine session with logged weights → start the same
   routine → set 1 prefilled + "Last time" hint; open the finished session → Edit → fix a
   weight → Save → Dashboard PR/volume + ExerciseProgress reflect it; History → search a
   routine name, tap a chip.
