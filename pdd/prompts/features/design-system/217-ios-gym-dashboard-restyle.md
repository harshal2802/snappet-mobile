# Prompt: Design-system reset, step 3d — Gym Tracker Dashboard (prompt 217)

**File**: pdd/prompts/features/design-system/217-ios-gym-dashboard-restyle.md
**Created**: 2026-11-01
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement")**: `docs/ux-research/design-system/gym-dashboard.html`

## Goal

Restyle the Gym Tracker Dashboard (`WorkoutDashboardSection`). Every element keeps its place and behaviour
(checklist in the mockup). Library, Routines and History follow, one PR each.

## Approach

- **Module colour.** The Gym Tracker joins `AppLibraryView.suiteAccentModules`: the user's accent replaces the
  workout orange (toolbar ⚙︎ ⚡, controls).
- **Week card.** Label + `SnappetMetric` (N days), streak line, discipline counts as outlined pills, the 7-day
  dots in the accent. Was tracked CAPS + coloured capsules.
- **Buttons and rows.**
  - Start = the wide filled accent button.
  - Plan a session = a panel row.
  - Resume banner = an accent-glow panel with a Resume pill.
  - Empty state = accent primary + outline pill.
- **Recent sessions.** One card of rows: neutral glyph tile, title, outlined PR tag, facts as one grey line, date.
  The coloured edge-bar and fact capsules go.
  - **"See all ›" now opens History.** Its action was empty: a dead button.
- **Weekly volume.** This week's total as a metric, thin bars, this week in the accent. Was orange.
- **Personal records / Quick start / Video Studio.** Panel rows; values in ink; "Open in Studio" in the accent.
- **Fix.** Fact plurals read "1 set", "1 send", "1 climb", "1 game" (were "1 sets" / "1 sends" / "1 games").
- **Fix (user, on device: "recent sessions is not showing sessions i did with quick session").**
  - `WorkoutDashboardStats.dominantDiscipline` had no `.racket` in its order, so racket matches and drills (Quick
    Sessions) got nil. They were dropped from Recent sessions and from the week's counts.
  - `displayOrder` now includes racket.
  - Recent sessions caps *after* skipping empty sessions, so it still fills to 5.
- **Fix (user: "weekly volume is kinda look weird").** On an empty new week the card read "0 lb" over all-grey
  bars.
  - `volumeFocus` features this week once it has volume, else last week (labelled "last week").
  - Other weeks draw in a soft accent, not near-invisible hairline grey.

## Acceptance

- [x] `WorkoutDashboardUITests`: sections present, See all → History; dark screenshots reviewed.
- [x] `RecentSessionsTests` (+ singular set, empty sessions don't eat a slot) and `WorkoutDashboardStatsTests` (+ racket counted, volume focus this/last week).
- [ ] Full UI + unit suites.
- [ ] Device.
