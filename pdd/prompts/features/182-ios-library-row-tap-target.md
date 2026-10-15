# Prompt: Library rows open wherever you tap them (climb tap bug)

**File**: pdd/prompts/features/182-ios-library-row-tap-target.md
**Created**: 2026-10-14
**Project type**: Native iOS fix (SwiftUI) — code lands in this repo.
**Chain**: found during activity progress P4 (prompt 181); reproduced on `main` before this fix
**Context**: `pdd/context/decisions.md`

## Goal

Tapping a climb (or run) in the workout Library did nothing, so its detail — and the new "View progress" link —
were unreachable.

## Diagnosis

Instrumented the tap → `open` → `router.push` → destination path: for a strength row all four fired; for a climb row
the button action NEVER fired. `LibraryItemRow` is a `Button` with `.buttonStyle(.plain)`, under which only drawn
content hit-tests. The row is `icon · title/subtitle · Spacer()`: climb/run starters have short titles and
subtitles ("Top-rope · 5.6–5.12"), so the middle and right of the row were dead space. Strength rows only worked by
accident — their long subtitles reach across the row. Separately, the Boulder row had no icon:
`ClimbType.boulder.symbol` was `figure.bouldering`, which isn't an SF Symbol.

## Approach

- `.contentShape(Rectangle())` on `LibraryItemRow` and `LibraryRecentRow` (same shape of bug).
- Boulder symbol → `figure.climbing`.

## Acceptance criteria

- [x] `LibraryTapUITests`: a climb row opens when tapped at its centre AND on its empty right side; the climb's
      "View progress" reaches the Climbing overview.
- [x] `ClimbTypeSymbolTests`: every climb-type and discipline symbol resolves with `UIImage(systemName:)`.
- [x] SnappetTests green; GuidePhoto, WorkoutWalkthrough, ActivityProgress UI suites green.
