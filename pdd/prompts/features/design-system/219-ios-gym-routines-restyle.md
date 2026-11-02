# Prompt: Design-system reset, step 3d — Gym Tracker Routines (prompt 219)

**File**: pdd/prompts/features/design-system/219-ios-gym-routines-restyle.md
**Created**: 2026-11-02
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement")**: `docs/ux-research/design-system/gym-routines.html`

## Goal

Restyle the Routines section (`RoutinesSectionView` + `RoutineUpNextCard`). Every element keeps its place and
behaviour (checklist in the mockup).

## Approach

- **Up next card** → `snappetPanel(glow:)`. Was an orange gradient card with a blue ▶ inside an orange Start.
  - Sentence-case kicker: "Up next · Today 7:00 AM", "· 2 of 7".
  - Name 18 semibold.
  - Wide accent Start; Skip today / Skip this one as outline pills (they still show only on the day).
  - Week strip cells show the routine's initials ("SK") — the first word crowded the cell on device (user).
  - Week strip: done = filled accent ✓, planned = accent outline, missed = amber (was coral, which is now the
    accent), skipped / none = muted.
- **Rows** (`RoutineRow`): neutral glyph tile (list.bullet when no sport), medium name, outlined `ScheduleChip`,
  grey "N exercises · N sets · level", tertiary first-three exercises. On the card surface.
- **Sections:** "My routines" / "Starter routines" (sentence case).
- **Accent:** the Start swipe and the empty-state button.
- **Wording:** "1 exercise · 1 set" via `RoutineRow.summary`. Was "1 exercises · 1 sets". The Up next card's
  "1 block · 1 set" too.
- **Tests:** `RoutineScheduleUITests` updated for the sentence-case kicker ("Today", "Tomorrow", " of 7").

## Acceptance

- [x] `RoutineRowSummaryTests`; `RoutineScheduleUITests` (4) green; dark screenshots match the mockup.
- [x] Full UI 160/167 — only the known `525 kg` main failure + a Household power-hour flake (passes alone); unit 2648 green incl. initials.
- [x] Device: user on MrRobot — week strip crowded "Sudarshan" → initials; missed stays amber (user: "keep it as it is").
