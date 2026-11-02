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
- **Fix.** Fact plurals read "1 set", "1 send", "1 climb" (were "1 sets" / "1 sends").

## Acceptance

- [x] `WorkoutDashboardUITests`: sections present, See all → History; dark screenshots reviewed.
- [x] `RecentSessionsTests` + a singular-set case.
- [ ] Full UI + unit suites.
- [ ] Device.
