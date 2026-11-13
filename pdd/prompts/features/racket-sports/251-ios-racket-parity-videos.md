# Prompt: Racket parity — tagging, videos and player (tag with video, rules, fix, shots, LiveTag, EditScore, SplitPhotos) (prompt 251)

**File**: pdd/prompts/features/racket-sports/251-ios-racket-parity-videos.md
**Created**: 2026-11-12
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#438](https://github.com/harshal2802/snappet-mobile/issues/438) → wireframe parity audit
(`racket-wireframes/audit/fixlist.md`) batches **V1** (tagging and fix with video), **V2** (videos, player, edit score) and
**M** (model screens), plus the declared deferrals on these screens the user now wants built: shot-by-shot tagging by hand
(Shots / ShotTags, DoublesShots), SplitPhotos (add a video from Photos and find games / drills in it), game-by-game clips
in Your videos / Keep rallies, LiveTag / QuickTag from the recording screen (by hand, no model), Summary's full board
layout, and the "Not available yet" placeholders on Summary, Timeline, Player Analyzed, the tag sheets, AnalysisSettings
and Capabilities' "Preview a sport with no model". Follows prompts 203, 244–250.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Boards (source of truth, all six sports)**: Videos / FindRallies, NoModelVideos, DrillVideos, Summary, ManualSummary,
Timeline, NoModelTimeline, Tag / QuickTag, NoModelTag, DoublesTag, LiveTag, Shots / ShotTags, DoublesShots, Fix /
FixRally, Rules / RallyRules, TagDone, EditScore, PlayerOriginal, PlayerAnalyzed, PlayerExport, SplitPrompt,
SplitReview, SplitEdit, SplitAssign, SplitPhotos, SplitDone, DeleteOriginal, KeepRallies, OriginalMissing, Analyzing,
AnalysisSettings, ChooseModel, ModelCompare, Capabilities, AISend / AIPrompt / AIImport / AICompare (re-check).

## Goal

The user tagged rallies blind twice on the phone: the tag sheet and Fix rally had no video. Every tagging screen now shows
the rally's own video, and the rest of the tagging, videos and player boards match: the rules sheet, Fix's "What went
wrong?", "+ Add a missed rally", every shot by hand, LiveTag from the recording screen, EditScore's "Which game",
SplitPhotos, game-by-game clips in Your videos, the Summary board, the Analyzing ring and "Sent to ChatGPT".

## User decisions this prompt follows (2026-11-11 / 12)

- **Capabilities and every screen show the truth.** Only Find rallies and the drills' longest rally exist, as
  "Placeholder". Court check, live tracking, shot count, shot types, endings and ball path are "Not available yet". Where a
  board shows one, its element stays in place with a clear "Not available yet" state — no fake data, no missing element —
  and offers the by-hand route where the board has one.
- **Recording screens open on Camera.**
- Keep the split screens' user additions: video at the top, the coloured timeline, a per-row Fix.

## Approach

- **Pure** `RacketTagFlow.swift`: rules per sport (copied from the boards), `RacketFixReason`, `RacketShot` /
  `RacketShotType` / `RacketShotTagging`, `RacketTagScore` (So far, serve line), `RacketLiveTag` (the last rally = since the
  last score tap / tag / game start, 2–20 s), `RacketMissedRally`, `RacketClipAdoption` (per-game clips → a game-by-game
  log), `RacketPhotosImport` (SplitPhotos), `RacketAIWaiting`. `RacketClock.ring` (Block / Paused zero-padded).
- **Model (additive Optionals)**: `RacketRally.fixReasonsRaw`, `RacketRally.shots`.
- **Screens** `RacketTagViews.swift`: `RacketRallyVideo` (own `RacketPlayback` over the part, loops the rally ±1 s),
  `RacketTagSheet` (QuickTag / NoModelTag / DoublesTag layouts), `RacketRulesSheet`, `RacketFixRallySheet` (video whose
  frame follows the dragged handle; add mode), `RacketShotsScreen`, `RacketLiveTagPanel`, `RacketEditScoreSheet`.
- **Wiring**: Timeline (+ Add a missed rally, Shots per row, shot-count placeholder), Your videos (EditScore, Add from
  Photos → SplitPhotos, Sent to ChatGPT, adopt game clips, `.shots` start for the drill review), Summary (board layout,
  Tag every shot → Shots), Analyzing ring, AnalysisSettings disabled switch, Player Analyzed placeholders, SplitPrompt
  video, both recording covers (Tag last rally → LiveTag with the camera on top), drill Review "Tag shot types".
- **Small**: Block / Paused rings "01:48"; Drill details' court shows From and To cells as the board does.

## Acceptance criteria

- [x] Tag / NoModelTag / DoublesTag: the rally's video loops at the top; board titles ("Unsure 2 of 4", "Your rally 3 of 5",
      "Rally 12 of 21"); So far · Final (TT / Bd / Sq), the doubles serve line; Not a rally | Next; What counts as a rally?
- [x] Rules per sport (Close returns to the tag sheet).
- [x] Fix rally N: video, strip (frame follows the handle), Split in two | Merge with next, Not a rally, What went wrong?
- [x] Timeline: + Add a missed rally (Fix in add mode); rows show shots you tagged.
- [x] Shots / DoublesShots by hand; Summary "Tag every shot" and Review "Tag shot types" open it; Save → timeline.
- [x] LiveTag on game-by-game and record-everything screens (camera on top), saved as a tagged rally.
- [x] Summary board layout with placeholders; EditScore; Analyzing ring; Sent to ChatGPT; AnalysisSettings switch.
- [x] SplitPhotos: Add from Photos → Add a video → Find games and drills / Add as one video / Pick a different session.
- [x] Game-by-game clips (per-set media) list in Your videos and Keep rallies.
- [x] Pure logic in `RacketTagFlowTests`; UI in `RacketTaggingUITests` (+ LiveTag steps in the match / recording suites).
- [x] Device: a 1:00 clip recorded on the phone. The split prompt, split review, Fix one part, timeline, tag sheet,
      Fix rally, Shots and player show video that scrubs (`racket-wireframes/shots/videos/device/walk5-*.png`). This
      includes the fix for paused players that opened black on the camera's empty first 0.7 s.

## Constraints

- On-device only. `HighlightEngine` untouched. Model fields additive optionals only. No model, no fake numbers.
- Out of scope (last batch): PbScoring / PbSideOut, TnNoAd / TnServe, PdWall, SqLet (the tag sheets' "Serve details",
  "Did it bounce first?", "Let, stroke or no let" links).

## Test plan

1. `cd ios/App && xcodegen generate`; build Snappet and SnappetWatch.
2. `SnappetTests` alone, serial; every racket UI suite separately; `cd ios/HighlightEngine && swift test`.
3. Device build + install; record a short clip, then split review → Fix one part → timeline → tag sheet → Fix rally →
   player, with device screenshots.
