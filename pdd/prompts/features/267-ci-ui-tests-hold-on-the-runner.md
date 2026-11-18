# Prompt: UI tests that hold on the CI runner, and failures that get their retries (prompt 267)

**File**: pdd/prompts/features/267-ci-ui-tests-hold-on-the-runner.md
**Created**: 2026-11-16
**Project type**: Native iOS test infrastructure + CI (XCUITest, GitHub Actions) — code lands in this repo.
**Chain**: prompt 261 (the UI suite as eight parallel legs, PR #457) → its first full run, 43935201896.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (no change)

## Goal

Run 43935201896 (macos-26 runner, Xcode 26.5, iPhone 17 Pro on iOS 26.4.1, `-retry-tests-on-failure
-test-iterations 3`) failed ten UI tests that pass on the local simulator. Some failures were never retried. Find why,
fix the causes (not the symptoms: no blanket timeout raises, no sleeps, no skipped or weakened tests), and say plainly
what local runs can and cannot prove.

## Context the implementer needs

- Job logs of legs 4, 5 and 6 and the leg-6 `.xcresult` (its failure hierarchies) are the evidence. On the runner one
  XCUITest step takes 1–3 s, and "wait for the app to idle" took 18–60 s after some taps.
- The app's own short timers that tests interact with: the racket player's controls hide 3 s after the last touch
  while playing (`RacketPlayerChrome.hideAfter`); the pro camera's focus square + sun fade 3 s after the last touch,
  the zoom dial 2 s after; the Activity page's toast lasts 3 s.
- `xcodebuild` restarts the test runner after "unexpected exit, crash, or test timeout" and resumes at the NEXT test.

## Approach

1. **Not retried.** Every failure that was not retried is followed in the log by "Restarting after unexpected exit,
   crash, or test timeout" and a new runner pid, and every one is in a class with an `async` `setUp` or `tearDown`
   (`ActivityPageUITests`, `ActivityProgressUITests`, `RacketPlayerUITests`). The retried ones are in classes with a
   sync `setUp`. Reproduce with throwaway probe classes (a failing test, `continueAfterFailure = false`, async vs sync
   hooks, async test method) before changing anything. Fix: every UI test's async `setUp`/`tearDown` becomes
   `setUpWithError`/`tearDownWithError`; `LibraryKilterUITests`' async tests become sync (`wait(for:)` in place of
   `await fulfillment(of:)`). `scripts/ci-ui-shard.py --check` (run by every leg) fails on any new async hook or test
   in `SnappetUITests`.
