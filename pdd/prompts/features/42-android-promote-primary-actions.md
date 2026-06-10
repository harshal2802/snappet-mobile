# Prompt: Android — promote buried primary actions (Kilter create, Expense add/receipt/settle, Download-first first-run)

**File**: pdd/prompts/features/42-android-promote-primary-actions.md
**Created**: 2026-06-10
**Project type**: Native Android feature (Kotlin / Jetpack Compose) — code lands in this repo.
**Chain**: 2026-06-09 product review → Android tracker [#101](https://github.com/harshal2802/Snappet/issues/101), Wave 1 (last item).
**Source**: GitHub issue [#94](https://github.com/harshal2802/Snappet/issues/94)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Three of the platform's most differentiated features — climb authoring, camera receipt-OCR, and
settle-up — are invisible behind three-dot overflow menus, while sibling modules (Journal, Habits,
Budget) all show a visible add action; the empty states literally have to teach the burial
("Tap More ▸ Create climb", "Use the menu to add the group's first expense"). The Kilter first-run
gate compounds it: the power-user path (Import a file) is the primary filled button while the path
that works for most users (Download from Kilter) is secondary, and the helper copy references
"the boardlib tool — see tools/kilter" — a git-repo artifact a phone user cannot see or act on.
Make the primary actions visible and lead first-run with Download.

## Context the implementer needs

- `ui/ModuleScaffold.kt` — the standard module chrome wraps Material3 `Scaffold` but exposes no
  `floatingActionButton` slot; there are **zero FABs app-wide**, which is why everything landed in
  kebab menus.
- `feature/kilter/KilterRoot.kt` — `KilterCatalogScreen` puts **Create climb** / Start session /
  Surprise me / Settings in the `kilter.more` kebab; the Mine-filter empty state says
  "Tap More ▸ Create climb…". History and Filters are already visible top-bar icons.
- `feature/expense/ExpenseRoot.kt` — `GroupDetail` puts **New expense** / **New receipt** (the sole
  entrance to receipt OCR) / **Settle up** in the `expense.groupActions` kebab; the empty state says
  "Use the menu to add the group's first expense." The group *list* already has a visible top-bar +.
- `feature/kilter/KilterCatalogSyncScreen.kt` — first-run gate: "Import catalog file…" is the filled
  primary `Button`, "Download from Kilter…" the `OutlinedButton` below it; the caption mentions
  boardlib / tools/kilter.
- `pdd/context/decisions.md` records "file-import primary" as a deliberate legal-posture choice
  (entries of 2026-06-05/06). The ToU notice and the user-controlled host are **not** changing —
  only the button emphasis on the Android first-run screen. Record the reversal.
- Instrumented tests drive the buried paths today: `KilterCreateUITest` opens create via
  `kilter.more` → `kilter.create`; `ExpenseUITest` opens new-expense and settle via
  `expense.groupActions`. `KilterUITest.emptyStateShowsCatalogSyncScreen` asserts the import button.

## Approach

1. `ModuleScaffold` gains an optional `floatingActionButton` slot passed through to `Scaffold`.
2. **Kilter browse**: an `ExtendedFloatingActionButton` "Create climb" (tag `kilter.create`, moved
   off the menu item); the kebab keeps Start/End session, Surprise me, Settings. Mine empty-state
   copy points at the visible control. List gets bottom content padding so the FAB never covers the
   last row.
3. **Expense group detail**: ExtendedFAB "New expense" (tag `expense.newExpense`); a top-bar
   receipt icon button for "New receipt" (tag `expense.newReceipt`, the OCR entrance); an inline
   "Settle up" button beside the Settle Up section header (tag `expense.settle`). The kebab is then
   empty → remove it. Empty-state copy references the visible controls.
4. **First-run**: swap emphasis — Download is the filled primary button and comes first, Import the
   outlined secondary; delete the boardlib/tools-kilter repo-artifact sentence (the caption explains
   both paths in user terms).
5. Update the instrumented tests to drive the visible controls; extend the first-run test to assert
   the Download button. decisions.md + knowledge-graph in the same change.

## Output

- `android/app/src/main/java/com/snappet/mobile/ui/ModuleScaffold.kt` — FAB slot.
- `android/app/src/main/java/com/snappet/mobile/feature/kilter/KilterRoot.kt` — Create-climb FAB,
  kebab minus Create, empty-state copy.
- `android/app/src/main/java/com/snappet/mobile/feature/expense/ExpenseRoot.kt` — New-expense FAB,
  top-bar receipt button, inline Settle up, kebab removed, empty-state copy.
- `android/app/src/main/java/com/snappet/mobile/feature/kilter/KilterCatalogSyncScreen.kt` —
  Download-first emphasis, repo-artifact copy deleted.
- `android/app/src/androidTest/.../KilterCreateUITest.kt`, `ExpenseUITest.kt`, `KilterUITest.kt` —
  updated/extended.
- `pdd/context/decisions.md` + `docs/knowledge-graph/data.js` — same change.

## Acceptance criteria

- [ ] Create climb and New expense/receipt reachable from a visible on-screen control without
      opening a menu.
- [ ] Settle up has an inline affordance in group detail.
- [ ] First-run screen leads with Download; no repo-artifact copy remains.
- [ ] Empty states reference the visible controls.
- [ ] decisions.md updated (reversal of "file-import primary" emphasis, Android first-run only).
- [ ] Unit suite + instrumented suite green (39-test baseline preserved or grown).

## Constraints

- On-device only; no backend/network/accounts beyond the existing user-configured catalog host.
- The Aurora ToU notice and the user-controlled host on the sync screen stay untouched — this
  changes button order/emphasis and copy only.
- Keep secondary actions in the kebab (Kilter); don't grow scope into session-start promotion or
  iOS parity (separate tracker items).

## Test plan

1. `./gradlew :app:testDebugUnitTest` (env per android-build-env: JDK 17, ANDROID_HOME).
2. Build debug + androidTest APKs, `adb install -r`, run
   `adb shell am instrument -w com.snappet.mobile.test/androidx.test.runner.AndroidJUnitRunner`
   on emulator-5554 — Kilter create flow via FAB, expense add/settle via visible controls,
   first-run screen shows Download primary.
3. By eye on the emulator: FAB placement over the lists, dark mode, empty states.
