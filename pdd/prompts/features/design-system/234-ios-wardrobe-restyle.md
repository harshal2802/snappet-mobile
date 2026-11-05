# Prompt: Design-system reset — Wardrobe (prompt 234)

**File**: pdd/prompts/features/design-system/234-ios-wardrobe-restyle.md
**Created**: 2026-11-04
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement")**: `docs/ux-research/design-system/wardrobe.html`
(before: `wardrobe-before-*.png`; as built: `wardrobe-after-*.png`, the "As built" row)

## Goal

Restyle the Wardrobe mini-app to the design system and fix three layout bugs found while taking the before shots.
Ids and actions are unchanged.

## Approach

- **Colour:** Wardrobe's rose pink (`SnappetColor.wardrobe`) → the user's accent everywhere inside, including the
  image-migration banner. Pink stays only on the App Library card.
- **Buttons:**
  - Filled buttons become ink-on-accent `SnappetWidePrimaryStyle`: Style this, Generate outfit, Style me — custom
    occasion, Wear today, Add your first item, Take photo, Save to closet, Add value, Apply.
  - The + FAB and the coach send button are ink-on-accent.
  - Secondary actions become outlines: Ask coach, Shuffle, Save, Import from Photos, Wear again, Check price.
- **Chips:**
  - Occasion, filter, season, value-mapping and coach-question chips → `snappetPill`.
  - The item's tags → neutral outline chips.
  - Outfits' Saved / Favorites / Worn → pills instead of a second segmented control.
- **Item stats:** Worn / Last worn / Cost per wear sit in one panel with light numbers and sentence-case labels.
- **Forms:** picked values are grey like iOS Settings, and "Add" is tertiary.
- **Text:** role labels (Top / Cover) are sentence case; weights are regular / semibold.
- **Settings:** neutral icon tiles and banner; Delete is red.
- **Kept on purpose:** the unworn "0× · 3 mo" badge stays amber (as an outline); the price delta stays green / red.
- **Bugs:**
  1. **"Ope / n ›" and "Wear ›" squeezed into a sliver** beside the thumbnails. The action moves to the title row,
     and the home card now shows every piece (it used `prefix(4)`, hiding the accessory).
  2. **"Wear again ›" wrapped onto three lines.** It is now a full-width outline button.
  3. **Tidy said "1 values" and allowed "Apply 0 changes".** Both are pluralised correctly, and Apply is disabled as
     "Nothing to apply yet".
- **Found while building:**
  - The App Library tinted Wardrobe — and Festival, missed in #426 — with their own colour, so system controls
    (Cancel, the gear, back) stayed pink / orchid.
  - Both are added to `AppLibraryView.suiteAccentModules`.

## Acceptance

- [x] Affected suites: `WardrobeUITests` 3/3, `FestivalUITests` 11/11 (the tint change). As built matches the mockup.
- [x] Unit suite alone: 2690 green.
- [ ] Device: user on MrRobot.
