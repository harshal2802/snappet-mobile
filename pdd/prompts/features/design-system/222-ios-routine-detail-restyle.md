# Prompt: Design-system reset, step 3e — Gym Tracker routine detail (prompt 222)

**File**: pdd/prompts/features/design-system/222-ios-routine-detail-restyle.md
**Created**: 2026-11-02
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement")**: `docs/ux-research/design-system/routine-detail.html`
(before: `routine-before-*.png`, after: `routine-after-*.png`)

## Goal

The first Gym Tracker inner screen: restyle `RoutineDetailView`. Every element keeps its place and behaviour (the
checklist is in the mockup).

## Approach

- **Background:** the List sits on paper; sections are on the card surface.
- **Schedule card:**
  - a neutral calendar tile and a 15 medium title
  - the grey summary and a tertiary reminder line
  - `ScheduleDayDots`: accent-filled scheduled days, regular weight (were orange / bold)
  - the paused and Not scheduled states stay, and it still opens the editor
- **Description:** grey body text.
- **Blocks:**
  - The header ("N blocks · N sets" + discipline glyphs) is a grey sentence-case label.
  - `RoutineBlockRow` gets a neutral glyph tile (was a discipline-accent edge bar + glyph) and a medium name.
  - Prescription and rest share one grey line ("4 × 6 · 60 kg · rest 2m 30s"); notes are tertiary italic.
  - The row is shared with `RoutineEditorView` and `RoutineImportSheet`, so they match.
- **About:** a grey label over one card.
  - Sport is an HStack: `LabeledContent { Label }` grew the row into a tall empty card.
- **Schedule editor's `WeekdayPicker`** (user on device: "calendar shows orange"): selected days use the screen's
  `.tint` with `onBrand` text, regular weight. It was a fixed workout orange. The Habits editor shares it and keeps
  its own tint.
- **Start Workout:** `SnappetWidePrimaryStyle` on paper (was orange `.borderedProminent` on `.bar`). It dims while
  disabled.

## Acceptance

- [x] Dark screenshots match the mockup (scheduled routine, starter routine with About).
- [x] Full UI suite: the only failure left is the known `525 kg` test. Timed-set record and Tip preset failed in the full
  run and pass alone. RoutineSchedule / Habit / WorkoutPause re-ran green after the picker fix. Unit suite alone:
  2653 green.
- [x] Device: user on MrRobot 2026-11-02. The user caught the orange weekday picker in the schedule editor (fixed:
  "fixed.").
