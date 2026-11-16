# Prompt: Racket — edit a logged match later, a complete state machine (prompt 260)

**File**: pdd/prompts/features/racket-sports/260-ios-racket-edit-match.md
**Created**: 2026-11-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: device feedback after prompt 259. Stacked on `claude/racket-turn-export`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (no new field, no new raw value)

## Goal

The user: "i want to make sure each match is editable in case someone made mistake in updating and realize it later.
make sure it that side of state machine is complete". The real case: a match whose set 0 is a stray 9–11 logged five
minutes before the recording (6.4 s, no video); sets 1–3 are the recording's games (`baseSetIndex` 1, parts linked 1,
2, 3, then not play), rallies tagged in each; set 3 came from the stop sheet and still carries the whole recording
(792 s) though its video is 211 s. The recap shows four games and "L 0–4"; the truth is three, 0–3. The session Edit
screen only edits values; the only removal is Remove match, and removing a set by hand would break `baseSetIndex` and
every part's `setIndex`.

## Context the implementer needs

- Games are `SessionExercise.sets` (no id). Things that point at a game by position: `RacketRecordingLog.baseSetIndex`,
  `RacketVideoPart.setIndex` (a game group's first half; `joinedSetIndexes` is draft-only and empty once saved), a
  game-by-game / adopted-clips `game` mark's `index`, and `SessionMedia.assignedSetIndex`. AI requests / imports, scans,
  part looks and rallies are time ranges, untouched by renumbering. Heart rate per game is derived (`completedAt`,
  `durationSec`, the split's times for a joined game), so it follows once the indexes are right. XP / streak / badges
  are a ledger re-derived from history (`ProgressionSnapshot.ledger`), never stored per session.
- One `SessionExercise` holds at most one `RacketRecordingLog`; "several recordings" of one match are several runs /
  assets of that log (game by game continued, resumed after an interruption).

## Approach

Pure `RacketMatchEditor.swift` (no UIKit / SwiftUI): a draft with stable game ids, links part id → game id and mark →
game id; every operation returns a new draft; `validate` / `normalized`; `commit` writes the indexes again from the ids;
`RacketMatchSave` applies it across the session (and the media moves). Thin `RacketMatchEditViews.swift`.

### Transition table (each row a function and a unit test)

| Operation | Precondition | Result |
|---|---|---|
| Score | any game | the score, confirmed (not "from Watch" / unconfirmed; a suggestion cleared) |
| Confirm score | Watch tally or suggested score | becomes the confirmed score |
| Confirm score | already confirmed / nothing to confirm | off: "This score is already confirmed." / "No score to confirm yet. Enter it above." |
| Score unknown | any game | "Score unconfirmed", counts for neither side |
| Remove game | the match's only game | off: "This is the match’s only game. To remove it, use Remove match." |
| Remove game | no video | it goes; later games renumber; `base` drops if it was before the recording |
| Remove game | has video, no choice | nothing; the dialog asks (Keep as an extra game (not counted in the match) / Mark as not play / Cancel) and says how many tagged rallies stop counting |
| Remove game | has video, extra | its halves become "Rallies, no score" (unsure, not counted), its timeouts breaks |
| Remove game | has video, not play | its halves and timeouts become Not play |
| Add game | position 0…count | a new game there, no video, unconfirmed (or a given score), logged between its neighbours' times; at or before the boundary it is a game logged before the recording |
| Move earlier / later | at the edge | off: "Already the first game." / "Already the last game." |
| Move earlier / later | both it and the neighbour have video | off: "Both games have video, so they keep the order of their video. Change the split to fix the video." |
| Move earlier / later | otherwise | swap; `base` stays, clamped so a video game is on the recording's side |
| Link video | game has video | off: "Unlink its video first." |
| Link video | part taken | off: "Another game uses this video." |
| Link video | would break video order | off: "This video would put the games out of order. Move the game first." |
| Link video | an unlinked game part or a "Rallies, no score" stretch | linked; the part is a game; the game is logged at its video's end with its played time |
| Unlink video | no video | off: "This game has no video." |
| Unlink video | has video | game stays (no video); its video becomes "Rallies, no score" (can be linked again) — chosen over a new unconfirmed game so unlinking never adds a game |
| Match details | always | opponent / doubles partner + two opponents + team, event, round, best of, points; a quiet note when games exceed best of or the match was decided earlier; never deletes games |
| Move to another match | has video | off: "A game with video stays with its recording. Unlink its video first." |
| Move to another match | only game / no other match | off (the only-game reason / "There’s no other match in this session.") |
| Move to another match | otherwise | leaves; Save puts it in the other match by its time, renumbers that match too, moves its media |
| Cancel | any | the draft is dropped |
| Save | any | normalized → validate must be empty → one write |
| Remove match (existing) | any | the entity goes, its media is untied to General, its recording stays in Photos; other matches untouched |

### Operation 7 — built and not built

- **Built**: move a game with no video to another match of the same session.
- **Not built: merge two matches.** A match holds one recording log; two logs can't become one without rewriting one
  recording's times onto the other's timeline (breaking every part, rally, scan and AI record). Instead: move the
  no-video games one by one into the match you keep, then Remove match on the other (its recording stays in Photos).
- **Not built: split a match in two at a game.** It needs a new match entity and a decision about which side owns the
  recording, its rallies and scans; a finished session has no "add a match" path to host it. Instead: unlink or remove
  the games that don't belong (their video is kept), or move no-video games to another match of the session.

### Invariants (validate + normalized + a test each)

1. Every link (part → game, mark → game) points at a game in the draft; none twice.
2. Only a group's first half holds a link; every game group has one (an unlinked one becomes "Rallies, no score");
   the split's timeout / link / belongs rules hold (its time rules are the split editor's: this editor never moves an
   edge, and a game-by-game split has gaps on purpose).
3. Games with video are in their video's order.
4. `base` within 0…count and never after the first game with video.
5. A game's length fits its video (`RacketGameDuration`).
6. Nothing with video leaves for another match; scores not negative.

### Also fixed

- **Duration rule** (`RacketGameDuration.fitted`, used by `RacketSplitAssign.apply` and the editor): a linked game keeps
  its own length when it fits its video's span (+20 s); a longer one (the stop-sheet game carrying the whole recording)
  takes the video's played time; a Watch game's own shorter wrist-timed length is kept; no length stays none.
- **Your videos ids** are unique per match: the first recorded match keeps `racket.videos.play.0` etc., later matches
  `racket.videos.play.m1.0` (also changeSplit / split / editMatch).

## Acceptance criteria

- [x] Unit (`RacketMatchEditorTests`): every row, every invariant, the real case (remove set 0 ⇒ base 0, links 0–2,
      "L 0–3", three games, tags intact, last game 211 s), heart rate following each game, media following its game,
      game-by-game / derived / no recording / older-build decode, 3000 random operation sequences.
- [x] UI (`RacketEditMatchUITests`, `-uiTestRacketEditMatch`): remove the stray game → Save → recap "L 0–3", three
      games; Your videos plays Games 1–3 with their scores; Cancel keeps everything; the video choice dialog; a disabled
      move's reason. Screenshots `shots/edit-match/`.
- [x] `decisions.md`, `project.md`, schema, `docs/knowledge-graph/data.js` updated.

## Constraints

No real footage; vision-only rally detection; simulator only (the phone run is the user's).
