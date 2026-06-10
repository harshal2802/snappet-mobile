# Prompt: Make the Pomodoro timer survive leaving the screen and alert when a phase ends (Android)

**File**: pdd/prompts/features/40-android-pomodoro-reliability.md
**Created**: 2026-06-10
**Project type**: Native Android feature (Kotlin / Compose) — code lands in this repo.
**Chain**: Product-review roadmap [#101](https://github.com/harshal2802/snappet-mobile/issues/101) → Wave 1
**Source**: GitHub issue [#85](https://github.com/harshal2802/snappet-mobile/issues/85)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

A focus timer the user must stare at is the opposite of the product: the engine lived in
`remember {}` (killed by back-out / tab switch / rotation / process death) and nothing
signaled a phase ending. Make the session indestructible and audible — the Android
counterpart of iOS #70.

## Approach

- **App-owned engine**: `PomodoroTimerState` moves to `AppContainer.pomodoro` (the
  `AppModel.pomodoro` mirror); the screen is a window onto it. Session logging wires in
  the container.
- **One seam**: `onScheduleChanged(phase, endTimeMillis?)`, fired on start/auto-advance
  (absolute end) and pause/reset (null). The container hangs three things off it:
  `PomodoroStateStore` (SharedPreferences persistence incl. paused progress),
  `PomodoroAlerts.sync` (below), and clear.
- **Catch-up + restore**: `sync(now)` walks **every** elapsed boundary anchored at each
  phase's end (the #70-review fix, ported); `restore`/`restorePaused` rebuild from
  persisted state on container build — a focus that completed while dead **is logged to
  Room on the way back in**.
- **Outside-the-app surface** (`PomodoroAlerts`): a foreground service
  (`specialUse` FGS) posts the **ongoing chronometer countdown** (system-ticked, zero app
  CPU — the Live-Activity counterpart), and an **exact wake-from-Doze alarm**
  (`setExactAndAllowWhileIdle`, inexact fallback when the API-31+ special access is off)
  fires `PomodoroAlarmReceiver` → the phase-end alert, even if the process died.
  `POST_NOTIFICATIONS` is requested in-context on the Pomodoro screen (API 33+).
- Pure copy (`phaseEndContent`) mirrors iOS; channels: low-importance "running" +
  high-importance "alerts".

## Output

- Modified: `PomodoroTimerState.kt` (seam/catch-up/restore/isPaused), `PomodoroRoot.kt`,
  `AppContainer.kt`, `AndroidManifest.xml` (permissions + service + receiver).
- New: `PomodoroAlerts.kt`, `PomodoroService.kt`, `PomodoroAlarmReceiver.kt`,
  `PomodoroStateStore.kt`, `test/.../PomodoroTimerStateTest.kt` (8 JVM tests).
- Extended: `PomodoroUITest.timerSurvivesLeavingTheModule`.

## Acceptance criteria

- [ ] Start focus → back out / switch tab / rotate → return: timer still running with
      correct remaining time (instrumented test covers the back-out path; rotation and
      process death ride the same container + persisted schedule).
- [ ] Process killed mid-focus: restored from the persisted endTime; an away-completed
      focus is logged to Room (JVM-tested via `restore` with a past end).
- [ ] Phase end with the screen off posts a notification (exact alarm + receiver;
      device-pending verification like the iOS lock-screen alert).
- [ ] Ongoing notification while a phase runs; cleared on pause/reset.
- [ ] Pure timer math unit-tested without a device (catch-up walk, seam edges, restore).

## Constraints

- All local; nothing leaves the device. The FGS uses the documented `specialUse` subtype
  property (timers have no dedicated FGS type on API 34+).
- Honest verification: notification/alarm *delivery* under Doze needs a physical-device
  soak; emulator runs verify the suite + the in-app flows.

## Test plan

1. `:app:testDebugUnitTest` (new `PomodoroTimerStateTest`).
2. Emulator: full instrumented suite via `adb shell am instrument` incl. the new
   survives-navigation test.
3. Emulator by hand: start → home → notification shade shows the countdown; pause →
   cleared. Phase-end alert with screen off: device-pending.
