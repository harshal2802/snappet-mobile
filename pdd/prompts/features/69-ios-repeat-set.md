# Prompt: Repeat set — log an identical set with a single tap

**File**: pdd/prompts/features/69-ios-repeat-set.md
**Created**: 2026-06-16
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Workout-with-timer initiative — **PR 3 of 6** (the one-tap repeat-set loop). Ideated + architected 2026-06-15 on this branch.
**Source**: In-repo ideation + architecture plan — Gym Tracker "Workout with timer" (timed sets · repeat-set loop · free-flow climb sessions · tracking-type search), 2026-06-15.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

In the freeform workout player, let the user log another set **identical to the most recent one with a
single tap** — no sheet. Each exercise that already has ≥1 logged set gains a **"Repeat set"** control
that appends a copy of that exercise's last set — copying every kind-specific field (reps/weight/unit, OR
durationSec, OR climb grade/status/attempts depending on `SetKind`) with a fresh `completedAt = .now` —
and persists. Tapping repeatedly logs a quick "loop" of identical sets (straight sets of 3×8 @ 60, a
bouldering burn of the same problem) without reopening `LogSetSheet` each time. The slowest part of the
existing flow is re-typing the same numbers; this removes it for the common case.

## Context the implementer needs

- **Reuse the one append+persist path.** `FreeformPlayerView.appendLog(_:toExerciseID:)` is where a
  committed `SetLog` is stamped (`completedAt = .now`), appended to `session.exercises[idx].sets`,
  persisted (`persist()` → `context.save()`), pushed to the Live Activity, and given `Haptics.success()`.
  Repeat must funnel through this exact path — it is just another producer of a `SetLog`, not a second
  save site.
- **The duplicate is pure.** Copying a `SetLog` with a fresh stamp is `SetLog`-shaped logic with no view
  or SwiftData — it belongs in the pure `SetMeasure` (next to `summary`/`hasInput`/`isSend`), so it is
  the one definition of "duplicate a set" and is unit-tested without a device (the
  repo's pure-logic-at-a-thin-edge rule). `SetLog` is a `Codable` value with all-optional additive
  fields, so a struct copy carries every kind's fields verbatim.
- **One sheet, untouched.** `LogSetSheet` and the `freeform.addSet` path (and every `SetKind`'s existing
  behavior) do not change — Repeat is a sibling control, not a new mode of the sheet.
- **Leaf identifiers only (PR 2 lesson).** On iOS 26, applying `.accessibilityIdentifier` to a
  composite/custom view collapses its accessibility subtree and hides child controls from XCUITest. The
  Repeat control must be a leaf `Button` with `accessibilityIdentifier("freeform.repeatSet")`, a sibling
  of the `freeform.addSet` button (not wrapped). Freeform set rows are content HStacks tagged
  `freeform.setRow`, queried type-agnostically (`descendants(matching: .any).matching(identifier:)`),
  NOT `app.cells[...]`.

## Approach

1. **Pure duplicate — `SetMeasure.swift`**: add `duplicate(_ set: SetLog, now: Date) -> SetLog` — a
   struct copy with `completedAt = now` (all kind-specific fields carry over). `now` is injected for
   deterministic tests; the player passes `.now`. Pure, `SetMeasure`-style, unit-tested.
2. **`FreeformPlayerView.swift`**:
   - A `repeatLastSet(_ ex: SessionExercise)` mutation: `guard let last = ex.sets.last`, then
     `appendLog(SetMeasure.duplicate(last, now: .now), toExerciseID: ex.id)` — reusing the one
     append+persist+haptic path. No-op when the exercise has no sets.
   - In `exerciseSection(_:)`, beside the `freeform.addSet` button, a sibling leaf `Button` "Repeat set"
     gated by `if !ex.sets.isEmpty`, with `accessibilityIdentifier("freeform.repeatSet")`. Hidden when
     the exercise has no set to repeat.
3. **Knowledge graph**: the action lives on the existing freeform player (no new surface) — update the
   `wt-freeform-player` node description to note the one-tap repeat-set loop. No new node/edge.

## Output

- Changed: `ios/App/Snappet/Features/WorkoutTracker/SetMeasure.swift` (add `duplicate`),
  `ios/App/Snappet/Features/WorkoutTracker/FreeformPlayerView.swift` (`repeatLastSet` + the
  `freeform.repeatSet` control).
- Tests: extend `ios/App/SnappetTests/SetMeasureTests.swift` (`duplicate` carries every kind's fields,
  replaces only the stamp); new `ios/App/SnappetUITests/RepeatSetTests.swift` (Quick Start → Lifting
  exercise → log one set → tap `freeform.repeatSet` → assert a second `freeform.setRow` with the same
  value appears, count 1→2, no sheet).
- `docs/knowledge-graph/data.js`: update the `wt-freeform-player` node desc (one-tap repeat-set loop);
  no new node/edge.
- `pdd/context/decisions.md`: a 2026-06-16 entry — Repeat as a pure `SetMeasure.duplicate` funnelled
  through the one `appendLog` path; a sibling leaf control gated on `!sets.isEmpty`; sheet/SetKinds
  unchanged.

## Acceptance criteria

- [ ] In the freeform player, an exercise with ≥1 logged set shows a one-tap "Repeat set" control; it
      appends a copy of the most recent set (every kind-specific field, fresh `completedAt`), persists,
      and fires a haptic — WITHOUT opening `LogSetSheet`. The control is hidden when the exercise has no
      sets.
- [ ] Tapping it repeatedly logs a loop of identical sets (each new `freeform.setRow` reads the same
      value as the source set).
- [ ] "Add set" (the sheet path) and every `SetKind`'s existing behavior are unchanged.
- [ ] `SetMeasure.duplicate` copies all of reps/weight/unit · durationSec · climb grade/status/attempts
      and replaces only `completedAt` — covered in `SetMeasureTests` without a simulator.
- [ ] A UI test taps `freeform.repeatSet` once and asserts the row count goes 1→2 with the same value
      (rows queried type-agnostically), and that no log sheet opened.
- [ ] The app type-checks against the iOS 18 SDK (Swift 6, 0 warnings); `HighlightEngine`, the watch and
      the widget are untouched.
- [ ] `docs/knowledge-graph/data.js` and `pdd/context/decisions.md` updated in this change.

## Constraints

- On-device only; no backend / network / accounts.
- **Reuse, don't re-implement.** Funnel Repeat through the existing `appendLog` append+persist+haptic
  path and the pure `SetMeasure`; do not add a second save site or duplicate the stamp/persist logic.
  `LogSetSheet`, `build()`, and `SetLog` are unchanged.
- Leaf `accessibilityIdentifier` only (PR 2 lesson): the Repeat control is a sibling leaf `Button`, never
  wrapped in a composite that would hide it from XCUITest.
- Do not touch the device-verified guided `WorkoutPlayerView`, the watch/widget targets, `HighlightEngine`,
  or release workflows.
- Honest verification: a clean type-check ≠ a device run. The orchestrator runs the simulator suite; this
  change ships `xcodegen generate`-verified plus the pure `SetMeasureTests`.

## Test plan

1. `cd ios/App && xcodegen generate`, then
   `xcodebuild test -scheme Snappet -only-testing:SnappetTests/SetMeasureTests
   -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (orchestrator); plus
   `-only-testing:SnappetUITests/RepeatSetTests` for the one-tap loop.
2. By eye on the sim: Quick Start → add a Lifting exercise → log a set → tap "Repeat set" twice → three
   identical rows appear with no sheet; confirm Climbing and Timed exercises repeat their last set the
   same way, and that the control is absent on an exercise with no logged set.
