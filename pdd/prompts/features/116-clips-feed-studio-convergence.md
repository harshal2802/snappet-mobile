# Prompt: Clips feed ⇄ Studio convergence — live-reflect trims + the extended HR window

**File**: pdd/prompts/features/116-clips-feed-studio-convergence.md
**Created**: 2026-07-09
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 115 (extended HR window) → **116 (live-reflect)** → 117 (bake lane, next).
**Source**: user request — "any changes done on the individual clip editor should be saved in place and
reflected on the same clip in the Clips feed", following the prompt-115 mismatch report.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframes**: `docs/ux-research/clips-feed-convergence/wireframes.html` (approved: three-lane model,
EDITED chip, bake variants deferred to 117)

## Goal

Make the Clips feed reflect what the scoped Studio editor saved for a clip — **without** playing a
rendered composition per feed cell. Two things flow (lane ① of the approved model): **trims** (the
feed *plays* the kept range: looper time-range, fullscreen transport span, poster = first kept frame,
EDITED chip) and the **extended HR window** (the prompt-115 lead/tail panes, scope, and parked dot —
the same chart the export burns; a never-edited clip gets the same 0:05/0:30 defaults the Studio
applies). Speed/filters/text/PiP stay honestly out of live playback — they reach the feed via the
bake lane (prompt 117).

## Context the implementer needs

- The reflection pipeline already exists: every Studio edit persists (`undo.commit → persist`) and
  bumps `StudioProject.updatedAt`, which is in the feed's rebuild key (`FeedKey.newestEdit`).
  Prompt 116 only widens WHAT flows.
- The feed plays raw `PHAsset`s (prompt 97/106 perf work). `AVPlayerLooper` natively loops a
  `timeRange`; the fullscreen transport needs a start-offset mapping; the poster generator needs a
  frame-at-time parameter.
- With playback trimmed, the HR "footage" span IS the kept range — so the dot stays in sync. The one
  visible non-convergence: nothing (deliberately).
- Split clips: one asset → several `TimelineClip`s with adjacent trims; the feed shows one item per
  physical asset → the kept ENVELOPE. A media id with no surviving timeline clip must fall back to
  raw (a Studio removal never hides feed media). Degenerate trims (< 0.5 s kept) play raw.

## Approach

- `ClipStudioEdit` (new, pure): kept-trim range + HR lead/tail/scope per media id;
  `byMedia(clips:mediaIDByLocalID:)` resolves a project's timeline (envelope rule, photo skip,
  localIdentifier healing — the prompt-115 offset-recovery policy); `keptRange(rawDurationSec:)` is
  the ONE validity rule (clamp, degenerate, whole-clip identity) shared by playback, poster, and HR.
- `MediaInput.edit` (optional, default nil) — stamped in the feed's `makeSnapshot`; all other
  construction sites unchanged.
- `ClipHROverlay`: `make` builds the window via the SAME `StudioHRPlacement.extendedWindow` the
  Studio uses (footage = kept range), scope → `statsSamples`; `fraction` maps asset-time →
  kept-range-relative → `values.chartFraction`; `playedRange` is the loop/fold denominator;
  `atEnd(for:)` parks at the footage/tail boundary.
- Playback: `ClipMediaSurface` builds the looper with the kept `CMTimeRange` (inline) or sets
  `forwardPlaybackEndTime` + seeks + attaches with `startOffset` (fullscreen);
  `ClipPlaybackController.attach(_:duration:startOffset:)` translates the scrubber.
- Poster: `AssetPosterLoader.videoFrameZero(at:)` + `ClipThumbnail.posterTime`, cache-keyed by time.
- Chrome: the EDITED chip (top-trailing, kept-range label) on trimmed feed clips.

## Output

- New: `Features/Feed/ClipStudioEdit.swift`, `SnappetTests/ClipStudioEditTests.swift`
- Edits: `FeedMedia.swift`, `FeedInputs.swift`, `ClipsFeedView.swift`, `ClipHROverlay.swift`,
  `ClipMediaSurface.swift`, `ClipPlaybackTransport.swift`, `MediaBrowserView.swift` (ClipThumbnail),
  `AssetPosterLoader.swift`, `FeedView.swift` (call-site), rewritten `ClipHROverlayTests.swift`
- Docs: knowledge-graph node/edges, `decisions.md` entry, this prompt.

## Acceptance criteria

- [ ] Trim a clip in "Edit this clip" → back in the feed: playback loops the kept range, the poster is
      the first kept frame, the EDITED chip names the range, the HR chart's footage span is the kept
      range — no manual refresh.
- [ ] A never-edited clip shows the default extended window (lead 0:05 / tail 0:30, Full-window
      scope) — same chart the Studio would show for it.
- [ ] Scope + saved-tile style flow to the feed; placement stays the feed's uniform strip.
- [ ] Split clips → envelope; removed-from-project → raw; degenerate trim → raw.
- [ ] Fullscreen transport: scrubber spans the kept range, parks at kept end, HR dot follows.
- [ ] The Recap viewer and grid (no `edit` stamped) render with defaults — unchanged trims.
- [ ] App type-checks (Swift 6, 0 warnings); pure logic unit-tested without a device.
- [ ] `decisions.md` updated.

## Constraints

- No `AVComposition`/compositor in feed cells (carousel perf, prompt 97/106) — that's the bake lane.
- `HighlightEngine` untouched.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — `ClipStudioEditTests` + rewritten
   `ClipHROverlayTests` + full suite.
2. `SnappetUITests/ClipsFeedUITests` (feed UI changed).
3. Device leg (MrRobot): trim + tail a real clip in the scoped Studio, return to the feed — verify
   trimmed loop, poster, chip, chart panes; fullscreen scrub across the kept range.
