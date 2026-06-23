# Prompt: HR capture fixes — stop dropping watch samples + a cadence diagnostic (Phase A / M5)

**File**: pdd/prompts/features/100-ios-hr-capture-fixes.md
**Created**: 2026-06-23
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: HR-granularity epic (99) → Phase A.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Stop losing heart-rate samples on the Apple-Watch relay, and add a pure, testable way to *measure*
the captured cadence so the rest of the epic (and the user) can tell a sparse window from a dense one.
This is the only phase that protects/measures the real captured data; everything downstream is bounded
by it.

## Context the implementer needs

- **Confirmed bug.** Watch-side `ios/App/SnappetWatch/WatchConnectivityLink.swift` `send(_:)` (line 43–50)
  calls `session.sendMessage(payload, replyHandler: nil) { _ in }` when `isReachable` — the error handler
  **discards** the failure with no fallback, so a sample sent during a transient reachability dip is lost.
  The doc-comment on `sendMetrics` even promises a `transferUserInfo` fallback the code doesn't perform.
  The **phone** side already does it right (`AppleWatchMetricsSource.send`, line 188–201: on failure it
  `queue(message)` → `transferUserInfo`). Mirror that on the watch.
- **No cadence visibility.** Nothing measures how many samples actually arrived in a window. The whole
  symptom is a cadence problem, so a pure `HRCadence` summary (count, span, samples/sec, median + max
  inter-sample gap, and an `isSparse(forWindow:)` verdict) is the diagnostic Phase B will reuse for the
  low-confidence styling, and that a debug surface can show.

## Approach

- **Watch relay fallback.** In `WatchConnectivityLink.send`, change the `sendMessage` error handler to
  fall back to `transferUserInfo(message.payload)` (mirror the phone). Keep the `else` (unreachable)
  branch as-is. Pure connectivity change; no wire-format change.
- **Pure cadence diagnostic.** Add `ios/App/Snappet/Features/WorkoutTracker/HRCadence.swift`:
  a `struct HRCadence { count, spanSec, perSecond, medianGapSec, maxGapSec }` with
  `static func summarize(_ series: [HRPoint]) -> HRCadence` and a
  `func isSparse(windowSec:minPerSecond:) -> Bool` (default thresholds documented). Foundation only →
  unit-tested in `SnappetTests`. (HRPoint lives in WorkoutModels.swift.)
- **Decisions note** on the live-session-in-feed flush gap: the Clips feed reads `hrSeries` derive-on-read
  from `@Query`; for an **ended** session `end()` has flushed everything, so the reported symptom is
  unaffected. A clip opened for a *still-live* session in the feed can read a series only as fresh as the
  last `syncLiveHR` (called on each log / on detail open). Record this as a known minor edge, not fixed
  in this phase (forcing a flush from the derive-on-read feed view is the wrong layer).

## Output

- `ios/App/SnappetWatch/WatchConnectivityLink.swift` — `transferUserInfo` fallback on `sendMessage` failure.
- `ios/App/Snappet/Features/WorkoutTracker/HRCadence.swift` — pure cadence summary + sparse verdict.
- `ios/App/SnappetTests/HRCadenceTests.swift` — count/span/perSecond/gaps + sparse/dense cases.
- `docs/knowledge-graph/data.js` — note the watch relay now has a reliable fallback; add `HRCadence`.
- `pdd/context/decisions.md` — record the watch drop fix + the live-feed flush edge.

## Acceptance criteria

- [ ] A `sendMessage` failure on the watch no longer drops the sample — it re-queues via `transferUserInfo`.
- [ ] `HRCadence.summarize` is correct on empty / single / dense / gappy series; `isSparse` flags a
      2-points-in-30s window and passes a ~1 Hz window.
- [ ] App type-checks (Swift 6, 0 warnings); `SnappetTests` green incl. `HRCadenceTests`.
- [ ] No platform imports added to `HighlightEngine`; `decisions.md` updated.

## Constraints

- On-device only; the relay fix is **device-verifiable** (needs a real watch under reachability churn) —
  flag it honestly; the cadence helper is fully unit-tested.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` (or `-only-testing:SnappetTests/HRCadenceTests`) — green.
2. Device (flagged): start a watch session, walk the phone out of range briefly, confirm the buffer keeps
   the samples (no cliff) after reconnect.
