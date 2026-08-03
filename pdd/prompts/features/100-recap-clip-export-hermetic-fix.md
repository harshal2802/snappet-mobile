# Prompt: Make the seeded clip-export E2E actually hermetic (prompt 100)

**File**: pdd/prompts/features/100-recap-clip-export-hermetic-fix.md
**Created**: 2026-08-02
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone red-CI fix (found while shipping the wardrobe closet trio, PR #301)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

`RecapClipExportUITests.testSeededClipAnimatesHermeticallyOnSimulator` has been failing on **main**,
so every PR's UI suite is red before it starts and the signal is worthless — a real regression in
that suite would be indistinguishable from the standing failure. Make the test pass for the right
reason: by being hermetic, as its own documentation already claims it is.

## Context the implementer needs

- The test seeds a session with a **bundled** clip (`RecapClipSeed`, launch arg
  `-uiTestSeedRecapClip`), navigates Recap → card → detail → Share, taps **Animate**, and waits for
  `share.animate.result` to prove the real `ReelExporter` composition + export ran.
- `RecapClipSeed`'s docstring states the point is to run the export *"hermetically on the simulator,
  with no Photos library and no device."* **It isn't.** `ClipExportCoordinator.animate` finishes the
  render and then calls `MediaLibraryService.saveVideoToPhotos`, whose first line is
  `PHPhotoLibrary.requestAuthorization(for: .addOnly)`.
- On a fresh simulator that puts up a **system permission dialog**. The test registers an
  `addUIInterruptionMonitor` for it — but an interruption monitor only fires on the *next
  interaction with the app*, and the test's only interaction (`app.tap()`) happens immediately after
  tapping Animate, **seconds before the render finishes and the dialog appears**. From then on the
  test is parked in `waitForExistence`, which does not interact, so nothing ever dismisses the alert.
- `share.animate.result` renders only when `animateState` leaves `.rendering`. The blocked `await`
  keeps it `.rendering` forever, so the element never appears and the test burns its 90s timeout.
  Diagnosis confirmed by the fix: the test drops from a 90s timeout to **passing in ~21s**.
- Blame was established before changing anything: the failure reproduces on **main with no other
  changes present**, and the *other* CI failure in the same run
  (`BudgetUITests.testEditTransactionAndMonthSwitch`) passes locally and passed on CI re-run — a
  flake, not related.

## Approach

Skip the Photos save **only** under the seeded-E2E launch arg, via a `RecapClipSeed.isActive` flag
alongside the existing `argument` / `bundledScheme` test seams:

- The render is what the E2E proves; the Photos save is the single non-hermetic step in the path.
- The test already accepts `"Rendered …"` exactly as it accepts `"Saved to Photos"`, so reporting
  `.rendered(url)` keeps the assertion's strength — it still fails if the export produces nothing.
- Zero production impact: the branch is unreachable without the launch argument, the same gating the
  bundled-clip `avAsset` fallback already relies on.

Rejected alternatives: granting Photos via `simctl privacy` in CI (moves an app-behavior problem into
CI config, and leaves the test broken for anyone running it locally); polling the app with periodic
taps to provoke the monitor (makes the test slower and racier to work around a dialog it should never
see).

## Output

- `ios/App/Snappet/Features/Feed/RecapClipSeed.swift` — `isActive`, documenting the hang.
- `ios/App/Snappet/Features/Feed/ClipExportCoordinator.swift` — skip the save when it's active.
- `pdd/context/decisions.md` — the lesson, not just the change.

## Acceptance criteria

- [ ] `RecapClipExportUITests` passes on the simulator, in seconds rather than by timeout.
- [ ] The assertion still fails if the export produces no file (the result-label check is unchanged).
- [ ] No production path can reach the skip — it is gated on the launch argument only.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated.

## Test plan

1. `xcodebuild test -only-testing:SnappetUITests/RecapClipExportUITests` — both tests green, fast.
2. Full unit suite unchanged (the touched path is UI-test-gated).
3. CI's UI suite on the PR goes green, restoring the signal for every subsequent PR.
