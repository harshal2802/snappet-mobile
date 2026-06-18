# Prompt: Quick Session — climb-first hierarchy (Phase 1)

**File**: pdd/prompts/features/quick-session-redesign/01-climb-first-hierarchy.md
**Created**: 2026-06-18
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `quick-session-redesign/PLAN.md` → Phase 1
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`; design in `docs/ux-research/quick-session-redesign/` (`README.md` §6, `wireframes.md` surfaces 2–3)

## Goal

Turn the freeform **Climbing** flow from flat attempt rows into a **climb-first hierarchy**: tapping
Climbing opens an **"Add a climb"** sheet that captures the climb's TYPE (boulder/top-rope/lead/sport),
GRADE (scale-aware discrete picker), optional NAME and GYM; the climb then renders as an **expandable
card**, and **attempts are logged underneath it** (grade no longer re-entered per attempt). This fixes
"you can't group three tries on the same V4 project."

## Foundation already in place (DO NOT re-create)

These pure types + model fields are committed and unit-tested — build on them:
- `ClimbGrade.swift`: `ClimbType` (boulder/topRope/lead/sport; `label`, `symbol`, `isRoute`,
  `defaultScale`, `scales(selected:)`, `statusLabel(_:)`) and `GradeScale` (`vScale/font/yds/french`;
  `rungs`, `difficulty(for:)`, `companion`, `shortLabel`, `defaultGrade`, `isBoulderScale`).
- `SessionExercise` new additive fields: `climbTypeRaw`, `climbGradeLabel`, `climbGradeScaleRaw`, `gym`
  + computed `climbType`, `climbGradeScale`, `resolvedClimbStatus`.
- `FreeformClimbStats.swift` (used in Phase 3 — leave as-is).
- Outcomes still use `KilterAscentStatus` (flash/sent/project/attempt); route types only relabel via
  `ClimbType.statusLabel`.

## Context the implementer needs

- The whole flow lives in **`FreeformPlayerView.swift`** (a `List` with a title section, an empty-state
  hero with three type cards `freeform.cardLifting/cardClimbing/cardTimed`, and one `Section` per
  `SessionExercise`). Today `addExercise(kind:.climbAttempt, name:"Climbing")` adds a bare climb row and
  every attempt opens `LogSetSheet(.climbAttempt)` capturing grade+outcome+attempts (+optional timer).
  `ClimbNameHeader` inline-edits the climb name (`freeform.climbName`).
- Heavily **UITest-instrumented**. Existing climb UITests will break and MUST be updated to the new
  flow: `SnappetUITests/NamedClimbTests.swift`, `ClimbAttemptTimerTests.swift`,
  `FreeformFlowWalkthroughTests.swift`, `TrackingTypeFilterTests.swift`. Read them; preserve identifiers
  where an equivalent control exists (`freeform.cardClimbing`, the session title, Finish `freeform.finish`).
- iOS-26 / XCUITest gotchas to respect (see existing comments): use `confirmationDialog`, NOT a
  toolbar `Menu`, for action lists; do NOT put an `accessibilityIdentifier` on a `StopwatchView`
  (collapses its inner `stopwatch.toggle`); custom `+`/`−` leaf buttons (not native `Stepper`) so each
  control is queryable; the leaf-only a11y rule for interactive controls.

## Approach

Edit `FreeformPlayerView.swift`; add a new `AddClimbSheet` view (same file or a new
`AddClimbSheet.swift` in WorkoutTracker). Reuse `snappetCard`/`snappetTile`, `SnappetColor.workout`
(CTAs/accents), `SnappetColor.kilter` (boulder grade pill), the existing command bar.

1. **Entry points.** The empty-state **Climbing** card (`freeform.cardClimbing`) and the
   `confirmationDialog`'s **Climbing** button now present `AddClimbSheet` instead of calling
   `addExercise(kind:.climbAttempt,…)`. (Keep Lifting + Timed unchanged this phase.)

2. **AddClimbSheet** (`.medium`/`.large` detents). Captures, with sensible defaults:
   - **TYPE** segmented `Picker` (Boulder/Top-rope/Lead/Sport), id `addClimb.type`. Changing type resets
     the grade scale to the type's `defaultScale` and the selected grade to that scale's `defaultGrade`.
   - **GRADE**: a scale-aware horizontal rung picker (`ScrollView(.horizontal)` of tappable rung pills
     from `scale.rungs`, selected one filled) + a recent-grades chip rail (persist the last ~5 grades
     per scale in `@AppStorage`/`UserDefaults`, e.g. key `freeform.recentGrades.<scale>`) + a small
     V/Font (or YDS/French) toggle (`scale.companion`). Container id `addClimb.grade`; expose the
     selected grade label on a queryable element (`addClimb.gradeValue`).
   - **NAME** (optional) `TextField`, id `addClimb.name`. Empty → fall back to the type label (e.g.
     "Boulder") via a small helper, NOT "Climbing".
   - **GYM** (optional) `TextField` under a "More" disclosure, id `addClimb.gym`; default to the
     session's most recent climb `gym` (inherited).
   - CTAs: **"Add & log first attempt"** (`addClimb.addAndLog`, prominent ember) creates the climb and
     immediately shows the inline outcome strip on its (auto-expanded) card; **"Add climb"**
     (`addClimb.add`, bordered) just creates the card.
   - On add: append a `SessionExercise(exerciseId:"adhoc-climbAttempt", kind:.climbAttempt,
     displayName:name, climbTypeRaw:type, climbGradeLabel:grade, climbGradeScaleRaw:scale, gym:gym)`,
     persist, push Live Activity, auto-scroll to it (the existing `onChange(count)` handles scroll).

3. **Climb card** (replaces the generic climb `Section` rendering for `.climbAttempt`). Rolled-up
   header: `climbType.symbol` icon · name · a **grade pill** (`gpill`-style: `climbGradeLabel` on a
   `SnappetColor.kilter` (boulder) / cool (route) capsule) · a **status badge** from
   `resolvedClimbStatus` (Sent ✓ leaf, Flash ⚡, Project ◷ ember, Attempt ○) · "N attempts" ·
   time-on-climb (from the climb's attempt stamps; reuse `FreeformClimbStats.log(for:)?.timeOnClimb` or
   compute). Tapping the header expands/collapses (inline) to the attempt list + footer. Keep the climb
   **name inline-editable** (reuse `ClimbNameHeader`, `freeform.climbName`). Keep the per-exercise
   remove menu.

4. **Attempt logging (untimed).** Expanded card footer shows **"+ Log attempt"** (`freeform.logAttempt`)
   → an **inline outcome strip** (NOT a full sheet): four type-aware outcome buttons
   (`ClimbType.statusLabel`), each appends a `SetLog(completedAt:.now, climbStatusRaw:status,
   climbGradeLabel:<climb grade>, climbAttempts:1)` via `appendLog`. Flash/Sent are "close the climb";
   Project/Attempt "keep open" — but for Phase 1 simply append the attempt with that status (no special
   close behavior needed beyond `resolvedClimbStatus` reflecting it). Also keep a **"Timed attempt"**
   button (`freeform.timedAttempt`) that, FOR NOW (Phase 2 replaces with a FOCUS cover), opens a minimal
   sheet hosting `StopwatchView(.countUp)` → on Stop, append a `SetLog` with `durationSec` + an outcome
   picked inline. Each attempt **row** shows the **attempt summary** (outcome + optional duration; NOT
   the grade — that's on the header) via a new `SetMeasure.attemptRow(_:type:)`; rows remain
   swipe-to-delete. Keep the one-tap **Repeat last** (re-logs the last outcome).

5. **Formatting.** Add `SetMeasure.attemptRow(_ set:SetLog, type:ClimbType) -> String` (e.g.
   "Sent · 0:42", "Onsight", "Project · 2 tries") for the per-attempt row. Leave the existing
   `SetMeasure.summary(.climbAttempt)` (grade·status·tries·time) for history/back-compat. `FreeformSummary`
   already reads per-`SetLog` grade — since attempts are stamped with the climb grade, sends/pyramid/
   milestones keep working; verify `sendCount`/`milestones` still pass.

6. **Tests.**
   - Extend `SetMeasureTests` for `attemptRow`.
   - Update the four UITests above to the new flow: tap **Climbing** card → AddClimbSheet → pick type →
     pick a grade rung → (name) → **Add & log first attempt** → pick an outcome → assert the climb card
     shows the grade pill + status + the attempt row; the climb-name rename test drives `freeform.climbName`
     on the card. Keep `TimedSetTimerTests`/`RepeatSetTests`/`QuickAddSetTests` green (timed/lifting
     unchanged this phase). If a UITest can't be made reliable, mark it skipped with a clear comment
     (don't delete coverage silently).

## Output

- `FreeformPlayerView.swift` (restructured climb section + entry points) and `AddClimbSheet.swift` (new).
- `SetMeasure.swift` (`attemptRow`) + `SetMeasureTests.swift`.
- Updated `NamedClimbTests`, `ClimbAttemptTimerTests`, `FreeformFlowWalkthroughTests`,
  `TrackingTypeFilterTests`.
- A `decisions.md` entry (climb-first hierarchy; grade stamped onto attempts; ember-not-coral; route
  status relabels reuse `KilterAscentStatus`).

## Acceptance criteria

- [ ] Tapping **Climbing** opens **Add a climb** (type/grade/name/gym); a created climb is an expandable
      card with grade pill + status + attempt count.
- [ ] Logging an attempt does NOT ask for grade again; the attempt nests under the climb; three attempts
      on one climb appear as three rows of one card.
- [ ] Type drives the grade scale (Boulder→V/Font rungs; routes→YDS/French rungs); grade entry is a
      discrete picker, never a free-text field.
- [ ] `xcodegen generate` + `xcodebuild build-for-testing` clean (Swift 6, 0 warnings).
- [ ] Full `SnappetTests` green (incl. new `attemptRow` tests; `ClimbGradeTests`/`FreeformClimbStatsTests`
      still pass).
- [ ] The four updated climb UITests pass (run them); other UITests still compile.
- [ ] `decisions.md` updated.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild build-for-testing -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
2. `xcodebuild test-without-building -scheme Snappet -destination '…iPhone 17 Pro' -only-testing:SnappetTests` (all unit tests).
3. Run the updated climb UITests: `-only-testing:SnappetUITests/NamedClimbTests -only-testing:SnappetUITests/ClimbAttemptTimerTests -only-testing:SnappetUITests/FreeformFlowWalkthroughTests`. If the sim wedges ("Failed to synthesize event"), `xcrun simctl shutdown all` and retry once (decisions.md).
4. Commit on `claude/quick-session-redesign` with the prompt + code together. Do NOT commit if the build or unit tests are red — report what failed instead.
