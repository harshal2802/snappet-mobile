# Prompt: Design-system reset — Kilter plan, Your Climbs, On the Board & setup (prompt 229)

**File**: pdd/prompts/features/design-system/229-ios-kilter-plan-created-restyle.md
**Created**: 2026-11-04
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "okay looks good")**: `docs/ux-research/design-system/kilter-plan.html`
(before: `kilter3-before-*.png`, as built: `kilter3-after-*.png`)

## Goal

Kilter part 3, the last Kilter group:
- `KilterPlanView`, `KilterPlanConfigSheet`, `KilterPlanAddClimbSheet`, `KilterLiveChip`
- `KilterCreatedView`, `CreateClimbView`
- `KilterOnTheBoardView`, `KilterBoardSetupSheet`, `KilterNearbyBoardsSheet`, `KilterScannerView`

It is visual only, plus one layout fix.

The user caught the first wireframe drawing 4 of 6 plan strategies. That led to a wireframe audit: the Adjust plan
sheet is now drawn in full, and every restyle wireframe gained an "As built" row and an omissions table (see
decisions).

## Approach

- **Plan header (layout fix):** the history line on its own row, then the working-grade / "starting easy" note,
  then the Reset / Shuffle / Edit / strategy chips. Beside the text, the text squeezed into a narrow column and the
  chips truncated ("Re-set", "Bal…").
- **Accent:** `moduleAccent("kilter")` / `SnappetColor.kilter` → the user's accent across these files.
- **Climb meaning colours:** sent / tried badges are perfFresh / perfModerate outlines (were system green / orange
  fills), and the status glyphs use the same tokens.
- **Sentence case:** "Next up" in the accent (was "NEXT UP" orange caps), "Draft" (was tracked "DRAFT").
- **Your Climbs:** neutral grade badges (were amber).
- **On the Board:** a light count (was heavy amber rounded) and a label caption.
- **Live chip:** the accent with ink text (was white on amber).
- **Contrast:** compact `.borderedProminent` buttons use `.snappetPrimary` (ink-on-accent); the board-setup Save
  uses `SnappetWidePrimaryStyle`.
- **Nearby boards:** the serial is secondary (was orange), the flashing board uses the accent (was blue), and the
  signal bars stay green.

## Acceptance

- [x] Affected suites: all 11 Kilter UI suites (22 tests) green. As-built plan / running plan match the mockup.
- [ ] Unit suite alone.
- [ ] Device: user on MrRobot.
