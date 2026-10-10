# Prompt: "Tag artist" opens the review on the clip you tapped

**File**: pdd/prompts/features/172-ios-clips-tag-artist-focus.md
**Created**: 2026-10-10
**Project type**: Native iOS fix (SwiftUI) — code lands in this repo.
**Chain**: phone check of 171 — user: "it is taking me to festivals review tags section but it is not highlighting
the video i just clicked on … which is confusing"
**Context**: `pdd/context/decisions.md` (festival prompt 03 review sheet)

## Problem

The review sheet lists one day's "Needs you" + "Auto-tagged" rows. From Clips the tapped clip could be on another day,
deep in a list, or absent entirely (a clip marked "Not from a set" appears in neither list — it couldn't be re-tagged).

## Approach

- `FestivalTagReviewView(focusMediaIDs:)`: opens on the first focus clip's day and pins a highlighted card ("THE CLIP
  YOU TAPPED" / "FROM CLIPS · N CLIPS") at the top for those clips — thumbnail, filmed-at time, state (tagged / best
  guess % / marked not from a set / no set playing), and **Change ›** whatever the state. Focus clips aren't repeated
  in the lists below.
- **Pick another set…**: every set of that day ordered by `FestivalTagging.setsByProximity` (playing-then first, then
  by minutes away; "PLAYING THEN" marker) — any clip can be tagged to any artist.
- Clips passes the clip on screen first, then the rest of the post's clips.

## Acceptance criteria

- [x] Tapping Tag artist lands on the tapped clip, highlighted; re-tag works from any state (user-verified on device).
- [x] `SnappetTests` 2385 green (proximity order unit-tested); Clips UI test for the pinned card.
