# Prompt: Design-system reset, step 3b — Kilter climb page restructure + session clips (prompt 214)

**File**: pdd/prompts/features/design-system/214-ios-kilter-climb-restructure.md
**Created**: 2026-10-29
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "looks good")**: `docs/ux-research/design-system/kilter-climb.html` (v2 + edits: one climb
card, Light above Log, session videos + Tag clips sheet; board photo = later PR)
**Depends on**: prompt 213 (#406)

## Goal

Restructure `KilterClimbDetailView` into the calm style **without dropping anything** (the checklist in the
mockup maps every element), and add "Videos from this session" with tag / find for the climb on screen.

## Approach

- Order:
  1. Session strip (HR + plan ‹ Plan · n/N · Next pick ›).
  2. Board (role colours + shapes; legend + position on one line; pill restyled).
  3. Off-board note.
  4. **Climb card**: name, Set by · FA, Grade with the angle chip | Quality + ascents, tags (Matching ⓘ, Classic,
     ▶ past clips = `activity.pastClips`).
  5. **Board** card: Light up / every state + share countdown + Set up · Wrong holds (size + Standard/Legacy) ·
     Disconnect.
  6. **Log this climb**: 2×2 outlined (send green, project/attempt amber), confirmation + auto-session Undo.
  7. **Videos from this session**: during a session.
  8. Grade by angle.
  9. Beta row.
- `KilterSessionClips.swift`:
  - pure `KilterClipTagging` (filters, Done diff);
  - `KilterStudioProjects.resolve` (moved from the session page, shared);
  - `KilterTagClipsSheet`.
- `KilterStyle.swift`: `kilterPill` shared (+ a meaning `tint`).
- Fix: grade-by-angle bars start at the domain floor + clipped (they overflowed before).

## Acceptance

- [ ] `KilterClipTaggingTests` + unit suite green.
- [ ] Kilter UI classes + `LibraryKilterUITests` + `ActivityProgressUITests` (past clips id) green.
- [x] Dark screenshots: top (session strip, board, climb card), log card, session videos, tag sheet, chart.
- [ ] Device: real board states, a session with real clips → tag / find / edit.
