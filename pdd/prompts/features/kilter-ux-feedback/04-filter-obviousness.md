# Prompt: Filtering that looks filterable (chips, one Filters entry, grade range, live counts)

**File**: pdd/prompts/features/kilter-ux-feedback/04-filter-obviousness.md
**Created**: 2026-07-02
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: kilter-ux-feedback/PLAN.md → F2
**Source**: Real-user feedback: *"filtering was not obvious"* · wireframe flows F2 A/1/2/3
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make the browse screen's narrowing controls read as controls: one obvious Filters entry with a live
badge, chips that visibly open things, one grade-range control instead of a coupled Min/Max pair,
search that's always there, and live match counts on every apply.

## Context the implementer needs

The criteria were split three ways: five look-alike value chips (`Layout · Size · Angle · Min · Max`,
no ▾, no pressed affordance — the tester read them as a summary line), four more criteria behind a
toolbar funnel sitting among four other toolbar glyphs, and a search field hidden behind
`navigationBarDrawer(displayMode: .automatic)`. The Min/Max chips dragged each other's value along
via `onChange` — surprising after the fact. `KilterFilter.activeExtras` already counts the sheet
extras for a badge.

## Approach

- **Search**: `displayMode: .always`.
- **Filters entry**: the toolbar funnel moves into the chip row as the leading chip (same
  `kilter.filtersButton` id), filled + badged (`Filters · N`, N = `activeExtras` + Saved/Mine) when
  refinements are active.
- **Chip merges**: Layout+Size → one **Board** menu chip ("Original · 12 x 12"; size picker only when
  the layout offers >1, unchanged rule). Min+Max → one **Grade** chip ("V4–V7" / "Any", filled while
  narrowed) opening a new range sheet. Every menu/sheet chip carries a ▾ (`chip(chevron:)`).
- **Grade range sheet** (`KilterGradeRange.swift`): a two-thumb slider over `catalog.gradeScale()`,
  labels riding the thumbs, ends anchored; drags snap via pure `KilterGradeRange.index/fraction` and
  crossed thumbs resolve via pure `clamp` (the dragged end pushes the other, visibly, mid-drag).
  VoiceOver: each thumb is an adjustable element. Live "Show N climbs" apply (the root's `count`).
- **Filters sheet**: gains a segmented "Show only" (All / Saved / Mine — the same mutual-exclusion
  state as the pinned chips, so they can't drift) and the same live-count apply via
  `safeAreaInset(edge: .bottom)`. Reset clears Saved/Mine too. Toolbar Done keeps its id.

## Output

- `KilterRootView.swift` — searchable placement, toolbar item removal, `filterBar` rebuild +
  `refineCount`/`boardChipValue`/`gradeChipValue`/`gradeNarrowed`, `chip(chevron:)`,
  `KilterFiltersSheet` unification.
- `ios/App/Snappet/Features/Kilter/KilterGradeRange.swift` — pure rules + sheet + slider.
- `ios/App/SnappetTests/KilterGradeRangeTests.swift` — snapping/clamp rules.

## Acceptance criteria

- [ ] Search is visible without pulling down; the Filters chip badge equals active refinements.
- [ ] Board/Angle/Grade chips carry ▾; Grade fills while narrowed and its slider keeps lo ≤ hi
      through any drag (dragged end pushes the other along).
- [ ] Both sheets apply with a live "Show N climbs" count; Reset restores the full range / defaults.
- [ ] Existing ids still resolve: `kilter.filtersButton`, `kilter.angle`, `kilter.filter.done`,
      `kilter.savedToggle`, `kilter.mineToggle`.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated.

## Constraints

- The browse query surface (`KilterFilter` / `KilterCatalog.list/count`) is untouched — this is
  presentation only.
- Keep the pure slider rules Foundation-only (`nonisolated` enum) so they test with no device.

## Test plan

1. `xcodebuild test -scheme Snappet -only-testing:SnappetTests/KilterGradeRangeTests` + full suites.
2. By eye on the simulator: badge counts, chip menus, slider drags at both ends, VoiceOver steps.
