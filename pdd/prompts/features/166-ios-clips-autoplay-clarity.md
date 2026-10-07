# Prompt: Clips — a labelled autoplay control that says what it did

**File**: pdd/prompts/features/166-ios-clips-autoplay-clarity.md
**Created**: 2026-10-06
**Project type**: Native iOS UI change (SwiftUI) — code lands in this repo.
**Chain**: Clips review 2026-10-05 → item 7 ("play.slash in the toolbar doesn't read as autoplay") — built overnight
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The autoplay toggle was a bare `play.slash` / `play.circle.fill` glyph — it didn't read as "autoplay", and when Low
Power Mode or Reduce Motion held autoplay back, "on" silently did nothing.

## Approach

- Toolbar: a labelled "▶ Autoplay" / "⏸ Autoplay" capsule (brand-tinted when on); accessibility value On/Off.
- A toast confirms each tap, from the pure `ClipAutoplayCopy` — including "paused while Low Power Mode / Reduce
  Motion is on".
- The hide-undo toast (164) and this share one `ClipFeedToast` slot, so toasts never stack.
- Default stays OFF (the review offered "default on"; kept opt-in — autoplay's device behaviour is the user's call).

## Acceptance criteria

- [x] Labelled control; toast on tap; system-held state explained (unit-tested copy).
- [x] `SnappetTests` 2369 green; `ClipsFeedUITests` 6/6 incl. the new autoplay test; toolbar fits on iPhone 17 Pro.
- [ ] Device: tap it on and off; try with Low Power Mode on.
