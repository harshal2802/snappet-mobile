# Prompt: Apple Watch workouts → Clips — surfaces (P3)

**File**: pdd/prompts/features/watch-workouts-clips/P3-surfaces.md
**Created**: 2026-07-10
**Chain**: watch-workouts-clips/PLAN.md → P3 (depends on P1)
**Context**: `pdd/context/{project,conventions,decisions}.md`

## Goal

Make watch imports legible across the surfaces the wireframe promised: a ⌚ source pill in Clips, a
dedicated "From Apple Watch" section in the Workout app, and an honest exercise-less session detail.

## Decisions folded in

- The "From Apple Watch" list lives **in the Workout app** (user pick) — the History screen, its own
  section, kept OUT of the tracked-gym `history` (which feeds set-based analytics/plan/dashboard/Studio).
- Watch workouts **do** count toward activity streaks (user pick) — no change needed; the Recap streak
  reads the raw `WorkoutSession` @Query, not the filtered `history`.

## Approach / touched

- `WorkoutTrackerModule`: `history` now excludes watch imports (leak guard — else empty exercise-less
  rows pollute the tracked list + analytics); new `watchSessions` computed passed to History.
- `HistorySectionView`: a "From Apple Watch" `Section` (shown when not filtering/searching the tracked
  list) of `WatchHistoryRow`s (⌚ + activity + duration/distance/energy/clips), same `SessionRoute` detail.
- `SessionDetailView`: a `watchSourceSection` when `session.isFromAppleWatch` — the honest "recorded on
  Apple Watch, no exercises/sets" note + measured distance/energy chips. The existing HR chart (guarded on
  non-empty `hrSeries`, which watch anchors have) + General media bucket carry the rest.
- `ClipFeedComposer`/`ClipsFeedView`: `isFromAppleWatch` threaded through the pure composer → the poster
  header shows a ⌚ "Apple Watch" pill + the perf-green source tint/`applewatch` glyph.
- `WorkoutSession` gains `hkEnergyKcal`/`hkDistanceMeters` (additive optionals, set on mint, backed up)
  for the detail/row stats.

## Acceptance criteria

- [x] Watch imports appear only in the "From Apple Watch" section, never in tracked history/analytics.
- [x] Their detail shows the note + HR + clips + distance/energy; no broken empty exercises UI.
- [x] Clips posters for watch imports show the ⌚ pill + green source tint.
- [x] App builds; full unit suite green (composer flag-propagation test added).
- [ ] Device leg: eyeball the section/detail/pill with a real watch workout + clips.
