# Prompt: Design-system reset — Budget (prompt 241)

**File**: pdd/prompts/features/design-system/241-ios-budget-restyle.md
**Created**: 2026-11-05
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved)**: `docs/ux-research/design-system/small-apps.html` (Budget section)

## Goal

Restyle Budget (small apps 5/6, stacked on 240). It is visual only; the donut crash fix (#429, prompt 236) is
underneath. Ids are unchanged.

## Approach

- **Colour:** Budget blue becomes the user's accent (month chevrons, toolbar menu, swipe Edit, bars, trends); Budget
  joins `suiteAccentModules`.
- **Summary:** Budget / Spent / Remaining sit in one `snappetPanel` with light 22-pt amounts and sentence labels (were
  three coloured bold tiles). Remaining turns red (`perfHard`) with a warning glyph only when over.
- **Category rows:**
  - A thin bar on a hairline track: accent, amber (`perfModerate`) from 85%, red when over. These replace system
    blue / orange / red.
  - The name is medium weight; the amounts are grey detail.
- **Trends row:** a neutral icon tile.
- **Donut:** the categorical slice colours stay (identity); the centre total is light.
- **Trends:** thin accent bars (was a blue gradient), with a sentence label.
- **Transactions:** the note is medium weight and the amount regular (were bold).
- **Empty state:** "Add category" is ink-on-accent at a fixed width.

## Acceptance

- [x] Affected suites: `BudgetUITests` 2/2 (incl. the two-category crash regression). As built matches the mockup.
- [ ] Unit suite alone (once for the stack).
- [ ] Device: user on MrRobot (batch).
