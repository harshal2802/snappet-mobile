# Prompt: Android — commit/error feedback and undo (snackbars, haptics, OCR & permission failures)

**File**: pdd/prompts/features/60-android-feedback-undo.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Jetpack Compose) — code lands in this repo.
**Chain**: 2026-06-09 product review → Android Wave 2 (third of three).
**Source**: GitHub issue [#89](https://github.com/harshal2802/Snappet/issues/89)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The app never responded to user actions: zero Snackbars, haptics, or toasts. Tip's "Add to history"
gave no feedback and double-tap silently wrote duplicates; Journal's per-row X deleted instantly
with no undo (the worst single-tap data loss in the app); Kilter's log pill was set and never
cleared, with no undo; receipt-OCR failure was a silent no-op; denying Bluetooth permission turned
Connect into a permanently dead control; and earned moments (focus complete, workout done, streak
milestones) were mute. Adopt the Material feedback pattern once at scaffold level and sweep.

## Context the implementer needs

- There was no app-level `Scaffold`/`SnackbarHost` shared across modules — each mini-app stands up
  its own `ModuleScaffold`. The shell (`ui/RootShell.kt`) is the one place every screen renders
  under, so the host belongs there, exposed via a CompositionLocal.
- Journal's list is Flow-driven, so optimistic undo is easy: hide the row immediately, defer the DAO
  delete until the snackbar times out, and let Undo just clear the pending id (nothing was deleted).
- Kilter's `insertLog` returns Unit, so undo is cleanest by deferring the *insert* to the snackbar's
  commit branch. The BLE permission callback ignored denial — `{ granted -> if (all) connect() }`.
- Receipt `recognize()` resumed `""` on every failure, indistinguishable from a blank photo.

## Approach

- `ui/SnackbarController.kt`: a `SnackbarHostState` wrapper with `show` and an `showUndo(message,
  onUndo, commit)` that runs `commit` only on timeout — built once so future delete flows reuse it.
  Host it at `RootShell` and provide `LocalSnackbarController`. `ui/Haptics.kt` wraps
  `LocalHapticFeedback`.
- Sweep: Journal optimistic undoable delete; Tip confirmation + debounce; Kilter pill auto-dismiss
  (~3s) + deferred-insert undo + BLE-denial rationale with a Settings deep link; Receipt
  `ReceiptScanResult` (Success/Empty/Failure) → inline error banner; haptics on set-complete /
  habit-toggle / log-climb; reduce-motion-gated workout-done entrance; pomodoro focus-complete and
  habit 7/30-day milestone snackbars.

## Output

- `ui/SnackbarController.kt`, `ui/Haptics.kt`; edits to `RootShell.kt`, `JournalRoot.kt`,
  `TipRoot.kt`, `KilterDetailScreen.kt`, `ReceiptScan.kt`, `NewReceiptSheet.kt`,
  `WorkoutPlayerScreen.kt`, `HabitRoot.kt`, `PomodoroRoot.kt`. Knowledge-graph node for the surface.

## Acceptance criteria

- [ ] Journal delete is undoable; the entry survives an Undo tap.
- [ ] Tip double-tap cannot create duplicate rows; commit gives visible feedback.
- [ ] Kilter log pill dismisses itself and offers Undo.
- [ ] Failed/blank OCR shows an inline error; success state unchanged.
- [ ] Permission denial shows rationale + Settings link; the button is never silently dead.
- [ ] Haptics fire on key commits; celebrations respect reduce-motion.

## Constraints

- On-device only; no new persistence. Reuse `Motion.kt`'s reduce-motion plumbing for celebrations.

## Test plan

1. `:app:testDebugUnitTest` + `:app:assembleDebug` (the feedback wiring is UI-layer; logic is thin).
2. Device-pending: the snackbar/haptic/permission/OCR paths need an emulator or device to observe.
