# Prompt: Kilter board session — recover, don't go stale

**File**: pdd/prompts/features/11-kilter-session-lifecycle.md
**Created**: 2026-06-07
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: bug-fix follow-up to the Kilter rich-session work (2026-06-05/06).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

A Kilter board "session" went **stale** after starting it and navigating around: the green session
bar vanished, the session couldn't be ended, climbs logged afterward were orphaned, and duplicate
open sessions could pile up. Make the session lifecycle robust and user-friendly — the persisted open
session is the single source of truth, and the UI always reflects (and can end) it.

## Context the implementer needs

`KilterSessionManager` tracked the active session **only in memory** (`current: KilterSession?`), and
was held as `@State` on `KilterRootView` — which is a `navigationDestination` in the App Library's
`NavigationStack`, so SwiftUI **destroys and recreates it** when you pop out of the module and back in
(or relaunch). The `KilterSession` row stayed open (`endedAt == nil`) in SwiftData but nothing
re-adopted it. Knock-on effects: logs written with `sessionId: nil` (orphaned/double-counted); a
second open session forked on board-connect / re-start; "End session" in the summary/History a no-op
(it operated on the dead in-memory `current`); a brief BLE disconnect *ended* the session; bulk
"Clear" could delete the live session.

## Approach

The persisted open session is the single source of truth.

- **Own `KilterSessionManager` in `AppModel`** (like `liveWorkout` / `kilterLiveActivity`) so it
  survives navigation; `KilterRootView` reads `app.kilterSessions` instead of `@State`.
- **Pure `KilterSessionRecovery`** (in `KilterSessionStats.swift`, device-free) decides recovery:
  adopt the newest open session, auto-close duplicates and sessions abandoned > 6 h (stamped at last
  activity, never "now"). `KilterSessionManager.recover(in:)` applies it on appear/relaunch.
- **Single-open invariant in `start()`** — adopt an existing open session instead of forking.
- **`end(sessionID:in:)`** — close by id from any surface (bar / summary / History), flushing HR only
  when this manager owns the live metrics.
- **Decouple the session from the BLE link**: own the board→session bridge at the root; connect
  opens/adopts the single session; **disconnect no longer ends it**.
- Surfaces: History shows live sessions (badge + running timer) with swipe-to-End; History/Settings
  "Clear" skip the active session.

## Output

- `Features/Kilter/KilterSessionStats.swift` — `KilterSessionRecovery` (pure planner).
- `Features/Kilter/KilterBoardController.swift` — `recover`/`adopt`/`start` invariant/`end(sessionID:)`.
- `Core/AppModel.swift` — `let kilterSessions`.
- `Features/Kilter/KilterRootView.swift` — read from AppModel, recover on appear, stable board bridge.
- `Features/Kilter/{KilterClimbDetailView,KilterSessionDetailView,KilterHistoryView,KilterSettingsView}.swift`.
- `Services/KilterLiveActivityController.swift` — `adoptRunningActivity()`.
- Tests: `SnappetTests/KilterSessionRecoveryTests` (8) + `SnappetUITests/KilterSessionLifecycleTests` (2).

## Acceptance criteria

- [x] A live session **survives** navigating out of the module and back (bar + timer + End persist).
- [x] No duplicate open sessions; "End" works from the bar, the summary, and History.
- [x] A board disconnect does not end the session; logs stay grouped under one session.
- [x] App changes type-check (Swift 6, 0 warnings); pure recovery logic unit-tested.
- [x] `decisions.md` + the knowledge graph updated.

## Constraints

- On-device only; no backend/network. The live-HR / Live-Activity / board paths remain device-only and
  unverifiable on the simulator — verified by construction + the pure planner's unit tests; the
  navigation-staleness fix is sim-verified end-to-end.
