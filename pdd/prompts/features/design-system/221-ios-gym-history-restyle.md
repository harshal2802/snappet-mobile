# Prompt: Design-system reset, step 3d — Gym Tracker History (prompt 221)

**File**: pdd/prompts/features/design-system/221-ios-gym-history-restyle.md
**Created**: 2026-11-02
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement")**: `docs/ux-research/design-system/gym-history.html`
(before: `history-before-*.png`, after: `history-after-*.png`)

## Goal

Restyle the History section (`HistorySectionView` + `HistoryFilterSheet` + both row types), the last Gym Tracker
section. Every element keeps its place and behaviour (the checklist is in the mockup).

## Approach

- **Rows** take the Dashboard's Recent sessions shape, so a session reads the same wherever it's listed. One
  private `HistoryRowShape` lays out both row types:
  - a glyph tile for the session's workout type (`WorkoutDashboardStats.dominantDiscipline`)
  - a medium name and a grey facts line
  - the date in tertiary text underneath
  - "+XP" in grey; Studio / Clips as a small accent tag
- **Facts lines:**
  - Tracked: "50 min · 10 sets · 2,520 kg". It was icon labels; now "1 set" is singular.
  - Imported: "Apple Watch · 31 min · 5.1 km · 320 kcal". The source leads, and the glyph follows the real writer
    (⌚ or the Health mark).
- **Sections:** sentence-case month labels, rows on the card surface over the paper background.
- **Filter bar:** an outline "Filters" pill that is the accent while filtering, with the count in an accent dot. A
  grey count line; the bar sits on paper (was `.bar`). Tokens are accent outline pills.
- **Filter sheet:**
  - on the card surface: the outline chips vanished against the system sheet material
  - sentence-case labels (were tracked caps)
  - outline chips that turn the accent when on
  - an accent "Show N sessions" button
- **Empty state** "Clear filters" and the Studio swipe use the accent.

## Acceptance

- [x] Dark screenshots match the mockup (list, filtering + sheet).
- [ ] Full UI suite, then the unit suite separately.
- [ ] Device: user on MrRobot.
