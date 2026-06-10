# Prompt: Android — system back, rotation/process-death state, tab retention, workout resume

**File**: pdd/prompts/features/43-android-nav-robustness.md
**Created**: 2026-06-10
**Project type**: Native Android feature (Kotlin / Jetpack Compose) — code lands in this repo.
**Chain**: 2026-06-09 product review → Android tracker [#101](https://github.com/harshal2802/Snappet/issues/101), Wave 2 (first item; explicitly gates #99 Today-home).
**Source**: GitHub issue [#86](https://github.com/harshal2802/Snappet/issues/86)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Gesture back is the primary navigation on Android and the app doesn't participate in it: there is
not a single `BackHandler` in 116 source files, every module's internal navigation is plain
`remember { mutableStateOf }`, and the only NavHost is `library → module/{id}`. A back swipe from
any depth pops the whole module to the app grid, discards drafts, and bypasses the workout
End/Discard dialog. Rotation and process death reset all in-module state. Tab-switching to Today
disposes the entire Apps subtree. Worst case: an abandoned active workout (`finishedAt == null`)
keeps its logged sets in Room but is filtered out of History and has no resume path — permanently
invisible. Make the app behave like a real Android app: back pops one level, rotation loses
nothing, tabs retain position, and an interrupted workout is recoverable.

## Context the implementer needs

One root cause, five surfaces (all file:line references verified 2026-06-10):

- **Shell**: `ui/RootShell.kt:55-58` renders the tabs with a bare `when (tab)` — switching tabs
  disposes the other tab's composition *and* its saveable-state registry entries are not retained.
  `ui/library/AppLibraryScreen.kt:64` holds the only NavHost (`library`, `module/{id}`, `backup`);
  `rememberNavController()` is savedState-backed, so once the subtree is retained, the route stack
  survives tab switches and rotation for free. NavHost already handles back at module root
  (pops to the grid) — module-internal back is the missing layer.
- **Workout** (`feature/workout/`): `WorkoutRoot.kt:82-88` — `screen`/`section` enums plus
  `selectedExerciseId`/`selectedRoutineRow`/`selectedSessionRow`/`playingSessionRow`
  (String?/Long?), all plain `remember`. The live player persists incrementally — every completed
  set calls `persist` → `dao.updateSession` (`WorkoutPlayerScreen.kt:89,135,160`), and the session
  row is inserted at start (`WorkoutRoot.kt:117-119`) — so the data for resume already exists; only
  the affordance is missing. `history = sessions.filter { !it.isActive }` (`WorkoutRoot.kt:91`,
  `isActive` = `finishedAt == null`, `WorkoutModels.kt:282`) hides active sessions. The
  "End this workout?" dialog (`WorkoutPlayerScreen.kt:216`) is wired to the top-bar arrow and End
  button only; system back bypasses it.
- **Journal** (`feature/journal/`): `JournalRoot.kt:62` holds a sealed
  `JournalScreen.Root/Editor(entry?)` (non-Saveable — carries the full `JournalEntry`);
  `JournalEditorScreen.kt:48-51` drafts (`title`/`body`/`tags`/`tagInput`) are plain `remember`.
- **Kilter** (`feature/kilter/`): `KilterRoot.kt:121-122` `screen` enum + `selectedUuid`;
  `CreateClimbScreen.kt:78-114` — the climb draft. `name` and the numeric params are already
  `rememberSaveable`; `mode`, `assignments: Map<Int, KilterAuthorRole>` (the actual draft), and the
  generator result are not. `manualHolds`/`genHolds` are derived from assignments/frames via
  `LaunchedEffect`, so saving the source state is sufficient. `KilterSessionManager`
  (`KilterRoot.kt:87`) groups ascents by `currentSessionId` — it must keep working across
  rotation.
- **Expense** (`feature/expense/`): `ExpenseRoot.kt:79` `selectedGroupId` plain `remember`; sheet
  staging uses full objects (`editing`/`editingReceipt`/`viewingReceipt: ExpenseRecord?`,
  `ExpenseRoot.kt:306-308`). `NewReceiptSheet.kt:60-63` strings are already `rememberSaveable` but
  `items` (`:76`, `mutableStateListOf<ItemEdit>`) — the OCR payoff — is not.
  `NewExpenseSheet.kt:45-48`, `NewGroupSheet.kt:40-42`, `RecordSettlementSheet.kt:40-42` drafts are
  plain `remember`.
- **Small modules**: `BudgetRoot.kt:84-92` (`screen`, `selectedCategoryId`, `month: MonthScope`,
  sheet staging), `TipRoot.kt:74-80` (screen + the whole calculator form), `PomodoroRoot.kt:82-83`
  (screen + settings sheet; the timer itself is already service-hoisted per #85),
  `HabitRoot.kt:80-83` (sheet staging), editor sheets `HabitEditorSheet.kt:42-43`,
  `BudgetCategoryEditor.kt:32-33`, `AddTransactionSheet.kt:37-41`.
- **Manifest/deps**: no `configChanges` opt-outs (rotation recreates the Activity — correct,
  `rememberSaveable` is the fix), `androidx.activity:activity-compose` already on the classpath
  (`BackHandler` available). Compose's `autoSaver` accepts everything Bundle-friendly — enums
  (Serializable), String, Long?, Boolean — so most promotions are mechanical.
- **Tests**: 39 instrumented tests, all tag-driven through `SuiteTest` helpers
  (`launch()`/`openModule(id)`/`tapBack()`); zero `recreate()`/back-gesture/`StateRestorationTester`
  coverage today. `TestHooks.freshInMemoryStore` gives per-test store isolation. Unit suite is 88
  plain-JUnit tests, no Robolectric.

## Approach

1. **Tab retention** (`RootShell.kt`): `rememberSaveableStateHolder()` +
   `SaveableStateProvider("today"/"apps")` around the `when (tab)` content so each tab's
   `rememberSaveable` state (including the NavHost back stack) survives switching away and back.
2. **System back = pop one level**: in each multi-screen module root, a
   `BackHandler(enabled = <not at module root>)` that performs exactly what the top-bar arrow does
   at that depth. When at module root the handler is disabled and back falls through to the NavHost
   (→ app grid). The workout player gets its own `BackHandler` routing through the existing
   End/Discard dialog (innermost-wins ordering keeps it above WorkoutRoot's). Bottom
   sheets/dialogs already dismiss on back via their own dispatchers — don't double-handle.
3. **Saveable promotion** (mechanical): screen enums, section enums, selection ids, search text,
   filter toggles, sheet-visibility booleans, and text drafts → `rememberSaveable`. Object staging
   → id staging + lookup from the existing Room flows (entry vanished ⇒ state self-heals to null,
   matching the existing `if (x == null) screen = ROOT` guards). Journal's sealed screen becomes
   saveable primitives (`editorOpen: Boolean` + `editingEntryId: Long?`, null = new entry); editor
   drafts keyed `rememberSaveable(entryId)`. Three custom Savers where autoSaver can't go:
   - Kilter `assignments: Map<Int, KilterAuthorRole>` — encode as `List<String>` `"id:roleName"`
     (pure codec, unit-tested),
   - expense receipt `items: List<ItemEdit>` — listSaver over (name, priceText, assignees),
   - budget `MonthScope` — its (year, month) ints.
   Generator result on the Kilter create screen: save `frames` + predicted grade (strings/ints);
   holds re-derive. Skip pendingSave/duplicate dialog staging and confirm-dialog staging
   (momentary, loss-safe) and `BackupScreen.pendingImportText` (MB-scale string; saving it into the
   transaction-limited Bundle is the wrong trade — record as accepted residual).
4. **Workout resume**: WorkoutRoot computes `active = sessions.filter { it.isActive }`; when on
   ROOT with no player open and `active` is non-empty, show a banner above the section selector —
   "Active workout — ⟨name⟩" with **Resume** (sets `playingSessionRow`/`screen = PLAYER`) and
   **Discard** (confirm dialog → `dao.deleteSession`). Resume policy: a `finishedAt == null` row is
   *only* ever finalized by the user (resume → finish, or discard) — never auto-deleted, never
   auto-finished. Player working state: completed sets already live in Room; promote
   position/inputs (`exerciseIndex`, `setIndex`, `phase`, `repsText`, `weightText`, `restRemaining`,
   `restTotal`, dialog booleans) so rotation mid-set restores in place.
5. **Tests**: new `NavRobustnessUITest` (instrumented) — back-pops-one-level (workout section →
   exercise detail → back ⇒ still in module), back-mid-workout-shows-End-dialog,
   `recreate()`-preserves-journal-draft, recreate-preserves-create-climb-assignments,
   tab-switch-preserves-module-position, resume-banner-appears-and-resumes (seed an active session
   via the container's DAO). Unit tests for the assignments codec round-trip. Keep the existing 39
   green — `SuiteSmokeTest.tapBack()` paths must still exit modules from their roots.

## Output

- `android/app/src/main/java/com/snappet/mobile/ui/RootShell.kt` — SaveableStateHolder.
- `feature/workout/WorkoutRoot.kt` + `WorkoutPlayerScreen.kt` — saveables, BackHandlers, resume
  banner + discard confirm.
- `feature/journal/JournalRoot.kt` + `JournalEditorScreen.kt` — saveable screen/id + keyed drafts,
  BackHandler.
- `feature/kilter/KilterRoot.kt` + `CreateClimbScreen.kt` (+ history/detail touch-ups) — saveable
  screen/uuid/filters, assignments codec + Saver, BackHandler.
- `feature/expense/ExpenseRoot.kt` + `NewExpenseSheet.kt` + `NewGroupSheet.kt` +
  `RecordSettlementSheet.kt` + `NewReceiptSheet.kt` — saveable group/record ids + drafts +
  ItemEdit Saver, BackHandler.
- `feature/budget/`, `feature/tip/`, `feature/pomodoro/`, `feature/habit/` — saveable screens,
  MonthScope Saver, draft promotions, BackHandlers.
- `android/app/src/androidTest/java/com/snappet/mobile/NavRobustnessUITest.kt` (new) + any touched
  existing tests; unit test for the kilter assignments codec.
- `pdd/context/decisions.md` + `docs/knowledge-graph/data.js` — same change.

## Acceptance criteria

- [ ] Back gesture from Kilter detail/create, Journal editor, and any module sub-screen pops one
      level, not the whole module.
- [ ] Back mid-workout triggers the End/Discard dialog; the session is never silently abandoned.
- [ ] Rotating mid-draft (journal, create-climb) and mid-workout preserves all state.
- [ ] Today ↔ Apps tab switches preserve module position.
- [ ] An interrupted active session shows a Resume affordance and can be finished or discarded.
- [ ] Unit suite + instrumented suite green (39-test instrumented baseline grown by the new class).
- [ ] `decisions.md` updated (resume policy, saveable-promotion pattern, accepted residuals).

## Constraints

- On-device only; no backend/network/accounts.
- Don't migrate modules into the NavHost graph — module-local `BackHandler` + saveable state is the
  deliberate minimal shape (the #99 nav hoist builds on it later; record in decisions.md).
- No Room schema change (stays v4) — resume reads the rows that already exist.
- `KilterBoardController`/`KilterSessionManager` object lifetimes are untouched (BLE reconnect on
  rotation is a known device-phase residual); only their *navigation context* must restore.
- Don't double-handle back for ModalBottomSheet/AlertDialog — Compose already dismisses those.

## Test plan

1. `./gradlew :app:testDebugUnitTest` (env per android-build-env: JDK 17, ANDROID_HOME; rerun
   `--rerun-tasks` if the fork flake hits).
2. Build debug + androidTest APKs, `adb install -r`, run
   `adb shell am instrument -w com.snappet.mobile.test/androidx.test.runner.AndroidJUnitRunner`
   on emulator-5554 (Gradle connected task wedges; use am instrument directly).
3. By eye on the emulator: back-swipe depth-walk through every module; rotate mid-journal-draft,
   mid-create-climb, mid-workout-set; kill the app mid-workout (`adb shell am kill`), relaunch,
   resume from the banner.
