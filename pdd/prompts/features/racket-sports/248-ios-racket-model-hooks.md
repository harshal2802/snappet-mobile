# Prompt: Racket model hooks: capabilities, a rally model seam, a placeholder model and its screens (prompt 248)

**File**: pdd/prompts/features/racket-sports/248-ios-racket-model-hooks.md
**Created**: 2026-11-07
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#438](https://github.com/harshal2802/snappet-mobile/issues/438) → step 5 of 6 ("Model hooks"); builds
on prompt 246 (step 3: videos, manual tagging, the `RacketRallyFinding` seam) and prompt 247 (step 4: round trip with
another AI app, AICompare)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframes (user-approved, five review rounds — the source of truth)**: canvas A / B linked from #438. Boards for this
step: `TtCapabilities`, `TtChooseModel`, `TtModelCompare`, `Analyzing`, `FindRallies`, `AnalysisSettings`, `Summary`,
`Timeline`, `QuickTag`, `TtTagDone`, `TtDrillVideos`, `TtSplitDone`, `TtNoModelVideos` and the per-sport variants
(`Bd` / `Tn` / `Pb` / `Pd` / `Sq`). Arrows (flows): Videos → Analyzing ("Find rallies"); Videos → ChooseModel
("Re-scan…"); ChooseModel → Analyzing ("Re-scan"); Analyzing → Summary ("Review game"); Analyzing → Videos ("Do it
later"); Analyzing → ModelCompare ("Scan done, compare on"); ModelCompare → Summary ("Use v3") / Videos ("Keep v2");
Summary → Timeline ("Open timeline") / Videos ("Done for now"); Timeline → Tag ("Tap an unsure rally"); Tag → TagDone;
SplitDone → Analyzing ("Find rallies in all"); DrillVideos → Analyzing / ChooseModel; Settings → Capabilities;
Match / NoModelVideos → Capabilities ("What works"); Capabilities → NoModelVideos ("Preview with no model").
Review5 lows: NoModelVideos labelled as a preview; Analyzing from a drill says blocks, not "Game 2".

## Goal

Give rally finding a real seam and a model that works on a phone today, so the user can test the whole racket flow end
to end on an iPhone + Apple Watch: record a match, split it, tap Find rallies, watch the scan's progress (closeable,
cancellable, resumable), and get rallies on the timeline marked "Snappet guess", with the unsure ones queued for a
one-tap check. The model is a clearly labelled **placeholder**; the seam is what later models plug into.

