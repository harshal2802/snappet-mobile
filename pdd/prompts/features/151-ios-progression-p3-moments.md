# Prompt: Progression P3 — level-up & growing-up moments, XP on session detail and history

**File**: pdd/prompts/features/151-ios-progression-p3-moments.md
**Created**: 2026-10-01
**Project type**: Native iOS feature (Swift / SwiftUI / RealityKit) — code lands in this repo.
**Chain**: session-progression — 148 P1 → 149 P2 → 150 Home → **151 P3** → P4 widgets
**Design**: `docs/ux-research/progression/wireframes.html` frames 2, 3, 10 (approved "as drawn")

## Goal

Make the big moments feel big, and show what every past session earned.

## Approach

- Pure `Progression.moment(before:after:celebrated:)`: crossing a level → level-up; crossing into a new
  stage → growing up. `celebrated` (highest level already celebrated, `BuddyDefaults`) makes each level
  celebrate once; never celebrated → the backfilled level counts as seen, so history never triggers one.
- `ProgressionMomentView` (full screen, from the finish screen ~1.4 s after the XP card's cheer):
  level-up = cheering buddy, "Level 13", sessions · all-time XP, next growth bar; growing up = one buddy
  that grows from the old stage into the new one with a cheer, "Sprout → Adult", what's new (`BuddyStage.unlocks`).
- `SessionXPRow` at the top of a session's detail: still buddy at the level it reached, "+187 XP",
  "Level 12 · on plan · Bench PR · 5-week streak". History rows show "+N XP".
- `ProgressionSnapshot.ledger(_:routines:)`: one way to get the ledger outside Home (same schedules +
  pauses) so the per-session XP cache is shared instead of recomputed.
- Labs: "Preview level-up" / "Preview growing up" to see both moments without levelling.

## Acceptance criteria

- [x] `ProgressionMomentTests` (7): level-up, grew up, none, once per level, history never triggers,
      unlocks per stage, short detail reasons.
- [x] `BuddyPrototypeUITests.testPreviewTheMoments` (both moments, screenshots checked);
      `SessionInsightsUITests` asserts the detail's XP line.
- [ ] Device leg: a real level-up after finishing a session; how fast a second 3D view draws (the
      simulator takes a few seconds to draw a second full-screen RealityView).
