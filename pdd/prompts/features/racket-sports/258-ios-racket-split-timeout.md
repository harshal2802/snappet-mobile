# Prompt: Racket split — Play in the split sheet, timeouts inside a game, and a complete split state machine (prompt 258)

**File**: pdd/prompts/features/racket-sports/258-ios-racket-split-timeout.md
**Created**: 2026-11-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: device feedback on the split, after prompt 257. Stacked on `claude/racket-tag-video`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (additive Optionals: one part kind, one draft field, a suggested score)

## Goal

The user: "when i split the video and hit play. it doesnt play before saving"; "while spliting if there was timeout
during the game there is no way to combine the videos before and after the timeout cut"; "think about completing this
state machine covering all the edge cases like this." Approved plan: a **Timeout** choice for a break between two halves
of the same game; the halves count as ONE game (one score, one rally list); the timeout stays in the original recording
but is skipped in the player and left out of shared copies. Their real match is already split and saved, and Game 4 /
Game 5 (both unscored) are really one game.

## Context the implementer needs

- The split is `RacketVideoSplit.swift` (parts, proposal, assignment, rows) and the cover `RacketVideoViews.swift`
  (review / edit sheet / assign / done). Links are indexes into `SessionExercise.sets`; removing a game shifts the rest.
- Play in `RacketSplitEditSheet` called `play(from: position, until: end)`; after a handle moved or "Split here" the
  playhead sat on the end, so nothing played.
- A saved split could not be reopened (the "Split recording" chip only showed before a split).

## Approach

1. **Representation** (`RacketSplitGroups.swift`, pure): a new kind `.timeout`. A game is a **group**: a game part and
   each (timeout, game) pair after it. A continuation is *defined* as the game directly after a timeout — no flag that
   could disagree. The group's one link (`setIndex`) sits on its first half. While editing, a half that brought its
   own logged game into a group keeps it in `joinedSetIndexes` (draft only), so changing the timeout back returns it;
   Save folds joined games into the group's game (`RacketSplitJoin.commit`) and renumbers.
2. **Invariants** (validate reports, normalized repairs): (1) tiling, each ≥ 5 s (a short part borrows time from a
   neighbour, else merges, the linked one surviving); (2) a timeout has game halves either side, else it becomes a
   break; (3) by construction; (4) one link per group on its first half, no game linked twice; (5) halves share
   `belongs`; (6) a drill holds no timeout (becomes a rest).
3. **Transition table** (each implemented in `RacketSplitEditor` and unit-tested):

| Operation | Result |
|---|---|
| Choose Timeout, neighbours are game halves with the same `belongs` | halves join; the later half's game becomes joined; a game part turned timeout brings its game in too |
| Choose Timeout, otherwise | chip disabled: "A timeout sits between two halves of the same game." |
| …and two or more of the joined games have a score | confirm sheet "Game 4 and Game 5 become one game: 6–5 + 5–3 = 11–8", Join them / Cancel |
| …one score or none | no question; the scored one (or none) stays, an empty placeholder folds in |
| Timeout → any other kind | group dissolves there; the later half gets back its own joined game, else no link (Save matches or creates its game) |
| Game half → non-game | its timeouts become breaks; if it held the link, the link (and joined games) move to the group's next half |
| Split here in the first half | the piece touching the timeout keeps the link; the other is a new game, no link |
| Split here in a later half | the piece touching the timeout before it stays; the detached piece is a new game, no link |
| Split here in a timeout | disabled: "A timeout can’t be split. Change it to a break first." |
| Merge with next, game half followed by its timeout | the WHOLE game (halves + timeouts) becomes one plain part (note says so first) |
| Merge with next on a timeout | disabled: "A timeout joins its two halves. To make it one part, use Merge with next on the half before it." |
| Merge with next on the last part | disabled |
| Merge with next, break before a group | the break takes the first half; the link moves to the next half |
| Drag / nudge edges | neighbours follow; a timeout shrinks to 5 s, never vanishes |
| G T G T G | one game |
| Belongs to, this match / practice | every half follows / the half leaves (as above) |
| Cancel / Save | discard / repair then validate; never save an invalid list |

4. **Save** (`RacketSplitCommit`): normalize → fold joined games (two+ scores ⇒ a *suggested* sum, "Score unconfirmed";
   one score kept as it was; durations add up = played time) → `RacketSplitAssign.apply`, now group-aware: links the
   editor kept are honoured first, a Watch game is matched by the end of the group's LAST half, then in order; a new
   game is "Score unconfirmed", its length the played time, with a suggested score from its rallies' tags. `remap`
   moves photos / clips attached to a game by index (`SessionMedia.assignedSetIndex`).
5. **Play fix**: `RacketScrub.playStart` — the playhead when inside the part and > 0.3 s before its end, else the part's
   start. The sheet uses `RacketSplitVideo`: the prompt-257 box (picture-shaped, turn honoured), tap to play / pause,
   speed, full screen with zoom; the range strip stays the scrubber.
6. **Downstream**: Your videos one row per game (played length, "1 timeout skipped", rallies outside timeouts); review
   "Game 2, continued" / "Timeout · 3:10, skipped"; assign / done one row per game; "Change the split" reopens a saved
   split; the review suggests "Was this a timeout in Game 2?" when only one side of a break is scored. The Watch-mode
   player, Analyzed and Timeline players skip timeouts (`RacketPlayback.playedClock`), show played time, mark each
   timeout on the progress line, ±10 s in played time. Rallies inside a timeout leave every list / count / tag / score
   (`log.rallies(lo, hi)`). Edit: no mark in a timeout. Share "Whole game" joins the halves; the AI app's whole-game clip
   is the halves as pieces. Keep rallies only leaves the timeout's rallies out. Scrub bar cosmetic: the rally is an
   accent bracket above the track.

## Acceptance criteria

- [x] Unit tests: every invariant and transition-table row, a randomised run (≥ 3000 operations), played ↔ recording
      time both ways (an edge exactly on a boundary), the user's match joined / renumbered / undone, scored join.
- [x] UI tests on the seeded match (`-uiTestRacketSplitTimeout`): Play advances after the end handle moves and after
      Split here; Timeout joins Game 4 and 5 into one row; the player skips it; back to a break gives two games; the
      disabled reasons show. Screenshots to `shots/split-timeout/`.
- [x] `decisions.md`, `project.md`, schema, `docs/knowledge-graph/data.js` updated.

## Constraints

- No real footage; vision-only rally detection. Simulator verification only; the phone run is the user's.
