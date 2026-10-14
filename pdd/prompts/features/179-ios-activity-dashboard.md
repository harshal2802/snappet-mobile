# Prompt: Activity progress P2 — a dashboard for every activity

**File**: pdd/prompts/features/179-ios-activity-dashboard.md
**Created**: 2026-10-13
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: activity-progress ideation (`docs/ux-research/activity-progress/ideation.html`, §05 screen D, §06, §08 P2);
builds on prompt 178
**Context**: `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Give each activity its own dashboard where the progress chart and the clips are linked: a hero metric over time,
KPI tiles, records (each playable when that session was filmed), frequency, and a clips filmstrip.

## Approach

- Pure `ActivityDashboard.make(key:history:media:unit:now:calendar:)` — the hero metric adapts to the discipline
  (strength est. 1RM via Epley or max reps when bodyweight · climb hardest send · timed longest hold · run pace,
  lower is better · dance/other total time); KPIs (best + % change from the first session, sessions + per-week over
  8 weeks, last done + week streak); records tied to their session; 18-week frequency.
- `ActivityDashboardView` (Swift Charts): points from filmed sessions are larger, brand-coloured and carry a 📷;
  tapping the chart selects the nearest session and offers "Play clip". Records with a clip show its poster and play it.
- `ActivityRoute(key:title:)`; `ProgressRoute` now renders the dashboard too, so the library's "View progress" and the
  dashboard's progress links upgrade. `ExerciseProgressView` is deleted (its job is a subset of this).
- Session detail exercise headers get a progress (chart) button next to the past-clips chip.

## Acceptance criteria

- [x] `ActivityDashboardTests` (Epley, bodyweight, pace direction, climb sends only, clip flags, week counts/streak).
- [x] UI test: session detail → dashboard → chart tap → Play clip → viewer; record with a clip → viewer.
- [x] Knowledge graph + decisions updated.
- [ ] Device: real data looks right for strength, a named climb, a timed hang and a run.
