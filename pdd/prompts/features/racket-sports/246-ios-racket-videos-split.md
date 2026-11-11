# Prompt: Racket videos, player, manual tagging and split (prompt 246)

**File**: pdd/prompts/features/racket-sports/246-ios-racket-videos-split.md
**Created**: 2026-11-07
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#438](https://github.com/harshal2802/snappet-mobile/issues/438) → step 3 of 6 ("Videos, player, manual
tagging and split"); builds on prompt 244 (step 1, recording core) and prompt 245 (step 2, Watch scoring)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframes (user-approved, five review rounds — the source of truth)**: canvas A / B linked from #438. Boards for this
step: `TtSplitPrompt`, `TtSplitReview`, `TtSplitEdit`, `TtSplitAssign`, `TtSplitDone`, `TtDeleteOriginal`, `TtKeepRallies`,
`TtOriginalMissing`, `TtSessionRecap`, `FindRallies` / `TtNoModelVideos` (Your videos), `TtDrillVideos`, `TtPlayerOriginal`,
`TtPlayerAnalyzed`, `TtPlayerExport`, `TtNoModelTimeline`, `Timeline`, `FixRally`, `TtNoModelTag` / `XxNoModelTag`,
`DoublesTag`, `TtTagDone`, `TtManualSummary`, `TtEditScore`. Fifth-review lows handled here: KeepRallies counts drill rallies,
TagDone / NoModelTag buttons wired, NoModelVideos is the real (not preview) state while no model exists.

## Goal

A whole match recorded with "Everything, split later" is one long Photos recording (in 10-minute parts). Step 3 turns it
into useful video: split it into games, breaks and so on **without changing the original**, link each part to its
game, play any part, mark and tag rallies by hand, see "From your tags", and free space by deleting the long original
(confirmed) or keeping only the rallies. A drill recorded with everything gets its block parts from the timers.

Settled (#438, do not reopen): recordings live in Photos; split is non-destructive (parts are time ranges on the
original; new Photos videos only when the user deletes the original, and that delete is confirmed); every sport shows
the by-hand path when a feature isn't available; manual tags appear in "From your tags" and count in history; a drill
never offers to delete its original; "Score unconfirmed" and "from Watch" stay one consistent state (review5 M5).
No ML: rally finding is step 5, so this builds the manual path and a seam (`RacketRallyFinding`) the model fills.

## Context the implementer needs

- `RacketRecordingLog` (prompt 244) holds runs, Photos parts (`assets`, start + duration on the recording timeline) and
  marks (block / rest / moment / newGame / breakStart). The Watch (prompt 245) logs a finished game "from Watch" with
  `completedAt` and adds a New game mark.
- The record-everything cover ended at a "Recording saved" placeholder with a per-game Enter score / Later step.
- `SessionRecapCards` / `RacketRecapCards` render in the Finish summary and the session detail (the detail hosts
  sheets outside its lazy list: `onOpenGame`).

## Approach

- **Pure** `RacketVideoSplit.swift`: `RacketVideoPart` / `RacketSplit` / `RacketDerivedVideo`; `RacketSplitProposal` (from
  New game / Break starts / a new `firstPoint` mark the Watch bridge adds on a game's first point; warmup / break when
  no point for 90 s; a break to the end is "Not play"; games beyond the format are unsure); `RacketSplitEditor` (tiling
  ranges: set bounds with neighbours, split, merge, kind, belongs, validate); `RacketSplitAssign` (Watch games by time,
  others in order, missing ones logged "Score unconfirmed"); `RacketVideoMap` (recording range → Photos segments across
  parts and gaps, or the derived videos once the original is gone); `RacketOriginalCheck`; `RacketVideoSpace` /
  `RacketKeepRallies` (numbers; drills included); `RacketVideoRows`; `RacketRallyFinding` (seam: `.notYet`);
  `RacketScoreEdit`.
- **Pure** `RacketRallyTags.swift`: `RacketRally`, `RacketRallyEnding` (per-sport lists from the boards), marking / fix /
  tag / next untagged, `RacketTagSummary`, `RacketPlaybackPolicy` (rallies only, overlay line, running score),
  `RacketTagTotals` (history).
- **Edge** `Services/RacketVideoLibrary.swift`: compositions over Photos parts (gaps kept), export (captions burned on a
  device for Analyzed), save to Photos, delete (iOS confirms), availability, iCloud download; `RacketPlayback` (AVPlayer
  or a virtual clock when no video was saved).
- **Screens** `RacketVideoViews.swift` (one stack: split prompt → review → edit sheet → assign → done; Your videos; drill
  videos; TagDone; From your tags; Original missing; Delete original; Keep rallies) and `RacketPlayerViews.swift` (player
  Original / Analyzed, export, timeline with Mark start / end, FixRally, tag sheet with doubles' last shot).
- **Wiring**: the recording cover shows the split flow when a whole match ends; the match / drill page gets "Your
  videos"; the recap card gets per-entity video lines, "Keep rallies only…" and "Your videos" (host-presented in the
  session detail); `ActivityDashboard` gets tag KPIs. Seed `-uiTestSeedRacketVideos`.
- **Model (additive Optionals on `RacketRecordingLog`)**: `baseSetIndex`, `qualityRaw`, `split`, `keptAsOne`, `rallies`,
  `derived`, `originalDeleted`; mark kind `firstPoint`.

## Output

- New: `RacketVideoSplit.swift`, `RacketRallyTags.swift`, `RacketVideoViews.swift`, `RacketPlayerViews.swift`,
  `RacketVideoSeed.swift`, `Services/RacketVideoLibrary.swift`, `SnappetTests/RacketVideoSplitTests.swift`,
  `SnappetTests/RacketRallyTagsTests.swift`, `SnappetUITests/RacketVideosUITests.swift`.
