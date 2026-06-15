# Prompt: Open Snappet to the OS — Siri / Shortcuts App Shortcuts (Phase 3 of 4)

**File**: pdd/prompts/features/56-ios-os-integration-appshortcuts.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → OS integration (iOS)
**Source**: GitHub issue [#81](https://github.com/harshal2802/snappet-mobile/issues/81)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Phases 1–2 gave the suite a widget. This phase gives it a **voice + Shortcuts** presence: App
Shortcuts so the user can say "start a focus timer" / "check off Read in Snappet" and see the suite's
actions in the Shortcuts app — satisfying #81's "start a focus timer works via Siri/Shortcuts; intents
appear in the Shortcuts app" AC. The intents reuse Phase 2's mechanisms (the off-process outbox for
check-off; the `SuiteRouter` deep-link dispatch for open-app actions).

## Context the implementer needs

- **Two cross-process channels already exist** (Phase 2): the **outbox** (`WidgetOutbox`, off-process
  habit writes the app reconciles) and the **`SuiteRouter` one-shots + `RootShell` dispatch** (open the
  app + do X — `pendingPomodoroStart`, `pendingKilterClimb`). Siri intents reuse both, not new paths.
- An interactive AppIntent runs OUTSIDE the app process. So: `CheckOffHabit` writes the outbox
  (no app open); the "open-app-and-act" intents (`StartPomodoro`, `OpenModule`, `QuickJournal`,
  `StartRoutine`) set `openAppWhenRun = true`, write a typed action to a new App-Group **inbox**, and
  the app drains it on foreground and dispatches via the existing `SuiteRouter`.
- `AppShortcutsProvider` is discovered in the **main app** bundle, so it lives in the app target; the
  intents live in `Shared/` (compiled into app + widget, like `ToggleHabitIntent`) so the provider can
  reference them.
- Module ids: `pomodoro`, `journal`, `habit`, `kilter`, `tip`, `expense`, `budget`, and the gym tracker
  `workout-log` (`WorkoutTrackerModule.id`; display title "Gym Tracker", #74) + reels `workout`.
- Habits for a Siri picker come from the App-Group **snapshot** (`SnappetWidgetSnapshot.habits` is the
  full habit list with id + name) — a `HabitEntity`/`EntityQuery` reads it off-process, no SwiftData.
- Swift-6: an `AppIntent`/`AppEntity`'s `static` metadata must be `static let` (Phase 2 gotcha).

## Approach

1. **`Shared/AppActionInbox.swift`** — `PendingAppAction` (Codable enum: `.startPomodoro`,
   `.openModule(String)`, `.quickJournal(String?)`, `.startRoutine`) + a directory-of-one-file-per-
   action App-Group inbox (the race-free `WidgetOutbox` pattern): `enqueue` / `drain`.
2. **`Shared/HabitEntity.swift`** — `AppEntity` (id + name) + a `DefaultHabitQuery` whose
   `suggestedEntities()`/`entities(for:)` read `WidgetSnapshotStore.read()?.habits`.
3. **`Shared/SnappetAppIntents.swift`** — the 5 intents:
   - `StartPomodoroIntent` (openAppWhenRun) → `enqueue(.startPomodoro)`.
   - `CheckOffHabitIntent` (NOT openAppWhenRun; `@Parameter habit: HabitEntity`) → append a
     `HabitToggle(desired: true)` to `WidgetOutbox` + optimistic snapshot + reload (the Phase-2 path),
     with a confirmation dialog.
   - `OpenModuleIntent` (openAppWhenRun; `@Parameter module: ModuleAppEnum`) → `enqueue(.openModule)`.
   - `QuickJournalIntent` (openAppWhenRun; optional `@Parameter text`) → `enqueue(.quickJournal(text))`.
   - `StartRoutineIntent` (openAppWhenRun) → `enqueue(.startRoutine)` (opens the gym tracker; a specific
     routine auto-launch is a follow-up — recorded).
4. **`Snappet/Widgets/SnappetShortcuts.swift`** — `AppShortcutsProvider` with an `AppShortcut` +
   natural-language phrases for each (the "${applicationName}" form).
5. **Dispatch**: `SuiteRouter.pendingJournalText` (one-shot, the `pendingPomodoroStart` pattern);
   `RootShell` drains `AppActionInbox` on first build + scenePhase `.active` and dispatches
   (`.startPomodoro` → pendingPomodoroStart + open pomodoro; `.openModule` → `open(module:)`;
   `.quickJournal` → open journal + `pendingJournalText`; `.startRoutine` → open `workout-log`).
   `JournalRootView` consumes `pendingJournalText` → opens a prefilled new editor.

## Output

- `ios/App/Shared/AppActionInbox.swift`, `ios/App/Shared/HabitEntity.swift`,
  `ios/App/Shared/SnappetAppIntents.swift` — new.
- `ios/App/Snappet/Widgets/SnappetShortcuts.swift` — new (`AppShortcutsProvider`).
- `ios/App/Snappet/Core/SuiteRouter.swift` — `pendingJournalText`.
- `ios/App/Snappet/Features/Shell/RootShell.swift` — drain + dispatch the inbox.
- `ios/App/Snappet/Features/Journal/JournalRootView.swift` — consume `pendingJournalText`.
- Tests: `AppActionInboxTests` (PendingAppAction codec round-trip per case), `HabitEntity` mapping
  from a snapshot.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] The 5 App Shortcuts appear in the Shortcuts app (an `AppShortcutsProvider` ships in the app).
- [ ] "Start a focus timer" via Siri/Shortcuts opens Snappet and starts the Pomodoro timer.
- [ ] "Check off <habit>" persists without opening the app (reuses the Phase-2 outbox; reconciled on
      next foreground), with the habit resolvable by name (`HabitEntity`).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6); full sim suite green.
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated (the inbox channel; StartRoutine's deferred named-routine launch).

## Constraints

- On-device only; no backend/network/accounts. The inbox + outbox are local App-Group files.
- Reuse the Phase-2 channels — do NOT add a third cross-process mechanism beyond the typed inbox.
- Verify honestly: Siri phrase invocation + the Shortcuts-app listing are best confirmed on a device;
  the sim verifies the intents compile/register, the inbox/outbox round-trips, and the dispatch.

## Test plan

1. `cd ios/App && xcodegen generate` clean; app + widget build (`build-for-testing`).
2. Unit (sim): `AppActionInboxTests` (codec per case), `HabitEntity` mapping.
3. Full sim suite green (this phase touches app UI dispatch → run `SnappetUITests` too).
4. Device-pending: actual Siri phrases, the Shortcuts-app gallery listing, donation.
