# Prompt: Design-system reset — Kilter history, session, stats & trends (prompt 228)

**File**: pdd/prompts/features/design-system/228-ios-kilter-history-stats-restyle.md
**Created**: 2026-11-04
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "looks good")**: `docs/ux-research/design-system/kilter-history-stats.html`
(before: `kilter2-before-*.png`, after: `kilter2-after-*.png`)

## Goal

Kilter part 2 (the user: "lets fix Gym leftover and kilter"). Restyle:
- `KilterHistoryView`, `KilterSessionDetailView`, `KilterStatsView`, `KilterTrendDetailView`
- the heatmap / month calendar and the grade-range sheet

It is visual only. Per the new rule, the mockup checklist lists the conditional UI: plan goals, heart rate, the
filtered ascent log, the level-change chip, the month recap, empty states and the edit sheets.

## Approach

- **Accent:** `moduleAccent("kilter")` / `SnappetColor.kilter` (amber) → the user's accent. Kilter has taken the
  user's accent since 213.
- **Panels:** surface-muted cards → `snappetPanel`. This includes the shared `ClimbGradePyramid` / effort / timeline
  containers.
- **History:**
  - sentence-case facet labels with `snappetPill` chips
  - light card facts
  - the PR / flash-rate / projects badges as outlines (were tinted fills)
  - Live in perfFresh
  - ascent status via `KilterAscentStyle.color`, so Flash is blue-green (was the same green as Sent)
- **Session detail:**
  - the six coloured metric tiles become one card with light numbers; the icons are kept, neutral except the send
    tick
  - End session is an accent outline
  - section titles are labels
- **Stats:**
  - an inline light hero (the shared `DisciplineHero` stays for share images / Clips cards)
  - one hairline-split stat card
  - light rings
  - neutral-tile trend rows with accent sparklines
  - Flash / Sent / current-max meaning colours stay
- **Contrast:** the remaining Kilter `.borderedProminent` + accent buttons use ink text. Highlight reel and the
  board-flow buttons are `SnappetWidePrimaryStyle`. The compact Set it up / Got it / Set a climb use
  `.snappetPrimary`.

## Acceptance

- [x] Affected suites: all 11 Kilter UI suites (23 tests) green. Dark screenshots match the mockup.
- [ ] Unit suite alone.
- [ ] Device: user on MrRobot.
