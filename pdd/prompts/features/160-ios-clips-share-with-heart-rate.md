# Prompt: Clips — "Share with heart rate" in one tap

**File**: pdd/prompts/features/160-ios-clips-share-with-heart-rate.md
**Created**: 2026-10-06
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips review 2026-10-05 → item 1 of 3 (160 share with HR · 161 climb outcomes · 162 durable favorites)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The heart-rate scorebug is what makes a Clips post a Clips post, but ⋯ → "Share clip" hands over the RAW
video (prompt 87). Getting the overlay out meant ⋯ → Edit this clip → Studio → Export. Make the burned share
the primary, one-tap share from the feed.

## Context the implementer needs

- `ClipHROverlay.make` already builds every clip's payload (window samples + tile — the feed scorebug or the
  session's saved Studio tile) and the feed caches it per media id (`ClipsFeedView.cachedPayloads`).
- `StudioOverlays.makeAnimationTool(overlays:canvas:totalDuration:clipHR:)` burns a `PlacedClipHR` tile and a
  `.climbName` lower-third — the Studio export's own path.
- Reels and baked clips already carry their HR in the pixels (they get no live overlay), so their raw share IS
  the burned share.
- The simulator has no H.264 encoder (ReelExporter notes): the burned render is device-only.

## Approach

- Pure `ClipSharePlan` (Features/Feed): `offer(for:payload:)` → none / raw / burnedAndRaw; `plan(...)` →
  kept range (`ClipHROverlay.playedRange`) + `PlacedClipHR` from the SAME payload the poster draws + a caption
  (title · detail · attempt); `clamped(_:assetDuration:)` re-slots the tile when the asset is shorter than
  the stored duration.
- `ClipShareService.exportWithHeartRate(plan)`: one-clip `AVMutableComposition` at native orientation and
  resolution, video composition built from the composition's properties (the -11838 lesson), the Studio's CA
  tool with the tile + a top-of-frame caption (the scorebug sits at the bottom). Audio track only if present.
- ⋯ menu: "Share with heart rate" (primary) + "Share original clip"; raw-only cases keep "Share clip".

## Acceptance criteria

- [x] A video with HR offers "Share with heart rate" and "Share original clip"; a reel/baked/no-HR video
      offers only "Share clip"; a photo offers no share.
- [x] The burned render uses the poster's payload and the Studio trim (unit-tested).
- [ ] Device: the shared file shows the poster's tile with the dot sweeping, plus the caption, at native
      orientation; Messages/Photos play it. (device leg owed)
- [x] `SnappetTests` green (bar the pre-existing midnight flake in `HouseholdSurfacesTests`), 0 new warnings.

## Constraints

- No new persistence; no change to the raw lane.
- On-device only.

## Test plan

1. `make ios-test-unit` — `ClipSharePlanTests` (offer matrix, payload reuse, trim, caption, clamp).
2. Device: ⋯ → Share with heart rate on a climb clip, a trimmed clip, and a custom-Studio-tile clip; compare to
   the poster.
