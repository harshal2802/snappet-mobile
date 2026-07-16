# Prompt: Reel editor redesign — the reel becomes the screen (+ per-clip trim)

**File**: pdd/prompts/features/reel-editor-redesign/01-reel-editor-redesign.md
**Created**: 2026-07-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follows the highlights convergence (P1–P5); redesigns the shared builder those
prompts converged on.
**Source**: user feedback 2026-07-15 — "this reel preview seems very less useful and less
intuitive… take inspiration from popular apps like Edits by Meta", plus "give user option to
adjust individual clips timelines".
**Wireframes**: `docs/ux-research/reel-editor-redesign/wireframes.html` (3 screens, approved)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

`ReelView`'s ready state is a settings-page-shaped `List`: a "Preview reel" button where the
video should be, three stacked control sections with instructional footers, and clip rows
labelled with raw stitched-timeline offsets ("52:33") and a meaningless "intensity 13%".
Rebuild the presentation in the grammar of Edits/CapCut — **the reel IS the screen**: an
auto-built looping preview fills it, Export is the one prominent action, tools compress to a
single chip row, the highlight list becomes a filmstrip timeline, and a tapped clip opens a
sheet with a **real per-clip trimmer** (new capability). Same ViewModel, same engine pipeline;
the recovery states and the export payoff screen are untouched.

## Context the implementer needs

- The engine anticipated trimming: `Highlight.clipStartWithin(_:)/clipEndWithin(_:)` are
  documented "what a trimmer needs", and `ReelPlanner.plan` derives segments straight from
  `clipStart`/`clipEnd` — so a trim is just rebuilding `Highlight` values with an adjusted
  window before planning. **The engine is not modified.**
- The preview composition (`ReelExporter.makeComposition`) is cheap (no export/re-encode) —
  auto-building it on `.ready` and after every edit is affordable. The burned HR overlay maps
  the WHOLE session series linearly across the composition (`HROverlayValues(samples:,
  durationSec: composition.duration)` → `.feedClipScorebug`), so a SwiftUI `HRTileView`
  overlaid on the preview with `fraction = time/total` is a faithful WYSIWYG of the burn —
  the CA tool itself can't render in an in-app player (the old footer's caveat).
- `ClipPlaybackController` (prompt 94) is player-agnostic: attach the preview `AVPlayer` for
  play/pause + observed time + seek. Composition timing for the filmstrip↔time map mirrors
  `makeComposition`'s cursor: photos advance `photoStill`, videos their segment duration,
  videos ≤ 0.1 s are dropped (`renderable`); unreadable-asset skips can drift the map — it's
  cosmetic (current-frame ring, play-from-here), so best-effort is correct.
- No XCUITest enters ReelView (only `generateHighlight`'s existence on the session detail is
  asserted), so the redesign can't break the suites; keep the existing accessibility ids
  (`reelFormat.*`, `reelOverlayToggle`, `reelRegenerate`) and add ids for the new chrome.
- `ReelView` is pushed/sheeted inside a `NavigationStack` from three hosts (gym detail sheet,
  Kilter detail, `WeeklyReelHostView`) — keep system navigation (inline title + toolbar), not
  a custom top bar.

## Approach

**Pure layer** (`Features/Reel/ReelTrim.swift`, unit-tested, no AVFoundation):
- `ReelTrim.bounds(for:media:)` — the trim's allowed window = the source video's full span on
  the workout timeline (`nil` for photos: not trimmable); `clamp(_:bounds:minLength: 1s)`;
  `apply(_:to:)` — rebuild `Highlight`s with trimmed windows (`atOffset` clamped inside).
- `ReelTimelineMap` — segment start offsets + `segmentIndex(at:)` mirroring the composition
  cursor, for the filmstrip's current-frame ring and "Play from here".

**ViewModel** (`ReelViewModel`):
- `trims: [String: ClosedRange<Double>]` + `setTrim`/`resetTrim`/`isTrimmed`/`trimBounds`;
  `plannedHighlights = ReelTrim.apply(trims, to: keptHighlights)` feeds BOTH `buildPreview`
  and `export` (what you drag is what ships); `generate()` clears trims; `peakBpm(for:)`
  reads the effective (trimmed) window so the badge stays honest.
