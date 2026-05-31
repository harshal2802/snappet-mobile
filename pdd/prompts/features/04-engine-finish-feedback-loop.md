# Prompt: Finish the auto-generate-then-edit feedback loop (pin / reorder / restore)

**File**: pdd/prompts/features/04-engine-finish-feedback-loop.md
**Created**: 2026-05-30
**Project type**: Native iOS feature (Swift / SwiftUI) — engine + app. Code lands in this repo.
**Chain**: `pdd/prompts/features/PLAN-ios-to-shippable.md` → P4
**Source**: GitHub issue [#60](https://github.com/harshal2802/Snappet/issues/60) §B (auto-generate-then-edit), §E (data loop)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Complete the **auto-generate-then-edit** edit surface so the training-data loop is real. Today the
reel editor only supports **remove / regenerate / export**, but the feedback model
(`HighlightFeedbackEvent.Action`) declares `pinned`, `reordered`, `added`, `restore`-style signals
that **no UI ever fires**. The strongest positive signal — a user explicitly **pinning** a moment —
is the most valuable training signal we're currently throwing away (#60 §E). Wiring pin + reorder +
restore makes "using the app produces the dataset that optimizes the app" actually true, and gives
power users the curation the product promises (#60 §B).

## Context the implementer needs

- The reel edit screen is `ios/App/Snappet/Features/Reel/ReelView.swift` +
  `ReelViewModel.swift`. The VM already tracks a `removed: Set<String>` and logs `.removed` /
  `.kept` / `.exported` / `.regenerated` / `.shown` via `model.feedback`. It has an unused `restore`.
- Reel composition is `ios/HighlightEngine/.../ReelPlan.swift` → `ReelPlanner.plan(highlights:media:)`,
  which fills a duration budget by score then orders **chronologically**. It has no notion of a
  user-forced ("pinned") clip or a user-chosen order.
- **Layering rule** (`conventions.md`): the engine stays platform-free. Pin/order are *composition*
  inputs the app passes **into** the planner — do **not** mutate engine output structs to carry UI
  edit state.

## Approach

**Engine** (`ReelPlan.swift`):
- Extend `ReelPlanner.plan` to `plan(highlights:media:pinnedIds: Set<String> = [], order: [String]? = nil)`.
  Keep the defaults so every existing call site and test is unchanged.
  - **Pinned highlights are budget-exempt**: always include every highlight whose id ∈ `pinnedIds`
    (even if they alone exceed `targetDuration`), then fill the remaining budget with the rest by
    score (existing logic).
  - **Order**: if `order` is provided, emit segments in that id order (ids not present fall to the end
    by `atOffset`); otherwise keep the existing chronological-by-`atOffset` order.
- Do **not** add a `pinned` field to the `Highlight` struct — pin state is app/composition state, not
  algorithm output. (See decisions.md entry for this prompt for the rationale.)

**App** (`ReelViewModel.swift`):
- Track `pinnedIds: Set<String>` and an optional manual `orderedIds: [String]?`.
- `togglePin(_:)` — flips pin; pinning a removed highlight restores it; log `.pinned` when **enabling**.
- `move(from:to:)` — reorder the kept set, persist as `orderedIds`, log `.reordered`.
- Wire the existing `restore(_:)` so removed highlights can come back.
- `keptHighlights` = highlights minus `removed`, in `orderedIds` order when set (else chronological).
- `export` builds the plan via the planner with `pinnedIds` + the kept order.

**App** (`ReelView.swift`):
- Pin/unpin affordance per row (swipe action + a filled-vs-outline pin icon in the row).
- `EditButton` + `.onMove` for manual reorder of the highlights section.
- A "Removed (n)" section that lists removed highlights with a **Restore** action (only when n > 0).

**Out of scope (defer, note in decisions):** `added` (adding a moment the engine missed) needs a
media/time picker UI — track as P4b/Phase 2. "Pins survive regenerate" also deferred (regenerate
re-runs the engine with fresh ids); pins are per-generation for now.

## Output

- `ReelPlan.swift`: new `plan(...)` signature + pinned/order logic.
- `HighlightEngineTests.swift`: tests for pinned-budget-exemption and explicit-order.
- `ReelViewModel.swift`: pin/reorder/restore state + actions + feedback events; updated `export`.
- `ReelView.swift`: pin affordance, reorder (EditButton/onMove), Removed section + Restore.
- `AppModel.reelPlan(...)` updated to pass through `pinnedIds`/`order` (or VM calls the planner directly).
- `pdd/context/decisions.md`: entry recording the "pin is composition state, not on `Highlight`" choice
  and the deferral of `added` / pins-survive-regenerate.

## Acceptance criteria

- [ ] `swift test` passes, including new tests: a pinned, low-score, over-budget highlight still
      appears in the plan; an explicit `order` is reflected in segment order.
- [ ] Existing 14 tests still pass unchanged (defaults preserve behavior).
- [ ] Pinning a highlight emits exactly one `.pinned` feedback event; reordering emits `.reordered`.
- [ ] Removed highlights can be restored from the UI; pinning a removed one restores it.
- [ ] Whole app type-checks vs the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine`; `Highlight` struct unchanged.

## Constraints

- On-device only; no backend. Keep the selector pluggable; don't touch selection scoring here.
- Engine stays platform-free; pin/order flow app → planner, never the reverse.
- Be honest in commit/docs: engine behavior is unit-proven; the UI wiring is type-checked, not
  device-run (HealthKit/Photos still need a device).

## Test plan

1. `cd ios/HighlightEngine && swift test` — all tests pass (14 existing + new).
2. Type-check the app (the two `xcrun swiftc` commands in `ios/App/README.md`).
3. By inspection: pin a mid-score moment → it survives a tight budget in the plan; reorder → export
   order follows the manual order; remove then restore → returns to the kept list.
