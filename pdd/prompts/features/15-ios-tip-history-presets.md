# Prompt: Tip — calculation history, editable presets & round-up

**File**: pdd/prompts/features/15-ios-tip-history-presets.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: suite feature-completeness pass (P9 follow-up); one of six parallel mini-app increments.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md` (§"Adding a mini-app"), `pdd/context/decisions.md`.

## Goal

Give the Tip calculator memory and flexibility: **save each calculation to a history**, let users **edit
the preset tip percentages** (currently hard-coded 15/18/20/25), and add a **round-up total** option.
Tip is the only mini-app with no persistence today (state lives only in `@AppStorage`).

## Context the implementer needs

- Folder: `ios/App/Snappet/Features/Tip/` — `TipRootView.swift`, inline `TipModule`. No `@Model` yet.
- **Model change (new type — the one shared-file edit in this batch):** add a `TipCalculation` `@Model`
  (`bill`, `tipPct`, `people`, `tipAmount`, `total`, `date`) in a new `TipModels.swift`, and register it
  in `Core/SnappetCore.swift` by appending `TipCalculation.self` to `SnappetSchema.models`. Keep that edit
  to a single appended line (merge-friendly; this branch merges last).
- Pushed into the App Library's `NavigationStack`; **no nested `NavigationStack`**. History is a pushed
  screen (`NavigationLink`/`.navigationDestination`).
- `core.log(module: "tip", action: "calc", …, metric: tipAmount)` already fires on bill commit — keep it,
  and also persist a `TipCalculation` at the same moment.

## Approach

- **Persist history** — new `TipModels.swift` (`TipCalculation` `@Model`); insert one on each committed
  calculation. New `TipHistoryView.swift`: list past calculations (bill, tip%, people, total, relative
  date) newest-first, with swipe-to-delete and a "Clear all" toolbar action.
- **Editable presets** — store the four preset percentages in `@AppStorage` (comma-encoded or four keys);
  a small editor (sheet or inline steppers) to change them; the preset buttons read from it.
- **Round-up** — a toggle that rounds the total up to the nearest whole currency unit and back-computes the
  effective tip; keep currency formatting locale-driven as today.
- Add `.accessibilityIdentifier(...)`: bill field (`tip.bill`), each preset (`tip.preset.<idx>`), custom
  slider (`tip.customPct`), people stepper (`tip.people`), round-up toggle (`tip.roundUp`), result rows
  (`tip.total`, `tip.perPerson`), history link (`tip.history`), history rows (`tip.historyRow`).

## Output

- New `Features/Tip/TipModels.swift` + `TipHistoryView.swift`; edits to `TipRootView.swift` (presets
  editor, round-up, history link, identifiers, persist-on-commit); one appended line in
  `Core/SnappetCore.swift`. New `SnappetUITests/TipUITests.swift`. This prompt asset; a `decisions.md`
  line (first persisted model for Tip).

## Acceptance criteria

- [ ] Committing a calculation saves a `TipCalculation`; the History screen lists it; swipe deletes; clear-all empties it.
- [ ] Preset percentages can be edited and persist across relaunch; the preset buttons reflect the edits.
- [ ] Round-up rounds the total up to the nearest currency unit and the per-person split stays consistent.
- [ ] `TipCalculation.self` is registered in `SnappetSchema.models` (single appended line).
- [ ] bill/preset/people/round-up/results/history controls carry stable `accessibilityIdentifier`s.
- [ ] `xcodegen generate` + `xcodebuild build-for-testing` (iPhone 17 Pro sim) → clean (Swift 6, 0 warn);
      `TipUITests` compiles.
- [ ] No nested `NavigationStack`; no platform imports in `HighlightEngine`.

## Constraints

- On-device only; no new dependencies. Keep the `SnappetSchema.models` edit to one appended line.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=F1A2B6B8-C609-47F8-8D55-44D94C5577B4' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build-for-testing` → succeeds.
2. `TipUITests`: enter a bill, pick a preset → open History → assert a row; edit a preset % and assert the
   button updates.
