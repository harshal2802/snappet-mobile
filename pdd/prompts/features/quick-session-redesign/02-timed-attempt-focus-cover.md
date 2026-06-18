# Prompt: Quick Session — live timed-attempt FOCUS cover (Phase 2)

**File**: pdd/prompts/features/quick-session-redesign/02-timed-attempt-focus-cover.md
**Created**: 2026-06-18
**Chain**: `quick-session-redesign/PLAN.md` → Phase 2 (builds on Phase 1 `04ce896`)
**Context**: `pdd/context/*`; design in `docs/ux-research/quick-session-redesign/wireframes.md` **surface #4 (Live timed attempt screen)**.

## Goal

Replace Phase 1's minimal `TimedAttemptSheet` (a `.medium` sheet) with a full-screen, dark, glass
**FOCUS cover** for timing one climbing attempt — the "detailed timed screen with a Stop button showing
climb details" the user asked for. The clock is the hero; HR is a chip; all session chrome recedes;
Stop is a giant bottom-center button; stopping prompts the outcome inline and auto-returns to the canvas.

## Context the implementer needs

- In `FreeformPlayerView.swift`: the footer **"Timed attempt"** button (`freeform.timedAttempt`) sets
  `@State var timingAttemptFor` which today drives `.sheet(item:)` → `TimedAttemptSheet(type:)` →
  `logAttempt(toExerciseID:status:durationSec:)`. The `logAttempt(...)` funnel (stamps the climb's grade
  + `completedAt` + haptic via `appendLog`) is the commit path — KEEP it.
- Reuse the **timing model directly**: `StopwatchViewModel(mode: .countUp)` (in `StopwatchView.swift`)
  is `@Observable`, wall-clock-backed (`reading.elapsed`, `start()`, `stop()`, `syncToWallClock()`).
  Build the FOCUS UI around the VIEW MODEL, not the packaged `StopwatchView` (whose small Start/Stop
  button doesn't fit a full-cover). The cover auto-starts the timer on appear (you're already mid-effort).
- Live HR: `app.liveWorkout.latestHR` + `HeartRateZone.forBpm(_, maxHR:)` with
  `app.userProfile.profile.resolvedMaxHR` (same as the command bar). The Glass-HUD palette
  (`#111928`@72%, white@14% hairline, SF Rounded tabular digits) — see `HRTile`/`StudioOverlays` for the
  exact treatment, but a self-contained dark style is fine. Boulder grade pill uses `SnappetColor.kilter`.
- iOS-26/XCUITest gotchas (see `FreeformPlayerView.swift` comments): one a11y id per interactive leaf;
  since you're NOT using the packaged `StopwatchView`, you CAN put an id on your own elapsed `Text`.

## Approach

1. New `TimedAttemptCover.swift` (WorkoutTracker) — a `View` presented via **`.fullScreenCover(item: $timingAttemptFor)`**
   (change the existing `.sheet(item:)` to `.fullScreenCover(item:)`). It takes the climb's
   name/type/grade(+scale) and the `(status, durationSec) -> Void` commit closure (same signature
   `logAttempt` consumes). States, per wireframe #4:
   - **Running**: dark base; a top row with **"⌄ Peek canvas"** (dismiss-without-logging,
     `timedAttempt.cancel`) + "try N" label; a glass card with `climbType` chip · name · grade pill;
     the **hero count-up timer** (≥48pt SF Rounded tabular, id `timedAttempt.timer`) with "counting up"
     caption; a glass **HR chip** (id `timedAttempt.hr`) shown only when `latestHR != nil` (omit, not
     "♥ --", when absent); a full-width **STOP** button (≥64pt, bottom-center, id `timedAttempt.stop`).
     Keep-awake via `.persistentSystemOverlays(.hidden)` is optional; do set `UIApplication.isIdleTimerDisabled`
     only if cheaply revertible on disappear (else skip — note as device-only).
   - **Stopped → outcome**: tapping Stop freezes the elapsed (grey it, don't remove), and slides up an
     inline **outcome prompt** — a 2×2 of type-aware buttons (`ClimbType.statusLabel`): order so the
     thumb-nearest row is the "close the climb" pair (Send/Flash) and the farther row is "keep open"
     (Fall→`.attempt`, Project). ids `timedAttempt.outcome.<flash|sent|project|attempt>`. Picking one
     calls the commit closure with `(status, capturedSeconds)` and dismisses. Also a **"Save as attempt"**
     (commits `.attempt` with the duration, id `timedAttempt.saveAsAttempt`) and dismissing via Peek/swipe
     = "save as attempt" (never silently discard a captured effort) — match the wireframe's "swipe-down = save".
   - Edge cases: no HR (chip omitted); first-ever attempt ("try 1", no "of N"); long attempt (timer rolls
     to H:MM:SS past 59:59 — `SetMeasure.formatDuration` already does this); Reduce Motion (no ring pulse;
     the glass card + digits suffice).
   - **Do NOT** fire milestone celebration here — Phase 3 owns the at-logging-moment `CelebrationBurst`
     uniformly for timed AND untimed attempts.

2. Remove the now-unused minimal `TimedAttemptSheet` (or keep if still referenced — prefer removing dead
   code). Keep `TimedAttemptTarget`/`timingAttemptFor` plumbing.

3. Update **`ClimbAttemptTimerTests.swift`** to drive the FOCUS cover: tap a climb's "Timed attempt"
   (`freeform.timedAttempt`) → assert `timedAttempt.timer` exists → tap `timedAttempt.stop` → tap
   `timedAttempt.outcome.sent` → assert the climb card now shows a timed attempt row (outcome + duration).

## Output
- `TimedAttemptCover.swift` (new); `FreeformPlayerView.swift` (`.fullScreenCover` swap, remove dead sheet).
- `ClimbAttemptTimerTests.swift` updated.
- `decisions.md` entry (FOCUS cover; viewmodel-direct timing; outcome-on-stop; save-on-dismiss).
- `docs/knowledge-graph/data.js`: add a `TimedAttemptCover` node + edge from the freeform player.

## Acceptance criteria
- [ ] "Timed attempt" opens a full-screen dark FOCUS cover with climb details + a live count-up timer + a
      giant Stop; HR chip shows only with a live HR source.
- [ ] Stop captures the duration and prompts a type-aware outcome inline; picking it logs the attempt
      (duration + status, grade stamped from the climb) under the climb and returns to the canvas.
- [ ] Dismissing after a Stop saves the attempt (never silently drops a captured effort); dismissing
      before starting/stop logs nothing.
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, **0 new warnings**).
- [ ] Full `SnappetTests` green; `ClimbAttemptTimerTests` passes the new FOCUS flow (retry once on the
      `simctl shutdown all` sim wedge).

## Test plan
Same as Phase 1: `xcodegen generate`; `simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; then `-only-testing:SnappetUITests/ClimbAttemptTimerTests`. Commit on the branch (add only changed files) ONLY if green; message `feat(quick-session): Phase 2 — live timed-attempt FOCUS cover`. Report files/build/test results/commit SHA + any device-only notes.
