# Prompt: Racket round trip with another AI app (prompt 247)

**File**: pdd/prompts/features/racket-sports/247-ios-racket-ai-roundtrip.md
**Created**: 2026-11-07
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#438](https://github.com/harshal2802/snappet-mobile/issues/438) → step 4 of 6 ("Round trip with another
AI"); builds on prompt 246 (step 3: videos, player, manual tagging and split)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframes (user-approved, five review rounds — the source of truth)**: canvas A / B linked from #438. Boards for this
step: `TtAISend`, `TtAIPrompt`, `TtAIImport`, `TtAICompare` and the per-sport variants (`Bd` / `Tn` / `Pb` / `Pd` / `Sq`).
Arrows (flows): NoModelVideos / Videos / DrillVideos → AISend ("Another AI app"); Videos → AIImport ("Bring results
back"); AISend ↔ AIPrompt ("View and edit" / Back); AISend → AIImport ("Send, app replies"); AIImport → AICompare
("Compare first"); AIImport → PlayerAnalyzed ("Add as suggestions"); AICompare → PlayerAnalyzed ("Done"). Review5 low:
the AI "long" ending mapping.

## Goal

Rally finding has no model yet (step 5), so a player can ask another AI app they already use to analyze a part. Snappet
sends the part's video (or still frames for an app that can't take video) together with a prompt written for the
sport, the user brings the app's reply back by pasting it or choosing a file, Snappet reads it tolerantly and shows what
it found next to the user's own tags, and the user accepts it per item or all at once. Nothing the user tagged changes
unless they pick the other app's answer for that item.

