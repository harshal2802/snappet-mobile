# Prompt: Library redesign L4c — Kilter board climbs in Yours

**File**: pdd/prompts/features/188-ios-library-kilter.md
**Created**: 2026-10-17
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData) — code lands in this repo.
**Chain**: Library redesign wireframes (`docs/ux-research/library-redesign/wireframes.html`, decision 4 B, screen 2's
"Board: Spicy Pringle · KILTER" row, §08 L4); last of L4 (186 create · 187 pickers · 188 Kilter)
**Context**: `pdd/context/decisions.md`

## Goal

Climbing in the Library covers the board too: every Kilter climb you've logged shows in Yours with a KILTER badge —
V grade, last angle, attempts, best outcome, how often — and opens in the Kilter module.

## Approach

- Pure `LibraryCatalog.kilterRows([KilterInput])` (snapshots of `KilterLogEntry`): one row per board climb uuid
  (key `kilter/<uuid>`; the catalog uuid is a stable identity, boards don't reset); sessions = board session or, for
  an ad-hoc log, its active day; best status flash > sent > project > attempt; grade = the V part of "6c/V5" so
  "Hardest" sorts board and gym climbs on one V ladder; `Row.Climb.angle` (new optional).
- `WorkoutLibraryView` queries `KilterLogEntry` and appends the rows; `LibraryYoursRow` shows the KILTER pill and
  "Kilter Board · 40° · 12 attempts".
- Tap → `router.pendingKilterClimb` (the deep-link one-shot, which lands gracefully when the climb isn't in this
  device's catalog) + push `ModuleRoute("kilter")` over the Library (Back returns). `ActivityRoute.angle` carries the
  last angle. The missing-climb alert no longer says "shared".
- `ActivityLauncher.canLaunch` is false for board climbs → not in Log it now or the pickers.
- Seed: `-uiTestSeedActivityClips` adds "Spicy Pringle" (6b+/V4, 40°, 3 sessions, sent).

## Acceptance criteria

- [x] `LibraryKilterTests`: one row per climb with best outcome + attempts + angle + sessions; latest angle/grade
      win; ad-hoc logs count by day; V-grade sort value; not launchable / not in pickers; projects/sent filters.
- [x] `LibraryKilterUITests`: the board climb is under Climbing with KILTER · 40° · 12 attempts and opens Kilter.
- [ ] Device: your real board climbs appear and open on their detail at the right angle.

## Device feedback (2026-10-18) — fixed in the same PR

1. "Tapping a Kilter climb takes me to the Kilter app first and then to the climb's page — confusing." → the Library
   now pushes the climb's page itself (`LibraryKilterRoute` → `LibraryKilterClimbView`, the module's
   `KilterClimbDetailView` with `app.kilterSessions` + its own `KilterBoardController`, which only touches Bluetooth
   on connect). The installed check + angle adoption reuse the pure `KilterDeepLinkRouting.destination`; a climb not
   in this phone's catalog is explained in the Library.
2. "I can't see the way to unhide the hidden Kilter climb." → the only way back was a toggle inside the sort menu.
   Yours now ends with a visible "Show N hidden" row (`library.showHidden`); when shown: "Swipe a dimmed one left to
   unhide it." `LibraryKilterUITests.testHideABoardClimbThenBringItBack` covers the round trip.
