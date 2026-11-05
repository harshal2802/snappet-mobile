# Prompt: Design-system reset — Journal (prompt 239)

**File**: pdd/prompts/features/design-system/239-ios-journal-restyle.md
**Created**: 2026-11-05
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved)**: `docs/ux-research/design-system/small-apps.html` (Journal section)

## Goal

Restyle Journal (small apps 3/6, stacked on 238). It is visual only.

## Approach

- **Colour:** Journal purple becomes the user's accent; Journal joins `suiteAccentModules`.
- **Rows:** the title is medium weight (was a bold headline), the date is detail grey, and tags are in the accent.
- **Editor:** the title is medium weight; tag chips are accent outline `snappetPill`s (were tinted fills).

## Acceptance

- [x] Affected suites: `JournalUITests` 4/4. As built matches the mockup.
- [ ] Unit suite alone (once for the stack).
- [ ] Device: user on MrRobot (batch).
