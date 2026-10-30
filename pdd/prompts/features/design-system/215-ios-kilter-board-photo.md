# Prompt: Your own board photo behind the holds (prompt 215)

**File**: pdd/prompts/features/design-system/215-ios-kilter-board-photo.md
**Created**: 2026-10-29
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved)**: `docs/ux-research/design-system/kilter-climb.html` — "New: add a photo of your board (option 1)"
**Depends on**: prompt 214 (#407)

## Goal

User: "do you think we can also put a real kilter photo?" → option 1, their own photo. A photo of their board
shows behind the hold shapes. Aurora's board images stay out (decisions 2026-06: copyrighted, the repo ships no
Aurora data).

## Approach

- `KilterBoardPhoto.swift`:
  - pure `KilterBoardPhotoMath`: bilinear quad point, the quad extended by a 6 % margin, the photo rect in the
    view, output size at the board aspect;
  - pure `KilterBoardPhotoPick`: the connected board's own photo first, else the newest for that layout + size;
  - `KilterBoardPhotoStore`: index in UserDefaults, JPEGs in Application Support, in-memory cache;
  - `KilterBoardPhotoRectifier`: bakes orientation, then Core Image `perspectiveCorrection` on the extended quad,
    drawn at the board aspect.
- `KilterBoardPhotoSheet` has three steps:
  1. take or choose the photo;
  2. `KilterCornerPicker` — drag or tap the numbered markers onto the four corner holds (TL, TR, BR, BL);
  3. preview with every hole as a dot plus the open climb's shapes; Adjust corners / Save photo. Remove is in
     step 1.
- `KilterBoardView(photo:showsGridOverPhoto:)`:
  - the photo maps the hole area (`pt(0,0)…pt(1,1)`) grown by the same margin;
  - grid dots are hidden over the photo (the real holes show), except in the line-up check;
  - stroked holds get a dark halo for contrast.
- Entry points:
  - climb page Board card: "Add a photo of this board ›" / "Board photo ›";
  - the "Your photo" chip on the board;
  - Kilter Settings → Board photo, which works without a board connected or on a simulator.

## Acceptance

- [x] `KilterBoardPhotoTests`: bilinear, margin, photo rect = extended quad, aspect, pick order, rectifier size (6/6).
- [x] Simulator (`KilterBoardPhotoUITests`, DEBUG sample wall via `-uiTestBoardPhotoSample`): corners → line-up → save → shows behind the holds on a climb (aligned) → remove. UI tests use a scratch store (prompt-133 rule).
- [ ] Device: photograph the real board; holds line up across a few climbs.
