# Prompt: Quick Session — live climbing stats ribbon + at-logging milestones (Phase 3)

**File**: pdd/prompts/features/quick-session-redesign/03-live-stats-ribbon-milestones.md
**Created**: 2026-06-18
**Chain**: `quick-session-redesign/PLAN.md` → Phase 3 (builds on Phases 1–2)
**Context**: `pdd/context/*`; design reference is the section titled **"Climbing — live in-session stats"** in `docs/ux-research/quick-session-redesign/wireframes.md` (find by title, not number); `README.md` principles 11–12. The spec below is authoritative; the wireframe is illustrative.

## Goal

Make climbing stats **accrue live** as you log: a one-line **stat ribbon** docked above the climb cards
(sends · hardest · mini grade-pyramid) that taps to expand into a read-only **Live-stats sheet** (full
pyramid, sends/hr, projects, median time, time-on-wall, HR effort). And fire a **`CelebrationBurst`** at
the *moment* an attempt is logged for a genuine history best ("First V4!", new hardest send, flash) —
not just at session end.

## Foundation already in place (USE, don't recreate)
- `FreeformClimbStats.stats(for: session, now:)` → `KilterSessionStats` (sends, projects, attemptsOnly,
  totalAttempts, hardestSendGrade, sendsPerHour, **pyramid** `[GradeCount]`, timeline, medianTimeOnClimb)
  and `FreeformClimbStats.hasClimbing(session)`. The pyramid/timeline shapes are the SAME ones the Kilter
  board summary already renders.
- `FreeformSummary.milestones(for: session, history:)` → `[Milestone]` (personalRecord / firstSend) and
  `FreeformSummary.milestoneHeadline(_)` — the PURE milestone logic. The player already has `history`.
- `CelebrationBurst` / the `.celebrates(on:)` modifier (used on the done-screen) + `Haptics`.

## Context the implementer needs
- The canvas is the `List` in `FreeformPlayerView.swift`; climb cards render via `climbSection`. The
  ribbon docks ABOVE the climb cards (a `Section` or a row at the top of the climbing area), shown only
  when `FreeformClimbStats.hasClimbing(session)`.
- The player body re-renders on HR (~1 Hz) and on every log. `FreeformClimbStats.stats` is pure + cheap
  (small N) — computing it per render is fine; if you prefer, cache in `@State` recomputed on
  `session.exercises` change like `prefills`. Pass `now: .now` for the live "end".
- Look for an existing reusable **grade-pyramid** + **zone-bar** view in the Kilter session summary
  (`SessionDetailView.swift` / Kilter summary views) and reuse it; only build a Swift Charts `BarMark`
  pyramid if none exists. Zone colours come from `HeartRateZone.color` (the repo ramp — decisions.md).

## Approach
1. **Stat ribbon** (`freeform.statsRibbon`, a full-width tappable row): hero = `sends` ("N sends"),
   then "hardest <hardestSendGrade>" (omit until a send exists), then a small inline mini-pyramid
   (bars by grade). Before any send, show a teaching variant ("Send one to start your pyramid"). Whole
   ribbon is one 44pt tap target → presents the Live-stats sheet (`freeform.statsExpand`). Honest
   degradation: drop sends/hr for very short sessions; hide the time-on-wall row when no climb was timed.
2. **Live-stats sheet** (`.medium`/`.large`): hero tiles (Sends · Hardest · Sends/hr); full grade
   **pyramid** (easiest→hardest, hardest at apex), projects/attempts counts, median time, time-on-wall
   vs rest (only if ≥1 timed climb), and an **Effort** block (avg/max/redline + a single stacked
   zone-bar + recovery) ONLY when the session has HR (`!session.hrSeries.isEmpty`). Read-only — logging
   stays on the cards.
3. **At-logging milestones.** In the climb-logging path (`logAttempt` / the untimed outcome strip), after
   appending, recompute `FreeformSummary.milestones(for: session, history: history)` and compare against a
   `@State var celebratedMilestones: Set<...>` of already-fired ones; for each NEW milestone, fire the
   inline `CelebrationBurst` (bump a trigger used by `.celebrates(on:)`) + a success haptic, and show a
   short headline (e.g. `FreeformSummary.milestoneHeadline`). Reduce-Motion → haptic + static text only
   (the existing done-screen pattern). Fire ONLY on genuine new bests; never on every attempt.

## Output
- `FreeformPlayerView.swift` (ribbon + sheet hosting + at-logging celebration) and a
  `LiveClimbStatsSheet.swift` (new) if the sheet is substantial.
- A new unit test file if you add any pure helper (e.g. a `Set`-key for celebrated milestones — keep
  any such logic pure + tested). Otherwise extend `FreeformClimbStatsTests`/`FreeformSummaryTests`.
- `decisions.md` entry; `docs/knowledge-graph/data.js` node + edge for the live-stats surface.

## Acceptance criteria
- [ ] After logging a send, the ribbon's sends count + hardest + mini-pyramid update live; tapping it
      opens the read-only Live-stats sheet with the full pyramid (and HR effort only when HR exists).
- [ ] Logging the first-ever send of a grade (or a new hardest send) fires a celebration at that moment
      (haptic always; burst suppressed under Reduce Motion); it does NOT re-fire on later attempts.
- [ ] Ribbon hidden when there's no climbing; honest empty/early/no-HR/untimed states (no fake data).
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green.
- [ ] A climbing UITest drives: log a send → ribbon shows "1 send" → expand sheet shows the pyramid.
      (Add to `FreeformFlowWalkthroughTests` or a new `LiveClimbStatsTests`.)

## Test plan
`xcodegen generate`; `simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; then the climbing-stats UITest. Commit (changed files only) only if green; message `feat(quick-session): Phase 3 — live climbing stats ribbon + at-logging milestones`. Report files/build/tests/SHA + device-only notes.
