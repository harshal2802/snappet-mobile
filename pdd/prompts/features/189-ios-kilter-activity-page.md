# Prompt: Board climbs get the Activity page (Progress · Clips · About)

**File**: pdd/prompts/features/189-ios-kilter-activity-page.md
**Created**: 2026-10-19
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData) — code lands in this repo.
**Chain**: follows Library redesign L4c (prompt 188, PR #380 — stacked on it); the Activity page is prompts 179–184
**Context**: `pdd/context/decisions.md`

## Goal

User (2026-10-19): "can we also have progress/clips/about screens for kilter climbs as well, just like the way we
have for normal climbs?" A KILTER row in Library → Yours opens the same Activity page as a gym climb.

## Approach

- Pure adapter `KilterActivityHistory.build(climbUUID:logs:sessions:media:)`: one board climb's `KilterLogEntry`s →
  transient (never inserted) `WorkoutSession`s, one per board session (ad-hoc logs per active day), each holding one
  climb entity — `exerciseId` "kilter:<uuid>", V grade, "Kilter Board" as gym, last angle as wall, the logged ascents
  as sets (outcome + attempts) — with the board session's HR; the climb's clips (`assignedClimbUUID`) re-filed to that
  entity. `ActivityIdentity.key(for:)` maps a "kilter:" entity to `kilter/<uuid>`.
- `ActivityDashboardView` reads `source` (the board history for a KILTER key, else `history`) for the dashboard,
  records, effort, clips and About — no other changes to those builders. Clips tab = the shared sheet's Kilter path.
- Bottom bar: **Open on the board** (Kilter accent) instead of Log it now / Add to routine → the catalog check + angle
  adoption (`KilterDeepLinkRouting`) → pushes the climb's Kilter page (`LibraryKilterRoute`), or explains a climb
  missing from this phone's catalog. Rename / Merge hidden (`LibraryMaintenance.canRename` false for board climbs);
  no "All climbing" link (that overview is gym climbs). About labels: "Board" / "Last angle".
- The Library row now opens the Activity page (was: the Kilter page directly, prompt 188 feedback).

## Acceptance criteria

- [x] `LibraryKilterTests`: board logs → history (sessions incl. ad-hoc day, one entity per session, grade/angle/
      outcome, HR, only this climb's clips re-filed) → identity key → `ActivityDashboard` (3 sessions, hardest send,
      📷 point); board climbs can't be renamed / merged.
- [x] `LibraryKilterUITests`: KILTER row → Progress · Clips · 2 · About + KPIs; Open on the board → (no catalog)
      explained in place / (fixture catalog) the climb's Kilter page with its 2 past clips; Clips tab "2 clips · 2
      sessions".
- [ ] Device: a real board climb's page — Progress chart over your sessions, clips, Open on the board.
