# Prompt: Per-layout board-size memory (fix "resets board to 12 x 14")

**File**: pdd/prompts/features/kilter-ux-feedback/01-per-layout-size-memory.md
**Created**: 2026-07-02
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: kilter-ux-feedback/PLAN.md → F3
**Source**: Real-user feedback: *"resets board to 12x14"* · wireframe flow F3
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Stop the app from silently resetting the user's physical board size. The size choice must survive
layout switches, app relaunches, and transient catalog reloads; the only legitimate reset is a
catalog swap that genuinely removed the size — and that case gets a visible notice.

## Context the implementer needs

The size is ONE global `@AppStorage("kilter.productSizeId")`, and both `KilterRootView.syncBoardSize()`
and its Settings twin overwrite it with `catalog.defaultSizeId(forLayout:)` — the **lowest**
`product_size_id`, which for the user's layout is the "12 x 14" — whenever the stored value isn't
valid for the *current* layout. That guard fires on every layout switch AND on every appear while the
catalog can't list sizes yet (an empty size list fails the `contains` check), so browsing another
layout — or a slow reload — destroys a deliberate choice.

## Approach

Add `KilterSizeMemory` (Features/Kilter): a `UserDefaults`-backed map `layoutId → product_size_id`
(the `KilterBoardMemory` pattern — injectable defaults, no `@Model`), plus a pure, `nonisolated`
resolution rule `choose(remembered:current:available:)`:

- `available` empty → `nil` = leave the selection alone (the transient-reload fix),
- remembered-and-offered wins (returning to a layout restores *its* size),
- else a still-valid current carries over,
- else the layout default — the one legitimate reset.

`syncBoardSize()` in the root and Settings routes through `choose`; every valid size selection
(chip pick, Settings pick, board-memory restore) is recorded via an `onChange` hook /
`applyRestore`. The legacy global key stays as "the size in effect" for render/LED paths. A lost
remembered size surfaces the root's transient bottom notice. `applyRestore` mirrors a recognized
board's size into the map *before* the layout-change sync runs, so a P1 restore can't be overridden
by an older per-layout memory.

## Output

- `ios/App/Snappet/Features/Kilter/KilterSizeMemory.swift` — store + pure `choose`.
- `KilterRootView.swift` / `KilterSettingsView.swift` — `syncBoardSize()` rewrites + record hooks.
- `ios/App/SnappetTests/KilterSizeMemoryTests.swift` — pure rule + persistence + the reported
  regression as a round-trip test.

## Acceptance criteria

- [ ] Pick 12×12 on Original → browse another layout → return: 12×12 is restored, not 12×14.
- [ ] Appear/reload with the catalog unreadable never changes the stored size.
- [ ] A catalog swap that removed the remembered size falls back to the default AND shows a notice.
- [ ] A P1 board-memory restore's size wins over the layout's older remembered size.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated.

## Constraints

- On-device only; `UserDefaults`, no new SwiftData schema.
- The pure rule stays `nonisolated` + Foundation-only so it tests with no device.

## Test plan

1. `xcodebuild test -scheme Snappet -only-testing:SnappetTests/KilterSizeMemoryTests` (macOS + sim).
2. By hand on device: the round-trip above; kill the app between steps to prove persistence.
