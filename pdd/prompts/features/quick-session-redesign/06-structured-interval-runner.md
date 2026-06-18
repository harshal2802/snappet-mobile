# Prompt: Quick Session — structured interval runner (Phase 6)

**File**: pdd/prompts/features/quick-session-redesign/06-structured-interval-runner.md
**Created**: 2026-06-18
**Chain**: `quick-session-redesign/PLAN.md` → Phase 6 (builds on Phase 5's `TimedExerciseSpec`)
**Context**: `pdd/context/*`; design reference (by title) `docs/ux-research/.../wireframes.md`: **"Timed exercise — live timed-set screen"** (lead-in, WORK/REST phases, set·rep counter, next-phase chip, capture card).

## Goal

For `.repeaters` / `.tabata` / `.emom` timed exercises, run a dedicated full-cover **interval runner**:
a 3-2-1 lead-in, a large phase label (WORK/REST), a draining count-down, a "Set 2/3 · Rep 3/6" counter,
a next-phase preview chip, color that telegraphs the phase before the beep (WORK = ember, REST = muted),
per-phase audio + haptic cues — and "the timer is the log": on finish, the completed reps·sets + total
time-under-tension are captured into the `SetLog` with one-tap confirm.

## Approach

1. **Pure schedule engine** `IntervalSchedule.swift` (in `ios/App/Shared/`, no SwiftUI): from a
   `TimedExerciseSpec`, produce the ordered `[Phase]` (`enum kind: leadIn, work, rest, restBetweenSets,
   done`; each with `durationSec`, `setIndex`, `repIndex`, a label, and the NEXT phase's label). Plus a
   pure `state(at elapsed: TimeInterval) -> (phase, remainingInPhase, overallRemaining, setRep)` so the
   running view is a thin wall-clock read (the `StopwatchTiming` pattern). Unit-test thoroughly
   (`IntervalScheduleTests`): total duration = `spec.totalSeconds`; phase boundaries; rep/set counts;
   tabata 20:10×8; emom; repeaters 7:3×6×3sets; edge (0 rounds, lead-in 0).
2. **`StructuredTimedRunner.swift`** full-cover view: drives off the schedule + a wall-clock anchor
   (reuse the `StopwatchViewModel` timing idiom or a small ticker). Big phase label + draining ring/bar
   (count-down, tabular digits), "Set i/n · Rep j/m", a "next ▸ <label>" chip, WORK = `SnappetColor.workout`
   (ember) / REST = a muted surface tint, a live HR chip (when present), Pause / Skip / STOP. Cues:
   final-3s countdown + distinct work-start vs rest-start tones (a light `AudioServicesPlaySystemSound`
   or `Haptics` per phase — keep it simple + revertible; expose a sound/haptic/silent toggle); a 3-2-1
   lead-in screen first. On finish (or STOP) → a **capture card** pre-filled with reps·sets·TUT (and
   avg/peak HR if present) → "Log set" commits the `SetLog(durationSec: TUT)` under the exercise.
   a11y ids: `intervalRunner.phase`, `.timer`, `.setrep`, `.stop`, `.pause`, `.skip`, `.logSet`.
3. **Wire-in**: in the named timed card (Phase 5), when `timedSpec.mode` is structured
   (`repeaters/tabata/emom`), "Add set" presents `StructuredTimedRunner` (`.fullScreenCover`) instead of
   the plain Timer; `.openCountUp/.maxHang/.countDown` keep the Phase-5 simple timer.

## Output
- `ios/App/Shared/IntervalSchedule.swift` + `IntervalScheduleTests.swift`.
- `StructuredTimedRunner.swift`; `FreeformPlayerView.swift` (present it for structured specs).
- `decisions.md` entry; `docs/knowledge-graph/data.js` node/edge.

## Acceptance criteria
- [ ] A repeaters/tabata/emom timed exercise runs the full-cover: lead-in → alternating WORK/REST phases
      with the right durations + set/rep counter + next-phase chip; STOP/finish logs the set.
- [ ] `IntervalSchedule` is pure + unit-tested (total time, phase boundaries, tabata/emom/repeaters).
- [ ] Per-phase color/cue telegraphs the phase; sound/haptic/silent toggle; Reduce Motion respected.
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green.

## Test plan
Build + `test-without-building -only-testing:SnappetTests` (incl. `IntervalScheduleTests`); a UITest that starts a tabata/repeater runner and reaches the capture card (device-only audio/haptics noted). Commit (changed files only) only if green; message `feat(quick-session): Phase 6 — structured interval runner (repeaters/tabata/emom)`. Report files/build/tests/SHA + device-only notes (audio/haptic cues, keep-awake).
