# Prompt: Activity progress P3 — Then vs Now, PR moments, progress reel

**File**: pdd/prompts/features/180-ios-activity-compare-prs-reel.md
**Created**: 2026-10-13
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: activity-progress ideation (`docs/ux-research/activity-progress/ideation.html`, §03 screen C, §04, §05 screen F,
§08 P3); builds on prompts 178–179
**Context**: `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Turn an activity's clips into visible progress: mark the sessions that were a first or a PR, compare any two clips
side by side, and cut a shareable progress reel with each clip's date and set burned in.

## Approach

- Pure `ActivityProgressReel`: `badges` (FIRST = oldest session, PR = strictly beats every earlier session on the
  dashboard's hero metric, direction-aware), `pick` (PRs only · one per month · all; videos only, oldest → newest),
  `caption` ("15 Sep 26 · 60 kg × 8"), `captionOverlays` (timed text overlays from the exporter's REAL placements).
- `ReelExporter.makePlacedComposition` records where each segment landed (skipped clips shift later ones);
  `export(… captions:)` burns caption overlays alongside the HR scorebug through the existing
  `StudioOverlays.makeAnimationTool`. `ReelSource.segmentCaptions` carries them.
- `ClipsReelScope.progress(ids, title:, captions:)` → the shared `ReelView` (full clips, chronological).
- `ActivityCompareView`: two `ClipMediaSurface`s in lockstep (sync start · play/pause · ½×), either side swappable,
  footer with time span · set → set · HR change. `ClipPlaybackController` gains `play/pause/setRate`.
- Past-clips sheet: Timeline / PRs ★ filter, PR/FIRST badges, a Compare + Progress-reel bar (≥ 2 videos). The
  dashboard's clips card gets the same two actions.

## Follow-up (2026-10-14, from device feedback)

"When I click Compare, should it give me an option to select which video?" — yes: Compare now opens
`ActivityComparePicker` (the videos grouped by session, first + latest pre-picked, tap to change the pair) and the
compare screen shows a visible "Change" button per side.

## Acceptance criteria

- [x] `ActivityProgressReelTests` (badges incl. ties + pace, pick rules, captions, placement timing).
- [x] UI test: PR filter, Compare footer + speed, Progress reel → reel builder (sim; assets fake).
- [x] Device build compiles the caption-burning export path.
- [ ] Device: exported progress reel shows each clip's caption over the right clip; Then vs Now plays in sync.