2. **Each failing test** — from its log and, where needed, the xcresult's UI hierarchy:
   - `RacketSportsUITests.testTableTennisMatchIsScoredGameByGameAndDecides` (all 3 tries): the session detail opened
     with the recap cards (stats, badges, the racket card, Photos & videos) filling the screen; the exercise sections
     were below the fold of a lazy `List`, so no `session.exerciseMenu` existed. Scroll to it
     (`XCUIApplication.scrollIntoView`, shared). **Corrected after run 44206031436** (failed again 3/3): the swipes
     never moved the list (scroll bar "2 pages, 0%" in all nine hierarchies, no new recording frame during the
     swipes, 0.5 s idle after each where a scrolling swipe on the same runner idles 2 s). Proven: the header is not
     realized because Photos access is denied on the CI simulator, so the Photos & videos card is 24 pt taller ("Enable
     Photos access in Settings"); with Photos revoked locally the layout matches and one swipe reaches the menu. Not
     proven, and not changed: why the list does not scroll after this flow on iOS 26.4.1 (the 26.4 runtime is not
     available locally). Needs a diagnostic CI run (the user's call: it means a push).
   - `RacketDrillUITests.testEverySportsDrillScreens`: after the relaunch for the second sport, Quick Start was tapped
     while the Gym Tracker was still sliding in and the tap was dropped (the hierarchy is still the Gym Tracker home).
     `XCUIApplication.startQuickSession()` taps until the session's timer shows; used by the racket suites that start a
     session this way.
   - `RacketPlayerUITests` (three tests): the test read the controls' label and tapped Pause in separate steps that
     outlasted the 3 s auto-hide. `tapControl(_:until:)`: give the controls a fresh 3 s, tap at once, check the
     outcome, go round; pause before stepping rallies instead of stepping while playing. (Tapping through the video's
     coordinates was tried: in the landscape walk, whose scene is turned on an upright simulator, such taps never
     reach the controls. The landscape walk checks rally 12 paused at its start instead of after 1.5 s of play.)
   - `RacketEditUITests` (run 44206031436, three tests) and `RacketVideosUITests` (same pattern, not yet failed): the
     player's auto-hide race in their own copies of the helpers. The helpers move to `RacketPlayerControls.swift`
     (shared); "play 1.5 s then pause" becomes Play then Pause at once (`playAMoment`) plus a check the playhead is
     still in the rally.
   - `RacketProCameraUITests` (two tests): the same race with the focus sun (3 s) and the zoom dial (2 s). Read the
     overlay from one app snapshot, drag through the preview's coordinates, retry the focus tap if it faded first.
   - `FestivalUITests.testShareSheetRendersAPlanCodeAndOffersScan`: after "Share my plan" the app did not idle for 60 s
     (52 s on the passing retry, 21 s after "Whole lineup"). App fix: `QRCodeImage` built a new GPU `CIContext` on
     every call from a view body; now one shared software context and a small cache.
   - `ActivityPageUITests.testTabsAboutAndAddToRoutine`: XCUITest's post-tap idle wait after "Push Day" took 18 s, the
     3 s toast had come and gone. Locally the same wait is 2.6 s of the toast's 3 s, so the toast can't be caught
     reliably anywhere. Check what it confirms instead: Push Day's exercise count on the Routines segment goes up by one.
   - `ActivityProgressUITests.testClimbDashboardAndClimbingOverview`: the first test of its leg; the app launch timed
     out on a just-booted simulator. Fixed by the retry fix (it is now retried) and by booting the simulator in the
     "Resolve" step so it settles during the build.
3. **No app behaviour changes** beyond the QR renderer (same image, faster), so `docs/knowledge-graph/data.js` is not
   touched.

## Output

- `SnappetUITests/UITestTaps.swift` (new): `tap(_:until:)`, `startQuickSession()`, `scrollIntoView(_:)`.
- `SnappetUITests/RacketPlayerControls.swift` (new): the racket player's controls (`tapControl`, `pause`,
  `playAMoment`, `freshControls`), shared by `RacketPlayerUITests`, `RacketEditUITests`, `RacketVideosUITests`.
- Changed tests: the 27 files with async hooks, `RacketPlayerUITests`, `RacketProCameraUITests` (also `@MainActor`),
  `RacketSportsUITests`, `RacketDrillUITests`, `ActivityPageUITests`, `LibraryKilterUITests`.
- `Snappet/Core/SnappetShareable.swift` (`QRCodeImage`).
- `scripts/ci-ui-shard.py` (`--check` lint), `.github/workflows/ci.yml` (boot early).
- `pdd/context/decisions.md` entry; `pdd/context/conventions.md` (Testing: no async hooks; wait on conditions).

## Acceptance criteria

- [ ] A probe shows a failing test with an async hook is not retried and with sync hooks is (local, Xcode 27.2).
- [ ] `ci-ui-shard.py --check 8` passes, and fails when an async hook is added.
- [ ] Every touched UI class passes 3 consecutive local runs (app uninstalled first); `SnappetTests` passes.
- [ ] No timeout raised, no sleep added, no test skipped or deleted. One assertion changes target: Activity page's
      transient toast → the routine's lasting change it confirms.

## Constraints

- Local runs cannot prove the CI result: the local simulator is fast. Say so; the next CI run is the check.
- Never commit videos or screenshots of real footage.

## Test plan

1. Probe run with `-retry-tests-on-failure -test-iterations 3` (probe file not committed).
2. `xcodebuild test -only-testing:SnappetTests`; each touched UI class three times, `simctl uninstall` before each.
3. The next CI run on PR #457.
