# Prompt: Design-system reset, step 3d — Gym Tracker Library (prompt 218)

**File**: pdd/prompts/features/design-system/218-ios-gym-library-restyle.md
**Created**: 2026-11-02
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement")**: `docs/ux-research/design-system/gym-library.html`

## Goal

Restyle the Gym Tracker Library (`WorkoutLibraryView`: Yours + Explore). Every element keeps its place and
behaviour (checklist in the mockup).

## Approach

- **Sport chips** → `snappetPill`, the accent when on. The per-sport chip colour parameter is removed.
- **Rows** (Yours + Explore):
  - a neutral 34-pt tile (the climb's grade, or the sport glyph) and a medium-weight title;
  - Kilter / New / Custom / "Done · N days" as small outlined `LibraryTag`s;
  - climb status as coloured words (✓ Sent green, ◐ Project amber, Not tried grey).
- **Accent instead of the workout orange:** the sort link, Show hidden, the Pin swipe, the empty-state button and
  the filter sheet's selected pills.
- **Wording:** Explore's header reads "859 strength exercises", "24 climbs", "3 activities" via
  `WorkoutLibraryView.exploreCount`. It was "859 strengths".
- The list stays a plain `List` (swipe to pin / hide).

## Acceptance

- [x] `LibraryExploreCountTests`; dark screenshots of Yours + Explore · Strength match the mockup.
- [x] Full UI: 159/167 + reruns — `LibraryKilterUITests` updated for the "Kilter" tag (was "KILTER"), the contact-rep interval timeout passes alone (flake), only the known `525 kg` main failure remains; unit 2646 green.
- [x] Device: user on MrRobot — found the Yours count still read "3 strength"; fixed (`exploreCount` for Yours too); "looks fixed now".
