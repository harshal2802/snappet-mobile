# Prompt: Design-system reset, step 3d — Gym Tracker session detail (prompt 220)

**File**: pdd/prompts/features/design-system/220-ios-session-detail-restyle.md
**Created**: 2026-11-02
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved)**: `docs/ux-research/design-system/session-detail.html` (before: `session-before-*.png`,
after: `session-after-*.png`)

## Goal

Restyle a finished session's detail (`SessionDetailView` + `SessionInsightsViews` + `SessionRecap` + the XP row).
Every element keeps its place and behaviour (the checklist is in the mockup).

## Approach

- **Background:** the List sits on `paper`, and every section row is on `surface`. The top cards line up with the
  section cards (zero row insets).
- **XP row** (`SessionXPRow`):
  - The 3D `BuddyCreatureView` becomes the still `BuddyWidgetSnapshot.imageName` avatar, as on Home. The 3D one
    rendered blank on the simulator and cost a RealityKit scene per page.
  - "+195 XP" is a light metric.
- **Header:** a grey subtitle line, then outlined chips. "On plan" stays green.
- **Stats:** the stat tiles become one panel with three columns split by hairlines and light numbers. Deltas use
  meaning colours: green is better, amber is worse, grey is the same. `SessionInsightsStyle` holds these rules.
- **Badges:** "This session earned" is a sentence-case label. The badge cards are neutral and their icons use the
  accent; the brown / blue / orange fills are gone.
- **Accent:** the progress line + point, the milestone thin bar, the exercise sparklines, the force-grid fills and
  the grade-pyramid bars. The best-ever rule stays a dashed green line.
- **Per-set change chips:** outlined; gains are green, losses amber.
- **Heart rate & effort:** an icon row with an "avg · max" subtitle and a rotating chevron. Its expanded stats use
  light numbers. HR zone colours stay.
- **Photos & videos** (when there's no media yet): outline Find / Add pills and an accent Settings link.
- **Exercise headers:** 13.5 medium ink, with accent Progress and ⋯ icons.
- **Set rows:** regular weight; the HR pill is outlined in its zone colour. The Move swipe uses the accent.
- **Shared cards that move with it:**
  - `SessionRecapHero` / `SessionRecapCards`: also on the finish screen.
  - `ClimbSummarySectionTitle`, `ClimbEffortSection`, `ClimbTimelineList`: also on the finish screen and the live
    climb sheet.
- **Not touched:**
  - `ClimbGradePyramid` (the Kilter stats screen's chart).
  - `RacketRecapCards`.
  - The finish screen's `SessionXPCard`.

## Acceptance

- [x] Dark screenshots match the mockup (strength top / compare / sets; climbing; hangboard).
- [x] Full UI suite: green except the known `525 kg` main failure, an interval flake (passes alone) and
  `BuddyPrototypeUITests.testPreviewTheMoments`, which fails on main too (af8010e). Unit suite alone: 2653 green.
- [x] Device: user on MrRobot 2026-11-02 ("merge after testing").
