# Prompt: Clips — a default overlay style (HR tile + title) for every clip

**File**: pdd/prompts/features/163-ios-clips-overlay-style.md
**Created**: 2026-10-06
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follow-up to 160 (Share with heart rate) — user: "is there a way to configure default HR chart config and title config?"
**Design**: `docs/ux-research/clips-overlay-style/wireframes.html` (approved 2026-10-06; user: backed up, apply to posts AND shares)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

One default for every clip's heart-rate tile and title, set from a ✎ sheet in the Clips toolbar, applied to feed
posts, fullscreen, Share with heart rate and highlight reels — so a post and the video shared from it match.
Precedence: a session styled in the Studio → the user's default → the built-in Broadcast scorebug.

## Approach

- Pure `ClipOverlayStyle`: tile (design/stats/chart/zone colour/transparency via `HRTile`), tile edge, title on/off,
  ordered parts (headline group name+outcome → big line; the rest → small line), title edge, chip/plain look.
  Rules: `titleText`, `tile(sessionTile:restHR:)` (precedence + HRR-off-without-rest), `switching(to:)`, per-design
  `posterSize`/`hAlign`, `placed(_:edge:canvas:)` and `titleOrigin` — the share's twin of the poster layout.
  Forward-compatible decode. Built-in == today's look.
- Persistence: one `ClipOverlayDefaults` @Model row (JSON blob) — in `SnappetSchema` + the backup envelope.
  `ClipOverlayStyleStore` caches it; re-attached each feed rebuild (picks up a restore).
- `ClipOverlayChrome`: the ONE SwiftUI title+tile layout — the poster and the sheet preview both use it.
- Share: tile placed by `placed`, title burned as CA layers at `titleOrigin` (new `extraLayers` on
  `StudioOverlays.makeAnimationTool`).
- Reels: the default's tile (design/stats/transparency) for preview + burn; placement unchanged.

## Acceptance criteria

- [x] ✎ sheet: design, stats, chart, zone colour, transparency, top/bottom; title on/off, parts + reorder,
      top/bottom, chip/plain; live preview on the user's own clip (sample when none); Reset to built-in.
- [x] The saved default survives reopen and a backup round-trip; built-in look unchanged for users who never open it.
- [x] Posts + share + reels use it; a session's Studio tile still wins.
- [x] `SnappetTests` green (2359); `ClipsFeedUITests` 4/4 incl. the new sheet test.
- [ ] Device: each design on a real clip, top/bottom both edges, plain title; a shared video matches its post.

## Known limits

- Fullscreen shows the default tile, but its title is still the viewer's own name tag.
- Reels keep each design's default placement (no edge).