Settled (#438 and the boards, do not reopen): no API keys, no network calls and no third-party SDKs: the system share
sheet carries the clip and the prompt, the clipboard / Files bring the reply back. The privacy note ("This leaves your
phone") and the permission switch ("Required each time. Send stays off until this is on") are on every send. The
prompt's JSON format line can't be removed; edits are kept for next time per sport. Imports "never change anything
you've tagged yourself" (AIImport); suggestions are "shown dashed and labelled" with the app's name.

## Context the implementer needs

- `RacketRecordingLog.rallies` (prompt 246) are time ranges on the recording's timeline, with `winnerRaw`, `endingRaw`,
  `lastShotBy`, `notRally` and an unused `sourceRaw` ("nil / you; a model's rallies will say which model").
- Your videos (`RacketVideosCover`) lists per-part rows (`RacketVideoRows`) and drill block rows; the player
  (`RacketPlayerScreen`) has Original / Analyzed; `RacketVideoLibrary.export` builds an .mp4 over segments
  (`RacketVideoMap.segments`). Step 3 left "Another AI app" out (decisions 2026-11-07).
- `ShareSheet` is the one `UIActivityViewController` bridge. The app has no share extension and no document types, so
  "share it to Snappet" (share-in) is not available yet: import is paste + Choose a file.

## Approach

- **Pure** `RacketAIRoundTrip.swift`:
  - `RacketAIApp` (ChatGPT, Gemini, Claude — frames only, Other apps) and `RacketAISendKind` (rallies only, whole part
    smaller, original quality).
  - `RacketAIClip`: the sent clip as pieces of recording time, joined end to end; maps clip seconds back to recording
    seconds (rallies only skips the dead time, so this is piecewise).
  - `RacketAIWire`: the schema id `snappet.racket-analysis/1`, each sport's ending list as snake_case wire names (the
    boards' lists = step 3's chips), side words (near / far), synonyms ("long" / "wide" → out, "netted" → net, …).
  - `RacketAIPrompt`: a deterministic prompt per sport: an editable body (the board's lines) and a fixed tail that
    can't be edited (the clip's length and which part / recording range it is, the allowed endings, the JSON format
    line with an example, "Fill in analyzer"). Same inputs, same text.
  - `RacketAIParser`: tolerant reading of a reply: smart quotes and BOM normalized; code fences or surrounding prose
    stripped; the first balanced JSON object / array (JSON5 allowed: trailing commas, comments); key aliases
    (`start_s` / `start` / `from` …); times as seconds, "75s", mm:ss, h:mm:ss, "1:02.5"; or, with no JSON, a pasted
    table / list (two times per line + side + ending words). Validation with reasons: ends before it starts, too
    short, after the video ends (rejected), past the end (clamped), negative start (clamped), overlaps the rally before
    (rejected), duplicates; unknown endings counted with a suggested mapping ("Count it as Out" / "Leave them out");
    sport mismatch is a warning; analyzer app / model read when given.
  - `RacketAIImportBuilder`: parsed rallies → recording-time `RacketRally`s with provenance (`sourceRaw = "ai:<app>"`),
    winner from near / far and the player's side.
  - `RacketAICompare` / `RacketAIMerge`: match AI rallies to your rallies one to one by overlap; items: is it a rally
    (not marked by you), winner (not tagged / differs), ending (not tagged / differs), "Not a rally" disagreements; per
    item yours / theirs (yours by default); "Use <app> for all" never touches rallies you tagged yourself; merge
    applies only the picked items and records who set each tag (`tagSourceRaw`).
  - Provenance: `RacketTagSummary.fromAI` / `RacketTagTotals.fromAI`; "From your tags, 5 of 7 · 2 accepted from
    ChatGPT". Accepted items count in history (the user chose them); suggestions never do.
- **Edge** `Services/RacketVideoLibrary.swift`: `frames(...)` (JPEG stills via `AVAssetImageGenerator` for "Claude ·
  frames only"); send uses the existing export (smaller / original).
- **Screens** `RacketAIViews.swift`: AISend (privacy note, what to send, prompt included → AIPrompt, send to, the
  permission switch, Send → export → share sheet with the prompt; the prompt is also copied), AIPrompt (Copy, Edit,
  Reset to default; the fixed tail is shown but not editable), AIImport (Paste from clipboard via `PasteButton` — no
  paste prompt — or paste into the box, Choose a file; Read N rallies · M skipped with reasons; unknown ending mapping;
  Made with / Model it reported / Change app; Which side were you on?; Add as suggestions / Compare with Snappet first),
  AICompare (yours vs the app, agreements count, per item choice, Keep my choices / Use <app> for all, Done → Analyzed).
- **Wiring**: Your videos part rows and drill blocks get "Another AI app" and "Bring results back" (and "Compare" while
  suggestions wait); the player draws suggestions dashed on the timeline and labels them in Analyzed; TagDone and From
  your tags show what came from another app.
- **Model (additive Optionals)**: `RacketRecordingLog.aiRequests`, `aiImports`; `RacketRally.tagSourceRaw`. The
  recorder's late log save keeps them (FreeformPlayerView merge).

## Output

- New: `RacketAIRoundTrip.swift`, `RacketAIViews.swift`, `SnappetTests/RacketAIRoundTripTests.swift`,
  `SnappetUITests/RacketAIUITests.swift`.
- Changed: `RacketRecording.swift` (log fields), `RacketRallyTags.swift` (provenance), `RacketVideoViews.swift` (entry
  points, routes), `RacketPlayerViews.swift` (suggestions on the timeline / Analyzed), `FreeformPlayerView.swift`
  (merge), `Services/RacketVideoLibrary.swift` (frames).
- Docs: `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [x] Your videos → Another AI app → AISend: privacy note, three send choices (rallies only off until rallies are
      marked), View and edit → AIPrompt, four apps, permission switch gates Send (export + share sheet are device legs).
- [x] AIPrompt is deterministic per sport and part, names the schema, the allowed endings and the clip's time range;
      edits persist per sport, the format tail can't be removed, Reset to default restores it.
- [x] Bring results back → paste (or a file) → "Read N rallies", skipped ones with reasons, unknown endings mapped or
      left out, side chosen → Add as suggestions (dashed on the timeline, labelled in Analyzed) or Compare first.
- [x] AICompare shows agreements and disagreements against your tags; per item and "Use <app> for all" (not on your own
      tags); Done merges and opens the Analyzed player. Your tags only change where you picked the app's answer.
- [x] Provenance visible: "from ChatGPT" on accepted items, TagDone / From your tags counts; accepted items count in
      history, suggestions don't.
- [x] Pure logic tested (`RacketAIRoundTripTests`, many malformed replies); UI: import → compare path on the seed.
- [x] No network, keys or SDKs; no platform imports in `HighlightEngine`.
- [ ] Device legs (owed): see Test plan step 4.

## Where this differs from the boards (recorded in decisions.md)

- AICompare compares the reply with **your tags** ("Your tags vs ChatGPT"), not "Snappet v2": there is no model until
  step 5. Your own tags are shown (the board hides them) but start on yours and change only by picking that item;
  "Use <app> for all" (board: "Use Snappet for all") skips them. "Compare with Snappet first" reads "Compare with your
  tags first".
- AIImport: no "share it to Snappet" (no share extension yet); paste (PasteButton or the text box) and Choose a file.
- Table tennis "long" suggests **Out**, not the board's "Net".
- AIPrompt's fixed tail adds the clip's length, recording range and "times from the start of this video" lines (and a
  stills / rallies-only line when they apply) to the board's endings + JSON lines.
- "Send to" names the app; the system share sheet is where it's actually picked (no app can be targeted directly).

## Constraints

- On-device only; Snappet makes no network call. The other app's privacy terms apply to what the user sends.
- State verification honestly: sharing to real AI apps and importing their replies are device items.

## Test plan

1. `cd ios/App && xcodegen generate`; build `Snappet` and `SnappetWatch`.
2. `xcodebuild test … -only-testing:SnappetTests -parallel-testing-enabled NO`; racket UI suites separately.
3. `cd ios/HighlightEngine && swift test` (untouched).
4. Device: mark 3 rallies on game 1, Another AI app → rallies only → ChatGPT (and Gemini; Claude frames), paste the
   reply back, compare, accept two items, check From your tags and the Analyzed player; try a reply as a .json file
   from Files.
