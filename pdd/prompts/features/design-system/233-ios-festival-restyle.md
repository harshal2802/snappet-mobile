# Prompt: Design-system reset — Festival (prompt 233)

**File**: pdd/prompts/features/design-system/233-ios-festival-restyle.md
**Created**: 2026-11-04
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "this redesign look nice")**: `docs/ux-research/design-system/festival.html`
(before: `festival-before-*.png`; as built: `festival-after-*.png`, the "As built" row)

## Goal

This is a visual-only restyle of the Festival mini-app to the design system. Behaviour shipped in prompt 232 (#425).
Ids, element types and actions are unchanged.

## Approach

- **Orchid → the user's accent** (`SnappetColor.festival` → `.brand`) for every button, tile, star and highlight.
  Kilter switched the same way in #406. Orchid stays only as Festival's identity colour in the App Library module card
  and the Clips activity chips.
- **Buttons:**
  - Every `.borderedProminent` + tint becomes ink-on-accent `SnappetWidePrimaryStyle`. That covers I'm here, Make a
    reel, Make my festival reel, the import confirm, Build a draft, Share link, the tour / checklist CTAs and Download.
  - The empty state's Import / Scan poster / Scan QR / Create are outline buttons.
- **Schedule:**
  - Day tabs are outlined, the selected one with an accent outline (was an orchid fill with white text).
  - Stage labels are sentence case (were caps).
  - Set rows are neutral panels, the live one with an accent outline. The NOW badge is an accent outline pill reading
    "Now · …". Times use monospaced digits.
- **Live sheet:** a sentence-case kicker ("On the floor · Stage") on a neutral panel (was orchid-tinted).
- **Set page:**
  - one stat panel with light numbers
  - "Your heart rate" / "Clips from this set" labels
  - the ✦ Auto badge is ink-on-accent
- **Recap:** the hero is a neutral panel with light numbers (was a solid orchid gradient). Peak ♥ stays red. Artist
  tiles are neutral.
- **Tag review:** sentence-case section labels, day chips as `snappetPill`, and a neutral focus card with an accent
  outline. Amber "needs you" stays.
- **For you:** a sentence-case kicker on a neutral hero.
- **Getting started:**
  - semibold, not heavy, titles
  - sentence-case "Step one…" kickers
  - neutral feature tiles
  - a neutral banner
  - the tent's glow removed
  - the done step stays green
- **Catalog:** year chips as `snappetPill`, "Get" instead of "GET", neutral row tiles.
- **Kept on purpose:** clash amber, HR red, the Installed / done green, the QR's white card, and the timeline blocks'
  accent tint.

## Acceptance

- [x] Affected suites: `FestivalUITests` 11/11 and `ClipsFeedUITests` 12/12 green. Two label assertions were updated
  for sentence case ("Now · …", "Pyramid Stage"). As built matches the mockup.
- [x] Unit suite alone: 2690 green.
- [ ] Device: user on MrRobot.
