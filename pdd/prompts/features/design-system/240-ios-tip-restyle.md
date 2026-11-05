# Prompt: Design-system reset — Tip Calculator (prompt 240)

**File**: pdd/prompts/features/design-system/240-ios-tip-restyle.md
**Created**: 2026-11-05
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved)**: `docs/ux-research/design-system/small-apps.html` (Tip section)

## Goal

Restyle Tip Calculator (small apps 4/6, stacked on 239). It is visual only. The `tip.total` / `tip.perPerson` ids
stay.

## Approach

- **Colour:** Tip teal becomes the user's accent (slider, Edit presets, toolbar); Tip joins `suiteAccentModules`.
- **Results:** one row. Per person is a light 36-pt number, with "Tip $x · Total $y" grey beneath it (were three
  rows, with per person bold teal).
- **History:**
  - The bill is medium weight (was bold).
  - "Clear all" is red. A toolbar button ignores the destructive role's colour, so it was blue.

## Acceptance

- [x] Affected suites: `TipUITests` 2/2. As built matches the mockup.
- [ ] Unit suite alone (once for the stack).
- [ ] Device: user on MrRobot (batch).
