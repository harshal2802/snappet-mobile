# Prompt: Protocol editor + hangboard presets

**File**: pdd/prompts/features/140-ios-protocol-editor-presets.md
**Created**: 2026-09-30
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: hangboard-protocols — 139 → **140 protocol editor + presets** → 141 tap-done reps → 142 load + hands → 143 mid-run adjust → 144 any-frequency → 145 force sensor
**Design**: `docs/ux-research/hangboard-protocols/wireframes.html` frames 1, 10, 10B–C (approved)

## Goal

Users asked for Max hangs / Endurance repeaters / Abrahangs. The timing model could hold them, but
the form fixed rest between sets at 3 min, used ±1 s steppers (120 taps for 2 min), dropped the
get-ready countdown, and a protocol couldn't be edited once saved or inside a routine.

## Approach

- Pure: `TimedExerciseSpec.maxHangs / enduranceRepeaters / abrahangs`, `sentence` (plain-English
  summary), `DurationStep` (1 s / 5 s / 15 s / 1 min by size), `ProtocolDraft` (every field incl. rest
  between sets + lead-in), `ProtocolCopies` (unchanged routine copies of a preset).
- One editor (`ProtocolEditorSections`) used by Create-new (pinned live summary on top, pinned Add
  button — the longer form pushed it off-screen), `ProtocolEditorSheet` for editing a saved preset
  (swipe / long-press in the pick list) and **Edit protocol** on a routine block (+ "Save as my preset").
- Editing a preset offers **"Update routines too?"** for routine blocks that are still identical copies;
  customised copies are never touched. Routine blocks stay copies (QR-safe).
- Presets join the timed suggestions (after Free hold); routine rows + the block editor show the sentence;
  runner "1266s left" → "21:06 left".
- Deviation from the wireframe: no separate "Hangboard" discipline tab — the presets live under Timed,
  category Hangboard, where the library already groups them (a new discipline is a far larger change).

## Acceptance criteria

- [x] Max hangs / Repeaters 10:6 / Abrahangs presets fill every field exactly; summary reads back.
- [x] Rest between sets and get-ready countdown are editable; 2 min is a few taps.
- [x] Edit a saved preset; unchanged routine copies can be updated in one tap; tweaked ones are left.
- [x] Edit protocol inside a routine block; its sets live inside the protocol (runs once).
- [x] `HangboardProtocolTests` (11); `StructuredIntervalRunnerTests.testMaxHangsPresetAndEditableRestBetweenSets`; existing timed UI tests green.
