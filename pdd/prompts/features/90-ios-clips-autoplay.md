# Prompt: Clips — autoplay-on-scroll (opt-in, muted)

**File**: pdd/prompts/features/90-ios-clips-autoplay.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 85 (Clips inline play) → the autoplay follow-up (#3) — explicitly opted into eyes-open.
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## ⚠️ Risk note (READ FIRST)

An inline auto-clip player was **dropped in R12** for rendering a **black box** in the scrolling card —
its scroll-center coordinator (`FeedActivePlayerCoordinator`) assigning players to recycled rows was the
cause. This prompt does autoplay **without** that coordinator and reusing the **proven** `ClipMediaSurface`
(tap-to-play, prompt 85), but the inline render is the same R12 risk. So autoplay ships **opt-in
(default OFF)** behind a toggle, **muted**, gated on Reduce Motion + Low Power — and **must be
device-verified** (watch for a black inline frame) before the default is ever flipped.

## Goal

When autoplay is ON, the feed card that's substantially on-screen plays its clip **muted** as you scroll;
scrolling to the next card transfers play. Tap to unmute; tap again pauses. Reuses the Phase-1 inline
player + the `playingClip` single-active state — autoplay just drives `playingClip` from a per-card
**`.onScrollVisibilityChange`** signal (NOT scroll-center geometry / a coordinator).

## Approach

- `PlayingClipRef` gains `muted: Bool`; the `isPlaying` check compares post+page only (`matches(_:_:)`).
- `ClipMediaSurface` gains `muted: Bool` → sets `player.isMuted`; a tap on a muted (autoplaying) surface
  **unmutes** (local `unmutedByTap`), a further tap pauses/resumes.
- `ClipsFeedView`: `@AppStorage("clips.autoplay")` (default false) + a nav-bar toggle
  (`play.circle`/`play.slash.fill`); `autoplayActive = enabled && !reduceMotion && !LowPower`. When
  autoplay is on, the existing `.onScrollPhaseChange`-stops-playback is suppressed.
- `ClipPostCard`: `.onScrollVisibilityChange(threshold: 0.7)` — when `autoplayActive` and the card crosses
  the threshold, set `playingClip = (post.id, page, muted: true)`; when it drops below and it was this
  card's, clear. (At ~0.7, only one full-width card is "visible" at a time → one autoplay.)

## Output

- `ios/App/Snappet/Features/Feed/ClipMediaSurface.swift` (mute + tap-unmute).
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` (`PlayingClipRef.muted`, the toggle, the
  visibility-driven autoplay, the suppressed scroll-stop).
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] With autoplay ON, scrolling plays the on-screen card's clip muted; scrolling transfers play; only one
      plays at a time; tap unmutes, tap again pauses.
- [ ] Default OFF; a nav-bar toggle flips it; no autoplay under Reduce Motion or Low Power.
- [ ] Tap-to-play (prompt 85) still works with sound; the fullscreen viewer + Recap unchanged.
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` green.

## Constraints

- No scroll-center coordinator (R12). One live player (reuse `ClipMediaSurface`). The inline render is the
  R12 risk → **device-verify before defaulting ON**.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — build 0-warning, suite green; `ClipsFeedUITests` green.
2. On a device with clips: toggle autoplay on; scroll → the on-screen clip plays muted; scroll → transfers;
   tap → unmutes; toggle off → no autoplay. **Watch for a black inline frame (R12).**
