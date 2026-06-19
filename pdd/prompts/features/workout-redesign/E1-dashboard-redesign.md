# Prompt: E1 — Dashboard redesign (discipline-aware home + recent-sessions feed)

**File**: pdd/prompts/features/workout-redesign/E1-dashboard-redesign.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `workout-redesign/PLAN.md` → E1 (wave 1; depends on E0)
**Design**: `docs/ux-research/workout-redesign/README.md` §4 (Dashboard); `wireframes.html` Flow 1
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`

## Goal

Rebuild the Gym-Tracker dashboard so it surfaces **what you actually did** across every discipline, in the
Pulse Pro language. Today it is strength-only (volume/PRs read reps×weight, so a climb/run/timed session
shows 0 and the chart hides) and there is **no recent-sessions surface at all** — a finished session is
invisible unless it has a video.

## Context the implementer needs

- `Features/WorkoutTracker/WorkoutDashboardSection.swift` is the surface; it's fed plain arrays/closures from
  `WorkoutHomeView` (`WorkoutTrackerModule.swift:237-269`). It owns no `@Query`.
- Strength-bias: `WorkoutMath.sessionVolumeKg` is reps×weight-only (`WorkoutProgress.swift:106-107`); PRs sort
  by `bestKg*bestReps` (`:297`); the chart is hidden for all-zero histories (`:47`). The resume banner
  hard-codes "sets logged" + a run icon (`:74-78`).
- E0 shipped `WorkoutDashboardStats`, `DisciplineHero`, `StatRibbon`, `GlassChrome`, and the perf ramp — use
  them. `WorkoutDiscipline` + `SessionExercise.discipline` are populated for freeform sessions; routine
  sessions derive `.strength` (handle that cleanly).
- `StudioEntry.candidates` (`StudioEntry.swift:29-50`) is the recent-session pattern to generalize — drop the
  video-only filter (`:33`) so non-video sessions appear. Per-discipline summaries reuse
  `FreeformSummary`/`StrengthStats`/`RunStats`/`FreeformClimbStats`.
- Do **not** duplicate the suite Home tab's cross-app feed (`HomeDashboardView`/`TodayDigest`) — the module
  dashboard is rich *within* the gym tracker.

## Approach

In `WorkoutDashboardSection`, top→bottom: (1) a conditional **Resume** card (the one coral-fill moment),
discipline-aware (active session's dominant discipline glyph + correct vocabulary); (2) one **hero stat** via
`DisciplineHero` (a coral ring around active-days-this-week or sessions-this-week) + a per-discipline
`StatRibbon` ("2 lifts · 5 climbs · 1 run"); (3) a calm 7-day consistency strip (today in coral, "You're on
track"); (4) a persistent **type-aware Start** CTA (label reflects the dominant recent discipline); (5) a
**Recent sessions** feed — the last 3–5 completed `WorkoutSession`s as mixed-type cards (discipline accent
edge-bar + glyph + a type-adaptive 3-fact rollup + optional coral PR pill) deep-linking to `SessionRoute`;
(6) keep the Video Studio card + Reels cross-link. All stats from `WorkoutDashboardStats`.

## Output

- A rebuilt `WorkoutDashboardSection` (+ a `RecentSessionCard`); thread the extra `@Query`/derived data
  through `WorkoutHomeView` as needed.
- A pure `recentSessions` selector (type-adaptive rollup per session) with tests.
- Discipline-aware resume copy/icon.

## Acceptance criteria

- [ ] A finished climbing/running/timed session appears in the recent feed with the right hero fact (sends /
      distance·pace / TUT), not "0 kg".
- [ ] The hero + ribbon + recent rollups come from pure, tested selectors (no inline view math).
- [ ] Resume banner shows the active session's discipline glyph + correct vocabulary.
- [ ] Deep-linking a recent card opens `SessionRoute`; the empty/first-run state matches Flow 1B.
- [ ] App type-checks (Swift 6, 0 warnings); UI suite green (new a11y ids documented).

## Constraints

- On-device only. Don't redefine "volume" — *add* discipline-aware metrics rather than changing the strength meaning.
- Don't duplicate the suite Home feed; reuse `TodayDigest.resumeWorkout` semantics where sensible.

## Test plan

1. `SnappetTests` for the recent-session selector + dashboard stats; `xcodebuild build` green.
2. UITest: a mixed history renders the feed + deep-links; empty state renders the chooser.
3. Eyeball Flow 1 (A populated dark / B empty light) against the build.
