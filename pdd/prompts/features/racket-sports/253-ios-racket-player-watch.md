# Prompt: Racket player, Watch mode — a video-first player with Photos' viewer and YouTube's gestures (prompt 253)

**File**: pdd/prompts/features/racket-sports/253-ios-racket-player-watch.md
**Created**: 2026-11-14
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#448](https://github.com/harshal2802/snappet-mobile/issues/448) part 1, the "Watch" checklist
only (first of three jobs: Watch → Edit + Share → camera). Stacked on #447 (prompt 252). Follows prompts 246 and 251.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Boards (source of truth)**: `racket-wireframes/boards2/` — Main, PlayerChrome, PlayerPaused, PlayerScrub, PlayerSkip,
PlayerHold, PlayerSpeed, PlayerModes, PlayerZoom, PlayerNoRallies, PlayerOpening, PlayerMissing, PlayerEnd,
PlayerLetterbox, PlayerLandscape, PlayerLandscapeChrome (canvas https://claude.ai/artifact/HkLJn1ATbhuZH2cNHsZd3d).

## Goal

Playing a racket video should feel like Apple Photos' video viewer: the video and nothing else, with a score pill and a
thin progress line showing the rallies. A tap brings the controls (back, title, Share, Edit; a filmstrip of real frames
with rally bands under a fixed centre playhead; play/pause; mute; previous / next rally; speed), and YouTube's gestures
do the rest: double-tap a side to skip 10 s, hold for 2×, pinch to zoom. Today's player (prompt 246) is a scrolling form
with a small video, which the user found hard to watch.

## User decisions this prompt follows

- Wireframes are the source of truth; explicit user decisions override a board. Capability labels tell the truth.
- A tap on the player always toggles the controls (#448 "Decisions already made").
- Rally finding is vision only and the shipped finder is still the placeholder; no BlurBall weights; no audio.
- Edit mode, Looks and the new Share sheet are the next job (prompt 254). Here Edit and Share exist and keep everything
  that works today: Share opens today's "Save or share"; Edit opens today's rally / tag / fix / score surfaces.

## Approach

- **Pure logic** (`Features/WorkoutTracker/RacketPlayerWatch.swift`, Foundation + CoreGraphics only):
  `RacketPlayerText` (clock "08:14 / 18:32", "6.2 s", "7 – 5", speeds, "2.4×", "+10 s"), `RacketPlayerRallies`
  (running score from your tags, rally at / last before the playhead, previous / next rally, loop target),
  `RacketPlayerCopy` (top bar subtitle, landscape title, label line, scrub readout, end line from the logged score, mode
  labels), `RacketPlayerChrome` (hide after 3 s idle only while playing, never while dragging or with the menu open),
  `RacketPlayerTaps` (single tap toggles at once; a second tap within 0.3 s undoes it and skips 10 s on that side;
  further taps within 0.7 s add 10 s each), `RacketPlayerHold`, `RacketPlayerSpeed`, `RacketPlayerLoop`,
  `RacketPlayerZoom` (1×–5×, pan clamped to the video), `RacketPlayerFit` (aspect fit, the turn hint),
  `RacketFilmstrip` (offset ↔ time under a centre playhead, about a minute across the strip, zero seek tolerance while
  the finger is slow), `RacketPlayerBand` (won accent, lost grey, untagged dashed).
- **Playback** (`Services/RacketVideoLibrary.swift`): `RacketPlayback` gains `loop`, `muted`, `ended`, `videoSize`,
  `poster` (Photos' own still, network off, so an iCloud-only video shows a frame at once); the library gains
  `poster(_:at:)` and `uprightSize(_:)`. Scrubbing keeps the existing one-seek-in-flight coalescing.
- **Screen** (`RacketWatchPlayerViews.swift`): `RacketWatchPlayerScreen` full screen (nav bar, status bar and home
  indicator hidden), video aspect-fit, UIKit gesture surface (`RacketPlayerGestureSurface`: tap, long press, pinch,
  pan-while-zoomed), the chrome as boards, a custom speed menu over the speed button, PlayerMissing / Opening / End /
  NoRallies / Letterbox / Landscape states. Every control a Button with a label and a `racket.player.*` identifier,
  44 pt targets; the video surface carries VoiceOver actions (show/hide controls, skip back / forward 10 s, reset zoom),
  the strip is adjustable (±10 s).
- **Wiring** (`RacketVideoViews.swift`): `.player` and `.missing` routes open the new screen (it shows PlayerMissing
  itself; the old TtOriginalMissing page is removed); "Game 2" replaces the route with the next part; Find rallies runs
  the sport's model (Analyzing); Mark by hand opens the part's timeline. Edit is a menu: Rallies and tags (timeline:
  mark, tag, Fix, Shots, add a missed rally), Edit score (a match game), Analysis view (the old player renamed
  `RacketAnalyzedPlayerScreen`: tags over video, AI suggestions, Compare), and Compare <app> suggestions when a reply
  waits. The `.analyzed` route (AI compare, longest rally) keeps the analysis view.
- **Seed** (`RacketVideoSeed`): `-uiTestRacketPlayer portrait|landscape|missing|opening` — game 1 (5:00, 21 rallies,
  rally 13 untagged, 7 – 5 after rally 12) and game 2 (1:00, no rallies) over two synthetic bundled clips (a drawn
  table and ball made with ffmpeg; no real footage), a missing original, or a held iCloud download.

## Acceptance criteria

- [ ] Main: only the video, the score pill and the progress line with rally segments.
- [ ] A tap toggles the controls at once; they hide after about 3 s while playing and stay while paused.
- [ ] Dragging the filmstrip scrubs with frames following; other controls hide; the readout shows time and rally.
- [ ] Double-tap left / right skips −10 / +10 s with the ripple and leaves the controls as they were.
- [ ] Hold plays at 2× with "2× · release for normal speed" and restores the speed (and pause) on release.
- [ ] Pinch zooms to 5× with "2.4×" and Reset; drag pans only while zoomed, clamped to the video.
- [ ] Speed menu 0.25× … 2×, Loop this rally, Rallies only; mode labels when the controls are hidden.
- [ ] States: no rallies (Find rallies, Mark by hand), opening (first frame + iCloud %), original missing (stats kept),
      end (Replay, next game), letterboxed sideways video with the turn hint, landscape with and without controls.
- [ ] Pure logic unit-tested in `RacketPlayerWatchTests`; UI test `RacketPlayerUITests`; existing UI tests updated.
- [ ] `decisions.md`, `project.md` and `docs/knowledge-graph/data.js` updated.

## Constraints

- HighlightEngine untouched. No audio analysis. No BlurBall weights. No real footage committed.
- Model unchanged (no new persisted fields).

## Test plan

1. `SnappetTests` serial on the simulator (`-parallel-testing-enabled NO`).
2. `RacketPlayerUITests`, `RacketVideosUITests`, `RacketTaggingUITests`, `RacketAIUITests` one at a time, the app
   uninstalled before each.
3. The board walk (`testBoardWalk`, `testBoardWalkLandscape`, `testBoardWalkStates`) with the host script that turns
   `RACKETSHOT:` log lines into simulator screenshots; compare each against its board PNG.
4. Device walk by the user (not run here): real Photos video, iCloud download, haptics, rotation, VoiceOver.