- Auto-preview: `previewEpoch` bumps on every invalidation; the view's `.task(id:)` rebuilds.
  Keep the last `ReelPlan` for duration/timeline mapping.

**View** (`ReelView` ready state only):
- Toolbar: principal = title + "N clips · m:ss"; trailing = prominent **Export** capsule.
- Canvas: the preview player fills the free height (tap = play/pause via
  `ClipPlaybackController`), with a time chip, a thin scrubber, and — when the HR chip is on —
  the live `HRTileView` scorebug (the burn, previewed).
- One tool row: format chips · HR chip · (limited-access pick) · ↻ regenerate (confirm gate
  unchanged) · ☰ edit list.
- Filmstrip: horizontal thumbnails (duration badge, peak-tint bar, pin marker, current-frame
  ring); tap → **clip sheet**: "Clip n of N · ks · kind", PEAK pill, the trim handles
  (drag = `setTrim`, live duration label, Reset trim), Play from here, Pin, Remove.
  A "+N removed" ghost tile opens the edit list.
- Edit list becomes a sheet (drag-reorder, pin/remove/restore swipes, shortfall note — the old
  List, re-skinned with "Clip n · ks · kind" + PEAK rows; offsets/intensity% copy deleted).

## Output

- `ios/App/Snappet/Features/Reel/ReelTrim.swift` (pure) + `ReelTrimTests.swift`.
- `ReelViewModel.swift`: trims + plannedHighlights + auto-preview epoch + last plan.
- `ReelView.swift`: the new editor (canvas/tool row/filmstrip/clip sheet/edit sheet);
  recovery + exporting + exported states untouched.
- Wireframes committed under `docs/ux-research/reel-editor-redesign/`.
- `decisions.md` entry + knowledge-graph updates in the same change.

## Acceptance criteria

- [ ] Opening a reel auto-builds and loops the preview — no "Preview reel" button; scrubbing
      works; play/pause on tap; the time chip reads m:ss / m:ss.
- [ ] Export is the single prominent top-right action; ↻ keeps its confirm-when-curated gate.
- [ ] HR chip ON shows the glass scorebug live on the preview (the same tile the export
      burns); OFF hides it and the export skips the burn (unchanged).
- [ ] Filmstrip mirrors the kept cut (order, durations, pins); tapping a frame opens the clip
      sheet; trim handles adjust that clip's window (≥1 s, clamped to its source video), the
      preview rebuilds with the trim, and the export ships it; Reset trim restores the
      auto-cut; photos aren't trimmable.
- [ ] No raw stitched-timeline offsets or "intensity %" anywhere; clips read "Clip n · ks".
- [ ] Pin / remove / restore / reorder / pick-shortfall note all still work (edit-list sheet).
- [ ] Recovery states (empty/denied/limited/error/exportFailed) and the exported payoff render
      exactly as before.
- [ ] `HighlightEngine` untouched; unit suite green (`ReelTrimTests` included).
- [ ] `decisions.md` + knowledge graph updated in the same change.

## Constraints

- On-device only; engine platform-free and UNCHANGED (trims are app-side `Highlight` rebuilds).
- Same ViewModel/pipeline: no new stores; trims are per-cut state (cleared by regenerate),
  deliberately NOT persisted.
- Honest verification: preview playback/export need a device (sim has no H.264 encoder;
  preview compositions of real Photos assets are device-only) — sim verifies build + layout.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — `ReelTrimTests` + full unit suite.
2. `make ios-sim SIMULATOR='iPhone 17 Pro'`; then the affected XCUITest suites
   (`ClipsFeedUITests`, `LiveWorkoutStudioWalkthroughTests`) — wedged-sim recovery:
   `xcrun simctl shutdown all`.
3. **Device leg (MrRobot, unlocked; verify install via `devicectl device info apps`)**: open a
   session reel + the weekly reel → preview auto-plays; trim a clip → preview reflects it →
   export ships it; HR chip toggles the live scorebug; export → payoff unchanged.
