# Prompt: Open Snappet to the OS — Today widget + interactive habit check-off (Phase 2 of 4)

**File**: pdd/prompts/features/55-ios-os-integration-widgets.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → OS integration (iOS)
**Source**: GitHub issue [#81](https://github.com/harshal2802/snappet-mobile/issues/81)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Phase 1 shipped the App Group + the read-only Today snapshot. This phase puts a real **home-screen
widget** on the springboard: a **Today** widget (day streak + habits remaining; medium adds an
interactive habit checklist + a Start-focus button). The headline daily user can now see their streak
and pending habits, **check a habit off from the widget without opening the app**, and start a focus
timer — directly satisfying three of #81's acceptance criteria.

## Context the implementer needs

- **The read path is in place** (Phase 1, prompt 54): `Shared/SnappetWidgetSnapshot` (the contract),
  `Shared/WidgetSnapshotStore` (App-Group `group.com.snappet.app` codec + file edge), the pure
  `WidgetSnapshotBuilder`, and `WidgetSnapshotService.refresh` (publishes on `scenePhase` in
  `RootShell`, no-ops under `-uiTest*`). The widget reads the snapshot — never SwiftData.
- **The interactive check-off is the hard part.** An interactive widget `AppIntent` runs OUTSIDE the
  app process, so it can't write SwiftData. Per the locked decision (decisions.md 2026-06-15) it
  writes an App-Group **outbox**; the app drains + reconciles it into SwiftData on next foreground.
  The iOS Simulator DOES provision the App-Group container, so this is sim-verifiable end-to-end.
- **"Start focus" reuses the deep-link plumbing** (#75): `SnappetDeepLink` (URL→route) +
  `RootShell.onOpenURL` + `SuiteRouter` one-shots (`pendingWorkoutResume`/`pendingKilterClimb`). Add a
  `snappet://pomodoro/start` route + a `pendingPomodoroStart` one-shot consumed by `PomodoroRootView`,
  which already owns the app-level `AppModel.pomodoro` engine (`timer.start()`).
- `SnappetWidgetsBundle` currently vends 3 Live Activities; add the `TodayWidget` beside them.

## Approach

1. **Outbox** (`Shared/WidgetOutbox.swift`): a `HabitToggle` value (id, habitID, day, **desired**
   absolute state, requestedAt) + a **directory-of-one-file-per-toggle** store (append = write a new
   uniquely-named file → no cross-process read-modify-write race; `pending()` reads, `remove(ids:)`
   deletes). Codec is pure/Codable-tested; the App-Group directory I/O is the thin edge.
2. **Interactive intent** (`Shared/ToggleHabitIntent.swift`, `AppIntent`, `openAppWhenRun = false`):
   read the snapshot for the habit's current `doneToday`, flip it, append a `HabitToggle(desired:)`,
   optimistically rewrite the snapshot (so the widget reflects the tap immediately), and
   `reloadAllTimelines()`. Touches only App-Group files — works in the widget process.
3. **Reconciliation** (`Snappet/Widgets/HabitCheckoffReconciler.swift`, PURE
   `plan(toggles:existing:) -> (inserts,deletes)`): last desired state per (habitID, day) wins
   (order-tolerant), and a desired state already matching the store is a no-op (idempotent).
   `WidgetSnapshotService.refresh` drains via `WidgetOutbox.pending()`, applies the plan to the
   `ModelContext`, saves, then `WidgetOutbox.remove(ids:)` ONLY on a successful save (no loss on
   failure; idempotent retry next foreground). Still gated off under `-uiTest*`.
4. **Today widget** (`SnappetWidgets/TodayWidget.swift`): `StaticConfiguration` + `TimelineProvider`
   reading `WidgetSnapshotStore` (`.after(nextMidnight)` policy so it rolls at day change; the app
   also nudges reloads). Small = streak + habits-remaining; medium = + a habit checklist (each row a
   `Button(intent: ToggleHabitIntent(habitID:))`) + a `Start focus` `Link(snappet://pomodoro/start)`.
   Added to `SnappetWidgetsBundle`.
5. **Start-focus deep link**: `SnappetDeepLink.startFocus` (`snappet://pomodoro/start`),
   `SuiteRouter.pendingPomodoroStart`, `RootShell.onOpenURL` routing, consumed by `PomodoroRootView`
   (onAppear + onChange) → `timer.start()`.

## Output

- `ios/App/Shared/WidgetOutbox.swift`, `ios/App/Shared/ToggleHabitIntent.swift` — new.
- `ios/App/Snappet/Widgets/HabitCheckoffReconciler.swift` — new (pure plan).
- `ios/App/Snappet/Widgets/WidgetSnapshotService.swift` — drain + apply + remove on save.
- `ios/App/SnappetWidgets/TodayWidget.swift` — new; added to `SnappetWidgetsBundle.swift`.
- `ios/App/Snappet/Features/Kilter/KilterDeepLink.swift` — `SnappetDeepLink.startFocus` route.
- `ios/App/Snappet/Core/SuiteRouter.swift` — `pendingPomodoroStart`.
- `ios/App/Snappet/Features/Shell/RootShell.swift` — onOpenURL `.startFocus` case.
- `ios/App/Snappet/Features/Pomodoro/PomodoroRootView.swift` — consume the one-shot.
- Tests: `WidgetOutboxTests` (HabitToggle codec; reconciler plan truth table), extended deep-link
  route test for `snappet://pomodoro/start`.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] A Today widget (small + medium) renders the snapshot's streak + habits remaining.
- [ ] Tapping a habit's check-off in the widget appends to the outbox + flips the snapshot
      immediately, and the app reconciles it into SwiftData on next foreground (idempotent,
      order-tolerant — proven by `HabitCheckoffReconciler` tests).
- [ ] `xcrun simctl openurl booted "snappet://pomodoro/start"` opens Pomodoro and starts the timer.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings); full sim suite green.
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated (outbox directory design; reconcile-on-save ordering).

## Constraints

- On-device only; no backend/network/accounts. The outbox + snapshot are local App-Group files.
- The interactive intent NEVER touches SwiftData (it can't, off-process) — outbox only. The app is the
  sole writer of the canonical store, on foreground.
- Verify honestly: the **widget actually rendering on the springboard + the AppIntent firing from a
  real tap** are best confirmed on a device; the sim verifies the snapshot read, the outbox
  round-trip, the reconciliation, and the deep link. Record device-pending accordingly.

## Test plan

1. `cd ios/App && xcodegen generate` clean; app + widget build (`build-for-testing`).
2. Unit (sim): `WidgetOutboxTests` (HabitToggle round-trip; reconciler insert/delete/no-op/
   last-write-wins/order), extended `SnappetDeepLink` route test.
3. Full sim suite green (this phase changes real UI → run `SnappetUITests` too).
4. Deep link (sim): `xcrun simctl openurl booted "snappet://pomodoro/start"` (cold + warm).
5. Device-pending: the widget on the springboard, a real check-off tap, Start-focus from the widget.
