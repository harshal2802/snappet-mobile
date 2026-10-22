# Prompt: Fix — the first Clips open waits on every HR overlay

**File**: pdd/prompts/features/202-ios-clips-first-load.md
**Created**: 2026-10-22
**Project type**: Native iOS performance fix (SwiftUI / SwiftData) — code lands in this repo.
**Context**: `pdd/context/decisions.md`

## Bug

Backlog from prompt 193: "the first Clips load decodes every `WorkoutSession.hrSeries` on main in `makeSnapshot`".
Measured on MrRobot before the fix: cold launch straight into Clips (`snappet://clips`), 1,805 clips, 372 workouts,
three runs.
- `makeSnapshot` on main ~120 ms, of which the `hrSeries` decode was ~78 ms (70,698 points, 307 sessions).
- **A second full rebuild started right after**: `rebuildFeed` loads the saved overlay style
  (`overlayStore.attach`), and `.onChange(of: overlayStore.style)` rebuilt again.
- Off-main compose ~520–580 ms, nearly all of it per-clip HR overlay payloads (1,075 clips; posts ~25 ms).
- The feed painted ~770 ms–1.2 s after the tab opened.

## Fix

- The style `onChange` only rebuilds for a style the feed wasn't built with (`snapshotStyle`).
- **Paint first**: the snapshot reads HR only for the 8 newest filmed sessions (pure
  `ClipFeedComposer.firstPaintSessions` — the top of every level, posts sort newest first). Compose builds posts +
  those overlays, and the feed shows.
- **Then the rest, off main**: a background `ModelContext` reads the other sessions' HR and builds their overlays,
  then the caches become exactly this build's results. Until then a rebuild keeps the previous overlays, so
  nothing further down blanks.

## Acceptance criteria

- [x] Device, same 3 cold launches: main-thread snapshot ~50 ms (from ~200 ms incl. the duplicate); feed paints
      ~260–310 ms after the tab opens; the remaining ~1,070 overlays land ~0.6–0.85 s later, off main; one rebuild.
- [x] `ClipFeedFirstPaintTests`; unit 2535 green; Clips UI suites green.
- [ ] Device feel: open Clips cold — the feed appears at once; scroll down — overlays are there.
