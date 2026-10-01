# Prompt: Progression P4 — buddy widgets (Home Screen + Lock Screen)

**File**: pdd/prompts/features/152-ios-progression-p4-widgets.md
**Created**: 2026-10-01
**Project type**: Native iOS feature (Swift / SwiftUI / WidgetKit) — code lands in this repo.
**Chain**: session-progression — 148 P1 → 149 P2 → 150 Home → 151 P3 → **152 P4 widgets**
**Design**: `docs/ux-research/progression/wireframes.html` frame 11 (approved "as drawn")

## Goal

Your buddy on the Home Screen and Lock Screen: level, mood, streak and what's up next.

## Approach

- Widgets can't run RealityKit, so the buddy is a **pre-rendered still** per stage × mood (5 × 5 = 25,
  `SnappetWidgets/BuddyStills.xcassets`, 360 px, ~760 KB). They're rendered from the app's real 3D buddy:
  `-buddyStillStudio` puts the Labs screen on the widget's exact background with no idle animation;
  `BuddyStillRenderTests` (skipped unless `TEST_RUNNER_RENDER_BUDDY_STILLS=1`) captures each one and
  `scripts/buddy-stills.py <xcresult>` writes the asset catalog. Re-run both when the buddy's look changes
  (or a new style arrives).
- `Shared/BuddyWidgetSnapshot` (+ `BuddyWidgetStore`, App Group JSON, versioned codec) — stage, level, XP,
  Form + mood, pause, hatched, streak, freezes, up next with its likely XP. Built by
  `WidgetSnapshotService.buddySnapshot` from the same `ProgressionSnapshot` Home uses, written on every
  foreground / background with the Today snapshot (never under UI tests).
- `BuddyWidget`: small (buddy, level, mood, streak, XP bar), medium (+ Form %, freezes, up next ≈ XP),
  Lock Screen rectangular (level, mood, streak, XP gauge) and circular (level gauge). Unhatched → egg.

## Acceptance criteria

- [x] `BuddyWidgetSnapshotTests` (4): still names for every stage × mood (bands match the buddy's moods),
      unhatched = egg, codec round-trip + future-version rejection, built like Home.
- [x] 25 stills rendered and checked (corners match the widget ground exactly).
- [ ] Device leg: add the widgets on MrRobot; they update after a workout / a pause.