- Changed: `RacketRecording.swift`, `RacketRecordingViews.swift` (split flow replaces the placeholder + scores step),
  `RacketWatchBridge.swift` (firstPoint), `FreeformPlayerView.swift` (Your videos, log merge), `RacketViews.swift` (recap),
  `SessionRecap.swift`, `SessionDetailView.swift`, `ActivityDashboard.swift`, `SnappetApp.swift` (seed),
  `RacketWatchTests.swift`, `RacketRecordingUITests.swift`.
- Docs: `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [x] Stop and split → SplitPrompt ("1:14:10 recorded", "Looks like 3 games and one more stretch…") → Review the split
      (parts with Matched / Not counted / Unsure) → Fix one part (edges, kind, belongs, split here, merge) → Apply →
      Match to your games ("Game 3 has video but no score" → Enter the score) → Split saved (N parts, no extra space).
- [x] Later / Keep as one video log the proposed games "Score unconfirmed" (step 1's state) and open Your videos.
- [x] Delete the long original: parts saved to Photos first, then the original deleted (confirmed by Snappet and iOS);
      playback then uses the new videos. Drills never offer it.
- [x] Keep rallies only: every marked rally across the session's matches and drills saved first, then the full videos.
- [x] Original missing: Download from iCloud / Find it in Photos / Keep tags and stats only.
- [x] Your videos says rally finding isn't available yet and offers Play / Mark rallies / See your tags / Edit score.
- [x] Player: a part plays from the original at its range (across parts); −10 s / +10 s, rallies only, 0.5×; Analyzed
      overlays your tags; Save or share a rally / rallies only / the whole part.
- [x] Manual tagging: Mark start / end, tag (winner, ending per sport, doubles last shot, Not a rally, Skip, Close),
      TagDone (wired "Tag winners for the rest"), From your tags; tags count in history (dashboard KPIs, recap line).
- [x] Pure logic tested (`RacketVideoSplitTests`, `RacketRallyTagsTests`); UI: `RacketVideosUITests`, updated
      `RacketRecordingUITests`. No platform imports in `HighlightEngine`.
- [ ] Device legs (owed): see Test plan.

## Where this differs from the boards (no user decision overrode them; recorded in decisions.md)

- The split proposal uses marks and Watch first points only ("rally activity" needs the model), so the review copy
  says so; the boards' Watch-tap / rally-activity line is shortened accordingly.
- SplitDone's "Find rallies in all" and Your videos' "Find rallies" / "Re-scan" / "Another AI app" aren't shown: no model
  yet (step 5) and the AI round trip is step 4. Your videos is the NoModelVideos board (no "Preview" label: it's the
  real state).
- TagDone reads "Snappet's guesses: None, no model yet" and "Left to tag" instead of "Unsure left".
- Shot-by-shot tagging (`ShotTags`, `DoublesShots`) and "Add from Photos" (`SplitPhotos`) are not built (follow-ups).
- Keep rallies only works on record-everything recordings; game-by-game clips (prompt 203) aren't listed in Your videos yet.
- Space numbers use the recording's quality at HEVC 30 fps (board: 8.6 GB for 1 h 3 min is a 4K figure).

## Device feedback round 1 (2026-11-11, user testing on an iPhone)

**Problem.** "Split recording" showed a flat bar and a list with no video, so a part couldn't be checked by eye.
**Changes** (decisions.md, "Racket device feedback round 1"; pure pieces in `RacketVideoScrub.swift`, tested in
`RacketVideoScrubTests`):

- [x] **Review:** the original plays at the top (one `RacketPlayback` over step 3's composition across the 10-minute
      Photos parts). The bar is a segmented timeline (`RacketSplitTimeline`: one segment per part, game accent,
      warmup / break / rest / not play / practice grey, unsure amber) with a playhead; a tap plays that part to its end
      (from its first moment with video), a drag scrubs. A row tap plays its part (outlined while playing); **Fix**
      opens TtSplitEdit.
- [x] **Fix one part:** the review's player at the top; dragging the start / end handle scrubs the video to that edge
      (one seek in flight, ~1 pt tolerance, exact on release); a film strip of frames sits behind the range (outside
      shaded); dragging the strip moves the playhead; Play / Pause; **Split here** cuts at the playhead (disabled, with
      why, until ≥ 5 s inside); the range is the title, as on the board.
- [x] **iCloud-only / missing originals:** "Downloading from iCloud… N %" with progress, Try again on failure, black
      stretches for missing parts ("1 part of the original isn't on this phone"), and "You can still split it by time"
      when none are there. Applies to every racket player.
- Differences from the boards: rows play (board: rows open the edit) — editing is the per-row Fix button; the review
  note adds "Tap a part to watch it, Fix to change it."; the playhead clock / Play row under the bar is new.
- [ ] Device: split a > 20 min recording (two Photos parts), tap game 2 (starts in part 2), drag a handle and watch the
      frame follow, Split here mid-rally; offload a part to iCloud and open the review.

## Test plan

1. `cd ios/App && xcodegen generate`; build `Snappet` and `SnappetWatch`.
2. `xcodebuild test … -only-testing:SnappetTests -parallel-testing-enabled NO` on iPhone 17 Pro; the UI bundle separately.
3. `cd ios/HighlightEngine && swift test` (untouched).
4. Device: record a match everything for > 20 minutes with New game marks (and Watch scoring), split it, play game 2
   (spans two Photos parts), mark and tag 3 rallies, export one rally (Analyzed), Delete the long original (iOS dialog),
   play again from the new part videos; Keep rallies only on a session with a drill; offload a part to iCloud and open it.
