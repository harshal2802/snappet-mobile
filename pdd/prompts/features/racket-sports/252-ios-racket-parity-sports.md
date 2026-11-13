# Prompt: Racket parity — the sport-specific boards (pickleball side-out, tennis no-ad and serves, padel wall, squash let, doubles servers) (prompt 252)

**File**: pdd/prompts/features/racket-sports/252-ios-racket-parity-sports.md
**Created**: 2026-11-13
**Project type**: Native iOS + watchOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#438](https://github.com/harshal2802/snappet-mobile/issues/438) → wireframe parity audit
(`racket-wireframes/audit/fixlist.md`, `matrix.md`), the last parity batch. Prompts 249–251 declared these boards "the
last batch": PbScoring / PbSideOut (pickleball side-out scoring), tennis No-ad, TnServe, PdWall, SqLet (the tag sheets'
"Serve details", "Did it bounce first?", "Let, stroke or no let" links), PbTag's "4–2–1 · Mia serving next", the
DoublesTag serve lines naming the player ("Mia serving", "Mia serving, right court", "Mia, server 2"), and the remaining
Low items. Follows prompts 203, 244–251.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Boards (source of truth)**: PbScoring, PbMatch, PbSideOut, PbDim / PbDimOff, PbStatsOff, PbScoreOnly, PbWatch,
PbWatchMark, PbTag, PbDoublesTag, PbRules; TnMatch, TnWatch, TnTag, TnDoublesTag, TnServe; PdTag, PdDoublesTag, PdWall;
SqTag, SqDoublesTag, SqLet; BdDoublesTag, DoublesTag; TtPlayerOriginal, TtSessionRecap (Low items).
Arrows (`generator/flows.py` EXTRA): Pb SessionHub → Scoring → Match, Dim → SideOut ("Serving side loses") → Dim ("Next
rally"); Tn Tag → Serve ("Serve details") → Tag ("Next point"); Pd Tag → Wall → Tag ("Back or next"); Sq Tag → Let → Tag.

## Goal

Every sport plays by its own rules on the phone, the Watch and the tag sheets. Pickleball can be scored the traditional
way (only the serving side scores, a second server, side-outs, the "4–2–1" call); tennis has No-ad; the tennis, padel and
squash tag sheets reach their detail boards; and doubles say who serves by name where the app can know it.

## User decisions this prompt follows

- Capabilities and every screen tell the truth (2026-11-11): nothing claims a feature that isn't built.
- Model fields are additive optionals only. Shared phone / Watch types live in `ios/App/Shared/`.
- Earlier device fixes stay: one persistent camera preview per recording cover with the 0.8 s delayed teardown and
  `ensureCapturing`; paused players open on the first moment with video; the doubles Team name / Player 1 / Player 2.

## Approach

- **Shared tally** (`Shared/RacketLiveScore.swift`): `RacketLiveRules` gains additive optionals `sideOut`, `doubles`,
  `servesFirst`. Side-out tally: only the serving side scores; doubles start at server 2 ("0–0–2"); server 1 losing hands
  to server 2, server 2 losing is a side-out to the other side's server 1; singles side out at once; to N win by 2.
  The tally derives `serving` / `serverNumber`; `display` is the call ("4–2–1", serving score first), `header` reads
  "Game 1 · you serve"; `serveChanges` lists the serving side's trailing losses (the PbSideOut panels). No-ad reuses the
  golden-point rule (40–40 → next point wins; tiebreaks unchanged).
- **Pure app logic** (`RacketSportRules.swift`): `RacketFormat.sideOut` (pickleball) and `noAd`, the rules for a unit
  (`SessionExercise.racketLiveRules`, first server alternating per game in side-out), `RacketDoublesServe` (the player
  serving within a side for each sport, from Warmup's new "Who serves first for us?"), the copy (game caption, Watch note,
  tag lines "Games 4–3 · Point 40–30", "4–2–1 · Mia serving next", "Mia, server 2", "Mia serving, right court"),
  `RacketServeDetail` (TnServe), `RacketWallDetail` (PdWall), `RacketLetCall` (SqLet).
- **Model (additive optionals)**: `SessionExercise.racketSideOut`, `racketOurFirstServerRaw`; `RacketRally.serveRaw`,
  `wallRaw`. Tennis No-ad is stored in the existing `racketGoldenPoint` (the same deciding-point rule).
- **Screens**: PbScoring before the pickleball match form (as PdDeuce for padel); PbMatch shows header, Film, Watch,
  buttons only; the game screen's PbSideOut panel; ScoreOnly / StatsOff / Watch show the call; TnMatch "No-ad" chip;
  TnServe / PdWall / SqLet sheets from the tag sheet; the tag sheet's sport score line; Warmup's doubles row.
- **Watch**: side-out buttons "We won / They won", the note "Winning while receiving doesn't score", tennis "You're
  serving · tap for the point winner" (from the phone's note).
- **Low items**: PlayerOriginal "Rallies only" as a chip; the recap's drill row "Longest 19 · 3 blocks · 3 videos".

## Acceptance criteria

- [ ] Side-out, server rotation, game end, singles, first server per game, no-ad deciding point and unchanged tiebreaks
      are unit-tested (`RacketSportRulesTests`).
- [ ] PbScoring → PbMatch; side-out games tally "0–0–2 → 1–0–2 → 1–0–1 …" on the phone and the Watch; PbSideOut shows
      after a serving-side loss and returns on the next rally (or Undo).
- [ ] TnMatch No-ad; a no-ad deuce point decides the game on the Watch and phone.
- [ ] TnTag → Serve details → Next point; PdTag → Did it bounce first? → Back / Next; SqTag → Let, stroke or no let.
- [ ] Doubles serve lines name the player when "Who serves first for us?" was answered, else the side.
- [ ] Every racket UI suite passes one at a time; new UI tests per sport for the new screens.
- [ ] `decisions.md` and `docs/knowledge-graph/data.js` updated.

## Constraints

- On-device only. `HighlightEngine` untouched. No model, no fake numbers. No video files, no BlurBall weights.

## Test plan

1. `cd ios/App && xcodegen generate`; build Snappet and SnappetWatch.
2. `SnappetTests` alone, serial; each racket UI suite separately (uninstall first); `cd ios/HighlightEngine && swift test`.
3. Device build + install (no device walk: these screens have no camera or video dependence).
4. Board re-check `racket-wireframes/audit/recheck-sports.md`, screenshots + board renders + side-by-side composites in
   `racket-wireframes/shots/sports/`.
