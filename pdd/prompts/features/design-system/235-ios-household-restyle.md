# Prompt: Design-system reset — Household (prompt 235)

**File**: pdd/prompts/features/design-system/235-ios-household-restyle.md
**Created**: 2026-11-05
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "looks good. lets implement it")**: `docs/ux-research/design-system/household.html`
(before: `household-before-*.png`; as built: `household-after-*.png`, the "As built" row)

## Goal

Restyle the Household mini-app to the design system. It is visual only: ids, flows and layout order are unchanged.

## Approach

- **Colour:**
  - Household's sage (`SnappetColor.household`) becomes the user's accent everywhere inside. Sage stays on the App
    Library card.
  - Household joins `AppLibraryView.suiteAccentModules`, so back, +, Cancel / Save and pickers follow the accent.
- **Buttons:**
  - Ink-on-accent `SnappetWidePrimaryStyle`: Add a chore, Open Settings, Make a new code, Join.
  - Accent outline pills (`HouseholdPillStyle`): I'll do it, Take it, 👏 Thank.
  - Neutral outline (`HouseholdOutlineStyle`): Take back, Copy invite link, Invite someone else, Start with common
    chores. End is a red outline.
- **Rows:** the done check is an accent fill with an ink tick. Names are medium weight. The S / M / L effort badge is
  a hairline outline. Overdue stays red.
- **Pet card:** the 3D pet keeps its hue gradient. The card is the one panel. The date / sync chips are neutral; the
  sync dot keeps its status colour. The mood line follows the buddy's rule. The goal bar is thin and in the accent.
- **Power hour:**
  - The start row has an accent label and a chevron.
  - The running banner has a light countdown and a thin bar.
- **Week:**
  - The house goal card is the panel, with a sentence label, a light number with a small unit, and a thin bar.
  - Day bars are in the accent on days with chores, with hairline stubs on empty days; today's label is primary.
  - Fair share: Balanced is a green outline, Uneven an amber one. The person colours stay.
- **Recap:** the green gradient card becomes the panel, with an accent date, a light 40-pt number and "Thank-yous" in
  sentence case. The share image renders the same card in dark.
- **Household section:**
  - The Local Network title is red and Open Settings is primary.
  - The platform badge is an outline. The nearby dot is green.
- **Invite / join:** trust icons are grey; the joined ✓ and joined ⌂ are in the accent.
- **Editor:** picked menu values are grey like Settings. The selected weekday is ink on the accent.

## Acceptance

- [x] Affected suites: `HouseholdUITests` 5/5. `HouseholdE2ETests` needs two simulators and is skipped in normal runs.
  As built matches the mockup.
- [x] Unit suite alone: 2690 green.
- [x] Device: user on MrRobot 2026-11-05 ("looks good").
