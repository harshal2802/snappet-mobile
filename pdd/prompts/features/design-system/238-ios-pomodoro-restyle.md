# Prompt: Design-system reset — Pomodoro (prompt 238)

**File**: pdd/prompts/features/design-system/238-ios-pomodoro-restyle.md
**Created**: 2026-11-05
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved)**: `docs/ux-research/design-system/small-apps.html` (Pomodoro section; before:
`small-before-pomodoro-*.png`)

## Goal

Restyle Pomodoro (small apps 2/6, stacked on 237). It is visual only: ids, the timer engine and notifications are
unchanged.

## Approach

- **Colour:**
  - Focus takes the user's accent (was tomato). Break stays green (`perfFresh`, meaning rest).
  - One `PomodoroRootView.tint(for:)` drives the ring, the phase pill and the live chip.
  - Pomodoro joins `suiteAccentModules`.
- **Timer:**
  - The ring is 10 pt on a hairline track (was 18 pt on a tinted track).
  - The countdown is light (was semibold rounded).
  - The phase pill is a hairline outline (was frosted material).
- **Controls:** Start / Pause are `SnappetWidePrimaryStyle`; Reset is a matching neutral outline.
- **Today:** sessions and minutes sit in one panel with `SnappetMetric` (were two tiles with red icons). "No focus
  sessions yet" is a calm panel.
- **Chart:**
  - Thin accent bars, with short hairline stubs on empty days.
  - The y-scale is at least 0–25 min, so an empty week stays short.
  - A sentence label (was red bars + headline).
- **Live chip:** ink on the phase colour (was white on red / green).
- **History:** the row icon is grey and minutes are regular weight.

## Acceptance

- [x] Affected suites: `PomodoroUITests` 3/3. As built matches the mockup.
- [ ] Unit suite alone (once for the stack).
- [ ] Device: user on MrRobot (batch).
