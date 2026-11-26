# Prompt: The phone's overlay reference, committed

**File**: pdd/prompts/features/studio-review/307-ios-studio-overlay-reference.md
**Created**: 2026-11-26
**Project type**: Native iOS (Swift) — test data and a test; no app behaviour changes.
**Chain**: `pdd/prompts/features/studio-review/PLAN.md` → P0/P1 device legs (prompt 304, "Owed on device" 1a)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Prompts 310 and 311 (PLAN P2, P3) move text, stickers, climb tags and the heart-rate tile from the
Core Animation tool into the Studio compositor. Once that is done nothing draws them the old way,
so the "before" pictures have to be captured from a phone first and committed. Prompt 304 built
the capture (Settings → Developer → Studio render check → "Capture overlay reference"); the user
ran it on 2026-11-26. This job commits those files and a test that keeps them one whole phone
capture.

## What was captured

- iPhone 13 Pro Max (iPhone14,3), iOS 27.2.1, Debug build of `studio-v2` at `25a7d0c8`,
  2026-11-26T23:38:50Z. Pulled from the app's `tmp/studio-overlay-reference` folder with
  `xcrun devicectl device copy from --domain-type appDataContainer`.
- 12 files: 11 frames (540×960 PNG) and `manifest.json`. The screen said "12 files saved"; the
  user expected 11 because the phone list said "the 11 images". The twelfth file is the
  manifest; prompt 304's code and its UI test already count 12 (`StudioOverlayReference.fileNames`
  is the frames plus the manifest). The phone list's wording was the mistake, not the capture.
- Looked at every frame. Text (bold, italic, highlight, rotation, opacity, appearing at 0.3 s and
  going at 0.8 s), the climb tag chip and the heart-rate tile (number, unit, zone chart) are
  drawn as the scenes describe, with two exceptions besides the stickers:
  - **Transition frame 21 shows both tiles.** It is 0.7 s, exactly the handover between the two
    clips' tiles, and both windows include that instant (`gateSegmentOpacity`: 0 at `e + ε`, full at
    `e`; the next tile full at `s = e`). Any other frame shows one; a real export shows the double
    tile on one frame at most. Found by the review of this PR. Not fixed in the Core Animation
    path, which prompt 311 replaces; 311 must draw exactly one tile on that frame. Listed as known
    wrong.
  - **The climb tag has one line.** The scene asks for "Attempt 2", but the editor adds that line
    to the text (`KilterClimbCaption.composeClimbTag`) before an export and the capture passes the
    raw text. The frame is a true picture of a one-line chip; a two-line chip has no reference
    (a gap since prompt 304).
- **The stickers are not.** Both stickers in `ref-sticker` (a star, and an orange flame at 2×,
  turned −20°) came out as solid black boxes: right place, size and rotation, no symbol, no
  colour. That frame goes through the same export as a user's video, so users' exported videos
  have the same bug. Prompt 304's device check 1a ("check that … the star sticker … are in the
  pictures") fails here.

## Approach

- Commit the files unchanged in `ios/App/SnappetTests/GoldenFrames/OverlayReference/` with a
  `README.md` (what, where from, the table of scenes, the sticker caveat, how to replace).
  `GoldenFrames` is already excluded from the test bundle, so `project.yml` does not change, and
  the golden-frame tests only list `.png` files at the folder's top level, so a subfolder does not
  disturb `testGoldenFolderHoldsExactlyTheScenesImages`. The Debug app's copy script copies only
  top-level PNGs, so the reference is not shipped in the app.
- `StudioOverlayReference.knownWrongFrames` = `["ref-sticker-f010.png",
  "ref-hr-tile-transition-f021.png"]`: the frames are kept (they are the honest record of what the
  export did) but marked so a later comparison skips them.
- Prompt 308 fixes the sticker export. After it is on the phone, a new capture replaces
  `ref-sticker-f010.png` and `manifest.json`, and the sticker frame leaves `knownWrongFrames`.
- Stale prompt numbers in the debug screen ("drawn by the compositor from prompt 305 / 306",
  "prompt 314+") now say 310 / 311 / 318+, with their tests.
- PLAN.md: 307 and 308 take the next two numbers, as 305, 306 and 309 did before them, so P2 is
  now 310, P3 311, P5 312 … P11 318+. P4 stays 309 (done).

## Output

- `ios/App/SnappetTests/GoldenFrames/OverlayReference/` — the 12 files and `README.md`.
- `ios/App/Snappet/Features/WorkoutTracker/StudioOverlayReference.swift` — `knownWrongFrames`.
- `ios/App/SnappetTests/StudioOverlayReferenceCaptureTests.swift` — two tests:
  - `testTheCommittedReferenceIsAWholePhoneCapture`: the folder holds exactly the capture's files
    and a README (hidden files ignored); the manifest is from a device, with the renderer string
    the old export wrote (frozen, so a later change to today's label does not fail it); every frame
    is a 540×960 PNG named in the manifest.
  - `testKnownWrongFramesAreInTheReferenceAndNamedInTheReadme`.
- `pdd/context/decisions.md` (2026-11-26), `PLAN.md` numbers, the knowledge-graph node for the
  render check.

## Acceptance criteria

- [x] The 12 files are byte-for-byte what the phone wrote.
- [x] Full unit suite passes; no golden image changed.
- [x] No app behaviour changes (only a DEBUG constant is added).

## Test plan

1. Full unit suite (`-only-testing:SnappetTests`).
2. CI: the path maps to the `studio` area (targeted UI legs).

## Owed on device

Nothing for this job. Prompt 308's device steps include the new sticker capture.
