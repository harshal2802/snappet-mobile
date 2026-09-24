# Prompt: Clips scroll — warm posters ahead of the scroll, never blank on a decode

**File**: pdd/prompts/features/134-ios-clips-poster-prefetch.md
**Created**: 2026-09-23
**Project type**: Native iOS performance fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: user report — "diagnose the lag when i scroll through clips"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make the Clips feed keep up with a normal scroll on a real library (**1,771 clips · 336 sessions ·
306 posts** on the reporter's device).

## What the device actually measured (before)

| | |
|---|---|
| video poster | avg **93 ms**, max 120 |
| photo poster | avg **71 ms** |
| one scroll (18 cards) | ~**1.5 s** of decode, ALL of it after the card appeared |
| feed rebuild | snapshot **107 ms on the main thread** + compose **434 ms** |
| saves / rebuilds per scroll | **1 / 1–2** |

A poster's load began only when its cell appeared (`.task(id:)`), so a normal flick outran the
loader and the user watched empty cards fill in behind them. Video costs ~31% more because
`AssetPosterLoader.videoFrameZero` decodes the EXACT frame 0 (prompt 97's invisible poster→video
handoff) — worth it for the card you play, wasteful for the 300 you scroll past.

**A hypothesis this replaces:** the obvious reading of the code said `backfillAspect`'s
`context.save()` per post cascaded through all seven `@Query`s into repeated main-thread rebuilds.
Measured: 1 save, 1–2 rebuilds per scroll. The story was wrong; the device settled it.

## Approach / Output

1. **Prefetch ahead** — `AssetPosterLoader.prefetch(_:pointSize:)` warms the next
   `prefetchDepth = 3` posts as each row appears: `PHCachingImageManager.startCachingImages` for
   the thumbnail pipeline plus a throttled (`maxInFlight = 2`) frame-0 pre-bake into the existing
   `frameZeroCache`. Warms the SAME poster time the card will request, or the cache key misses and
   the work is wasted. A `warmed` set (cleared past 400) prevents re-enqueueing.
2. **Never blank on a decode** — `ClipThumbnail.load()` paints from `cachedFrameZero` when prefetch
   already won; otherwise a video shows Photos' cheap thumbnail FIRST, then swaps in the exact
   frame. The exact frame still lands long before a tap, so the invisible handoff is preserved — it
   simply no longer gates the first pixel.

## Verified on device (after — same scroll, same library)

| | before | after |
|---|---|---|
| cards painting instantly from cache | 0 | **13 of 18** |
| video cards waiting on a decode | 12 (avg 93 ms) | **1** (cold start) |
| photo first pixel | 71 ms | **55 ms** |

## Acceptance criteria

- [x] Most cards paint with zero wait during a normal scroll (13/18 measured).
- [x] No video card pays a frame-0 decode mid-scroll.
- [x] The poster→video handoff stays frame-exact for played clips.
- [ ] Not addressed here: the ~270 ms FIRST card at cold start (nothing precedes it to warm it) and
      the ~540 ms feed rebuild on entering the tab.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`.
2. Device: instrumented build, identical scroll, compare the table above.
