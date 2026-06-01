# Prompt: Habit — edit, 7-day backfill strip & completion rate

**File**: pdd/prompts/features/13-ios-habit-edit-calendar.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: suite feature-completeness pass (P9 follow-up); one of six parallel mini-app increments.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md` (§"Adding a mini-app"), `pdd/context/decisions.md`.

## Goal

Round out the Habit tracker: let users **edit** a habit (name + symbol) after creation, **backfill or
correct** any of the last 7 days via a tappable week strip (today-only toggling is the current limit),
and see a **30-day completion rate**. Add a delete confirmation. The streak math and per-day completion
storage already exist; this exposes and extends them.

## Context the implementer needs

- Folder: `ios/App/Snappet/Features/Habit/` — `HabitRootView.swift` plus inline `HabitModule` and the
  `Habit` + `HabitCompletion` `@Model`s (already in `Core/SnappetCore.swift` `SnappetSchema.models`).
- `HabitCompletion` stores `habitID` + `day` (normalized to start-of-day); streaks read these. Backfill =
  insert/delete a `HabitCompletion` for an arbitrary past `day` (reuse the existing start-of-day
  normalization — do not duplicate it).
- Pushed into the App Library's `NavigationStack`; **no nested `NavigationStack`**. The editor is a sheet.
- Logs via `core.log(module: "habit", action: "create"/"done", …)`. Keep `done` logging on today's toggle;
  backfilling a past day should also log a sensible action (e.g. `action: "backfill"`).

## Approach

- **Edit** — new `HabitEditorView.swift` (sheet) reused for both create and edit (pass an optional
  `Habit`). Editing updates `name`/`symbol` in place; the symbol picker already exists — extract/reuse it.
- **Week strip** — a 7-day horizontal row per habit (or in a detail/expanded view): each day a tappable
  cell showing done/not-done; tapping inserts/removes that day's `HabitCompletion`. Today stays the
  primary toggle. Keep it a small `private struct` with a `done(on:)` / `toggle(day:)` closure.
- **Completion rate** — a label per habit: completions in the last 30 days ÷ days since creation (capped
  at 30), shown as a percent. Compute in a helper, not the view body.
- **Delete confirmation** — `.confirmationDialog` before destroying a habit + its completions.
- Add `.accessibilityIdentifier(...)`: add button (`habit.add`), each habit row (`habit.row.<name>` or
  index), today toggle (`habit.toggle`), edit button (`habit.edit`), week-strip day cells
  (`habit.day.<offset>`), editor name field (`habit.nameField`), save (`habit.save`).

## Output

- New `Features/Habit/HabitEditorView.swift`; edits to `HabitRootView.swift` (week strip, rate, edit
  entry, delete confirm, identifiers). New `SnappetUITests/HabitUITests.swift`. This prompt asset.

## Acceptance criteria

- [ ] A habit's name and symbol can be edited after creation and the change persists.
- [ ] Tapping a past day in the week strip toggles that day's completion and the streak/rate update.
- [ ] Each habit shows a 30-day completion-rate percent.
- [ ] Deleting a habit asks for confirmation.
- [ ] Add/row/toggle/edit/day-cell/editor controls carry stable `accessibilityIdentifier`s.
- [ ] `xcodegen generate` + `xcodebuild build-for-testing` (iPhone 17 Pro sim) → clean (Swift 6, 0 warn);
      `HabitUITests` compiles.
- [ ] No nested `NavigationStack`; no new `@Model` added; no platform imports in `HighlightEngine`.

## Constraints

- On-device only; no new dependencies. Reuse the existing start-of-day normalization & symbol set.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=F1A2B6B8-C609-47F8-8D55-44D94C5577B4' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build-for-testing` → succeeds.
2. `HabitUITests`: create a habit → edit its name → backfill a prior day → assert the streak label and
   completion-rate reflect it.
