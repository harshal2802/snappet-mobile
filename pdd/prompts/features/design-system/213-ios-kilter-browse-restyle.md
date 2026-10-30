# Prompt: Design-system reset, step 3a — Kilter browse (prompt 213)

**File**: pdd/prompts/features/design-system/213-ios-kilter-browse-restyle.md
**Created**: 2026-10-29
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "i like it, lets implement 3a")**: `docs/ux-research/design-system/kilter-browse.html`
(+ `kilter-browse-before.png`)
**Depends on**: prompts 211 (tokens) and 212 (Home)

## Goal

Bring the Kilter browse screen (`KilterRootView`) into the calmer design system. Same features and filters;
fewer bands above the first climb; the user's accent instead of Kilter orange.

## Approach

- Title "Kilter"; toolbar unchanged (History, Create, More).
- One **board card** (`snappetPanel`, glow during a session):
  - idle: board · size · angle line (menu with Layout / Size / Angle pickers), connection state, **Start session**
    (primary) + the state's action (Connect / Cancel / Settings);
  - session: "Session · timer", climbs · sends, board label, HR pill, End; the card opens the session/plan;
  - the last-lit climb line: name → climb, ⚡ re-light, All › → On the Board.
- Chips: Filters, Grade, Mine, Saved; All / Not tried / Projects / Sent — one outlined pill style
  (`kilterPill`), accent only when selected.
- Count + Clear as a small list header. Rows: medium name, setter + status in words (✓ green, ◐ amber), plain
  grade, grey stars + compact ascents, chevron. Climb of the day = ✦ first row.
- `AppLibraryView.suiteAccentModules = ["kilter"]` → Kilter takes the user's accent.

## Acceptance

- [x] All Kilter UI test classes green (21/21) + unit suite (2631) (ids kept: `kilter.session.start/end/open/boardLabel`, `kilter.board.*`,
      `kilter.layout`, chip ids); `LibraryKilterUITests` updated for the "Kilter" title.
- [x] Dark-mode screenshots (idle, board menu, session) reviewed against the mockup; fixed a clipped Grade chip
      (one scale in the chip) and added current values to the board menu.
- [x] Installed on MrRobot; user: "looks good" (2026-10-29).
- [ ] Device: connect, start/end a session on the real board.
