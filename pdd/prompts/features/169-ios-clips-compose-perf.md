# Prompt: Clips — fix the 5.7 s feed compose (prompt 163 regression)

**File**: pdd/prompts/features/169-ios-clips-compose-perf.md
**Created**: 2026-10-06
**Project type**: Native iOS perf fix — code lands in this repo.
**Chain**: phone check after merging #351–#359 — user: "clips tab takes time to load and little laggy"
**Context**: `pdd/context/decisions.md` (2026-09-23 Clips perf measurements)

## Goal

Find and fix the Clips tab's slow load, measured on the device rather than guessed.

## What the device probe showed (temporary diag build, never merged)

- Feed compose (background) **5,666 ms** (September baseline ~430 ms); first card **5.8 s** after entering the tab;
  the same 6.2 s compose re-ran on every tab entry.
- Cause: prompt 163 made every clip's tile explicit, so `ClipHROverlay.make` ran `resolveTile` — up to 60 readings
  per animated stat — for all 1,771 clips just to ask "would this tile draw anything?". Mac benchmark: 300 clips
  163 ms without a tile vs 849 ms with one.

## Approach

- `HROverlayValues.wouldDraw(_:)` answers the same question without building segments (chart → yes; otherwise the
  first reading of any enabled stat). Used by `ClipHROverlay.make` and the reel preview. Equivalence with
  `resolveTile != nil` unit-tested across every design, single-stat tiles, live/animated, rest/no rest, and
  dense/sparse/empty windows.
- Re-entering the tab with posts showing refreshes 600 ms later, after the tab switch lands.

## Result (same routine, same phone)

| | Before | After |
|---|---|---|
| Compose on entry | 5,666 ms | 411 ms |
| First card | 5.8 s | 0.6 s |
| Re-entry first card | 9 ms (+6.2 s compose) | 11 ms (+374 ms compose, deferred) |
| Scroll hitches | ~98/min, bursts to 520 ms | ~48/min, mostly < 40 ms |

## Acceptance criteria

- [x] `SnappetTests` 2375 green incl. `HROverlayWouldDrawTests`; device re-measured.
