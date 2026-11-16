# Prompt: Racket player, Edit mode and Share — Photos' video Edit mode over the racket timeline (prompt 254)

**File**: pdd/prompts/features/racket-sports/254-ios-racket-player-edit.md
**Created**: 2026-11-14
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#448](https://github.com/harshal2802/snappet-mobile/issues/448) part 1, the "Edit" and "Share"
checklists (second of three jobs: Watch → Edit + Share → camera). Stacked on #449 (prompt 253).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Boards (source of truth)**: `racket-wireframes/boards2/` — EditRallies, EditSelected, EditTrim, EditMarking, EditShots,
EditSport, EditLooks, EditScore, EditEmpty, EditFinding, EditDiscard, EditList, ShareSheet, ShareExport.

## Goal

Edit a game's rallies the way Photos edits a video: the video on top, a filmstrip under a fixed centre playhead, and tabs
Rallies / Looks / Score, with Cancel / Undo / Redo / Done. Select a rally to trim, tag, split, merge or drop it; mark a
missed one while it plays; find rallies without leaving; pick a look for playback; fix the game's score. Share makes a new
copy of this rally, the rallies only or the whole game, with the look, score and rally labels and the speed.

## User decisions this prompt follows

- Wireframes are the source of truth; capability labels tell the truth; rally finding is vision only and the shipped
  finder is the placeholder (the UI says so); no BlurBall weights; no audio.
- Looks are presets, playback and shared copies only; the video in Photos stays as filmed; rally finding reads the original.
- Model fields are additive optionals. Existing tag rules and reason lists are reused, never re-invented.

## Approach

- **Pure** (`RacketEditSession.swift`): `RacketEditSession` (working copy of the part's rallies, look and edited scores;
  Undo / Redo of every edit; one Undo step per drag; change count and "You changed 3 rallies"); trim limits (part,
  neighbouring rally, 0.5 s minimum); `RacketEditMark` (+ Rally clamp-or-refuse); split at the playhead, merge next, not a
  rally, tags through `RacketRallyMarking.tag`; `mergeFound` (found rallies replace only unconfirmed guesses and never
  overlap); `RacketEditRuler` / `RacketEditZoom`; `RacketEditList`; `RacketLook` / `RacketLookScope` / `RacketLookStore`;
  `RacketSharePlan` (ranges, length after speed, size estimate, labels on the copy's clock).
- **Model (additive)**: `RacketRecordingLog.lookRaw`, `partLooks`; `RacketShot.atSec`. "Always" in UserDefaults.
- **Services**: `RacketLookRenderer` (CIColorControls + CITemperatureAndTint through an `AVVideoComposition` CI handler,
  labels via CITextImageGenerator); `RacketPlayback.look` / `showOriginal`; `RacketVideoLibrary.export(… look:speed:labels:
  progress:)` with cancellation and progress.
- **Screens**: `RacketEditViews.swift` (Edit over the Watch player, same playback), `RacketShareViews.swift`. The tag
  sheet's score / serve lines move into `RacketTagLines` so the inspector and the sheet share them.

## Acceptance criteria

- [ ] Every board state reachable on the simulator fixture and checked against its PNG.
- [ ] Done writes rallies, look and scores; Cancel with changes asks (EditDiscard) and leaves nothing changed.
- [ ] Unit tests for the working copy, trim, mark, merge, found rallies, list, looks, share plan.
- [ ] UI suite `RacketEditUITests`; existing player suites updated.
- [ ] `decisions.md`, `project.md`, `docs/knowledge-graph/data.js` updated.

## Test plan

1. `SnappetTests` serial. 2. `RacketEditUITests`, `RacketPlayerUITests`, `RacketVideosUITests`, `RacketTaggingUITests`,
`RacketAIUITests`, one at a time, app uninstalled first. 3. Board walk screenshots to `shots/player-edit/`.
4. Device walk by the user: looks on real footage, share re-encoding with look / labels / speed, haptics, VoiceOver.
