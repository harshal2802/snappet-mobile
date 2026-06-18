# Prompt: Quick Session — type-adaptive completion summary + polish (Phase 7)

**File**: pdd/prompts/features/quick-session-redesign/07-type-adaptive-summary-polish.md
**Created**: 2026-06-18
**Chain**: `quick-session-redesign/PLAN.md` → Phase 7 (final; builds on Phases 1–6)
**Context**: `pdd/context/*`; design reference (by title) `docs/ux-research/.../wireframes.md`: **"Session completion summary (type-adaptive)"**.

## Goal

Finish the redesign: a **type-adaptive completion summary** (climbing → sends pyramid + hardest +
time-on-wall + timeline; timed → hold-time + per-exercise breakdown; strength → volume + PRs), plus the
remaining polish — **remembered rest timers** and **recent-gym** chips — so the branch is a coherent,
device-testable whole.

## Context the implementer needs
- The completion screen is `FreeformPlayerView.doneScreen` (today: a seal, milestone headline, and three
  `statCell`s Duration/Sets/headline). Upgrade it to a scrollable, type-adaptive recap. The dominant kind
  is `FreeformSummary.dominant(for:)`.
- Reuse what exists: `FreeformClimbStats.stats(for:)` (pyramid/hardest/sends-hr/time-on-wall/timeline,
  with HR effort when `session.hrSeries` is non-empty), the grade-pyramid + zone-bar views (reuse the
  Kilter session summary's if present — Phase 3 likely already located/added them), `FreeformSummary`
  (volume, PRs, hold-time), `CelebrationBurst`.
- `StopwatchView`/`StopwatchViewModel` (count-down) + the command bar for the rest timer.

## Approach
1. **Type-adaptive `doneScreen`** (scroll; pinned hero + bottom action bar):
   - Hero strip (3 cells) adapts: climbing = Sends · Hardest · On-the-wall(time); timed = Hold time ·
     Best · Sets; strength = Volume · Sets · PRs. Honest degradation (no per-climb timing → "Climbs" not
     "On the wall"; no HR → omit the Effort card).
   - Climbing: full **grade pyramid** + sends/hr · median · tries + **timeline** (top N, expandable) +
     **Effort** zone-bar (only with HR). Timed: **per-exercise** rows (name · sets · TUT · best). Strength:
     **PRs** list + per-exercise volume.
   - Keep the milestone seal/headline + `CelebrationBurst`; keep Done / View detail / Keep going /
     Discard. If clips exist, keep the existing "Turn N clips into a reel" Studio CTA.
   - All figures from the pure `FreeformSummary` + `FreeformClimbStats` — no model migration.
2. **Remembered rest timer**: after completing an attempt/set, optionally auto-start a count-down rest
   timer shown non-blocking in the command bar (reuse `StopwatchViewModel(.countDown)` + `Haptics` at
   zero). Remember the duration per climb-type / per-exercise via a small pure default
   (`RestTimerDefaults`, unit-tested) + `@AppStorage`. Make it opt-in/dismissable; don't block logging.
3. **Recent gym chips** in `AddClimbSheet` (recents persisted in `@AppStorage`, like recent grades) so a
   gym is one tap, never re-typed.
4. (If not already done in Phase 4) ensure **route grade pills** use a cool tint and **scale toggle**
   (V↔Font / YDS↔French) sticks per type via `@AppStorage`.

## Output
- `FreeformPlayerView.swift` / a new `FreeformDoneSummaryView.swift` for the adaptive recap.
- `RestTimerDefaults.swift` (pure) + tests; `AddClimbSheet.swift` (recent-gym chips).
- `decisions.md` entry; `docs/knowledge-graph/data.js` node/edge for the redesigned summary.

## Acceptance criteria
- [ ] Finishing a climbing session shows the sends pyramid + hardest + (when timed) time-on-wall +
      timeline + (when HR) zone-bar; a timed session shows hold-time + per-exercise; strength shows
      volume + PRs. No fake data in degraded states.
- [ ] Completing an attempt/set can auto-start a remembered rest count-down in the command bar.
- [ ] Recent-gym chips in Add-a-climb.
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green
      (incl. `RestTimerDefaultsTests`).
- [ ] The freeform walkthrough UITest still passes end-to-end (climb → attempts → finish → summary).

## Test plan
Build + `test-without-building -only-testing:SnappetTests`; run `FreeformFlowWalkthroughTests`. Commit (changed files only) only if green; message `feat(quick-session): Phase 7 — type-adaptive completion summary + rest timers + polish`. Report files/build/tests/SHA + device-only notes.

## After Phase 7 (for the orchestrator)
Run the FULL suite once: `build-for-testing` then `test-without-building -scheme Snappet` (all SnappetTests + the freeform/climb/timed UITests) on a fresh sim, so the branch is verified device-testable end-to-end.
