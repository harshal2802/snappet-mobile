# Prompt: Clips grid — a month scrubber and pinch for columns

**File**: pdd/prompts/features/176-ios-clips-grid-move-fast.md
**Created**: 2026-10-10
**Project type**: Native iOS feature (SwiftUI) — code lands in this repo.
**Chain**: clips-grid wireframes (`docs/ux-research/clips-grid/`, screen 4)
**Context**: `pdd/context/decisions.md`

## Approach

- **Month scrubber** (≥ 3 months): short labels down the trailing edge ("Oct", "Jan ’26" where the year changes);
  drag along it to fly through months (instant scroll while dragging, a bubble names the month). Pure
  `ClipGridModel.monthIndex(atFraction:count:)` + `scrubberLabel`.
- **Column toggle** in the grid toolbar (3 ⇄ 5) — visible, accessible, tested — and **pinch** in → 5, out → 3
  (`ClipGridModel.columns(afterPinch:current:)`) as a gesture shortcut, both remembered
  (`@AppStorage("clips.grid.columns")`). The grid content is at least a screen tall with a hit shape so a pinch
  anywhere reaches the gesture (a short month left most of the screen empty).
- UI-test resets: `clips.grid.columns` joins `clips.autoplay` in the test-launch reset (a run ending at 5 columns made
  the next run's pinch-in a no-op).

## Acceptance criteria

- [x] The toolbar toggle switches 3 ⇄ 5 columns (UI test measures the 2nd cover's position).
- [ ] Pinch: XCUITest's synthetic pinch is NOT recognised inside the scroll view (an earlier "it works" screenshot was
      a persisted 5-column state from a prior run — caught once the test-launch reset existed). Device check owed.
- [x] Scrubber mapping / labels / pinch thresholds unit-tested.
- [ ] Device: scrubbing through a year of months; pinch feel.

## Follow-up (device feedback, 2026-10-10): "pinch feels little laggy … month slider looks pretty weird"

- **Pinch** now switches the moment it crosses the threshold (not on release), with a light haptic and NO re-layout
  animation — the animated relayout of the whole grid was the lag. (Thumbnails were not reloading: `ClipThumbnail`
  keys its load on the clip + poster time, not its size — checked before changing anything.)
- **Scrubber** is now a Photos-style handle: a small pill on the trailing edge that appears while you scroll
  (fades 1.5 s after), rides the scroll position, and drags through months with a bubble + selection haptic. The
  column of month labels (and `ClipGridModel.scrubberLabel`) is gone.