Settled (#438, decisions, user, do not reopen): rally detection is **vision only** (no audio). The research spike's
BlurBall weights (prompt 220) are **evaluation only**: never bundled, downloaded or referenced. Every sport assumes the
placeholder model and the UI shows every feature as available ("✓ Available" + "Without it: …"), degrading to marking
and tagging by hand where a sport has no model. Live tracking during play is step 6 (needs a thermal test): only
post-recording scans here. No network, no API keys. `HighlightEngine` is untouched.

## Context the implementer needs

- Step 3 left `RacketRallyFinding.availability` returning `.notYet` for every sport and hid Find rallies / Re-scan /
  "Find rallies in all". Rallies live on `RacketRecordingLog.rallies` (recording time), with `sourceRaw` ("a model's
  rallies will say which model") and `tagSourceRaw` (prompt 247).
- Step 4's AICompare compares a reply with **your tags** because there was no model; its decision said the model's
  guesses become the other side once step 5 lands.
- Playback maps recording time to Photos parts through `RacketVideoMap.segments` (10-minute originals, gaps for
  interruptions). The simulator's stand-in camera saves no video.
- Per-point Watch taps are not recorded on the recording timeline (only the game's first point and game ends).

## Approach

- **Pure** `RacketModelHooks.swift`:
  - `RacketFeature` (the eight Capabilities rows with their "Without it" lines) and `RacketCapabilityRegistry` (per
    sport: the models, newest first, and the features the current model supports; a no-model preview).
  - `RallyModel` protocol: `RallyModelInfo` (id, version, name, sports, input requirement, placeholder flag), an async
    `scan(_:source:progress:)` over a recording range that checks cancellation, reports progress and returns
    `RallyGuess`es (times, confidence, an optional winner guess from a score tap). `RallyFrameSource` is the platform
    seam that turns video into the model's input (here: a per-frame motion signal).
  - `RacketMotionRallyRule`: the placeholder's rule over a motion-energy signal — smoothing, a rolling quiet baseline,
    robust spread, hysteresis, gap merge, minimum length, padding, a confidence; anchored by score taps when present
    (a tap after a found rally confirms it and names its winner; a tap with none before it adds an unsure guess;
    extra unanchored stretches between taps become unsure). Same shape as the spike's frozen rule (gap / min length /
    pad), different signal.
  - `PlaceholderMotionRallyModel`: chunked scan over the source (30 s chunks) with cancellation and progress.
  - `RacketScanRecord` (persisted per part: model, progress reached, status, results kept for compare);
    `RacketRallyGuessMerge` (guesses replace earlier unconfirmed guesses in the part, never your rallies);
    `RacketModelCompare` (one rally or two, found only by one side, winner differs); `RacketScanETA`;
    `RacketAnalysisSettings` (after a session: automatically / only on charger / ask me / never).
  - `RacketRally` gains `confidence`, `guessWinnerRaw`, `confirmed`; `isGuess` / `isUnsure`. Tagging or fixing a guess
    confirms it. History (`RacketTagTotals`) counts guesses only once confirmed.
- **Edge** `Services/`: `RacketMotionReader` (AVAssetReader over the Photos parts, small luma frames, fraction of grid
  cells that changed, 10 samples/s, cached per 30 s chunk in Caches so a stopped scan picks up where it stopped; throttles
  at `serious` thermal state and pauses at `critical`), `RacketScanCenter` (the queue: one scan at a time, progress, ETA,
  stop / resume, a background task so leaving the app pauses cleanly, waits for a charger when asked, writes results).
  A synthetic source for UI tests (`-uiTestStubRallySignal`).
- **Screens** `RacketModelViews.swift`: Capabilities (+ Preview a sport with no model), ChooseModel (models, Compare
  before replacing, other AI results with Remove), Analyzing (per part Ready / NN% / Waiting / Paused, ETA, Stop /
  Resume, Review, Do it later), ModelCompare (Use new / Keep earlier), game Summary (rallies found, longest, average,
  "Check N unsure", "Tag winners and endings", Open timeline), AnalysisSettings.
- **Wiring**: Your videos becomes FindRallies (scan state per row, Find rallies / Re-scan…, Open timeline, Scan all on
  charger, Settings); Drill videos and SplitDone get Find rallies / Re-scan… / "Find rallies in all"; the timeline shows
  guesses (dashed = unsure) with filters; the tag sheet shows a suggested winner and can walk only the unsure ones;
  TagDone shows Tagged by you / Snappet's guesses / Unsure left; AICompare uses Snappet's guesses as the other side
  where you haven't tagged; the match page links "What works for <sport>". The Watch bridge records each point tap on
  the recording (`point` mark) so scans can anchor on it.

## Output

- New: `RacketModelHooks.swift`, `RacketModelViews.swift`, `Services/RacketMotionReader.swift`,
  `Services/RacketScanCenter.swift`, `SnappetTests/RacketModelHooksTests.swift`, `SnappetUITests/RacketModelUITests.swift`.
- Changed: `RacketRallyTags.swift`, `RacketVideoSplit.swift`, `RacketVideoViews.swift`, `RacketPlayerViews.swift`,
  `RacketAIRoundTrip.swift`, `RacketAIViews.swift`, `RacketRecording.swift`, `RacketWatchBridge.swift`,
  `FreeformPlayerView.swift`, `Services/RacketVideoLibrary.swift`, existing racket tests where step 3 asserted "no model".
- Docs: `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [x] Capabilities lists the eight features per sport from the registry, each "✓ Available" with its "Without it" line;
      "Preview a sport with no model" opens Your videos in the no-model state, labelled as a preview.
- [x] Your videos → Find rallies → Analyzing: progress per part, ETA, Stop / Resume, Do it later keeps scanning; done →
      rallies on the timeline as "Snappet guess", unsure ones dashed and counted; Summary → Check N unsure → TagDone
      "Unsure left 0".
- [x] Re-scan… → ChooseModel → Re-scan with Compare on → ModelCompare → Use / Keep. Your own rallies are never changed.
- [x] AICompare compares the app with Snappet's guesses where you haven't tagged (yours stay protected).
- [x] The rule is pure and tested on synthetic signals (bursts, noise, drift, gaps, anchors, lets); the scan loop's
      cancel / progress / resume tested with a fake source.
- [x] No audio, no network, no BlurBall reference; no platform imports in `HighlightEngine`.
- [ ] Device legs (owed): scan speed, thermal state, accuracy on real footage, background behaviour.

## Constraints

- On-device only. The placeholder is honest about being a placeholder in its name and in decisions.md.
- State verification honestly: a simulator run with a synthetic signal is not a device scan.

## Test plan

1. `cd ios/App && xcodegen generate`; build `Snappet` and `SnappetWatch`.
2. `xcodebuild test … -only-testing:SnappetTests -parallel-testing-enabled NO`; racket UI suites separately (incl. the
   new `RacketModelUITests` on `-uiTestSeedRacketVideos -uiTestStubRallySignal`).
3. `cd ios/HighlightEngine && swift test` (untouched).
4. Device: record a whole match with Watch scoring, split, Find rallies on game 1; close the screen mid-scan, leave the
   app and come back, Stop and Resume; check the guesses against the video, Check unsure, Re-scan with Compare on.
