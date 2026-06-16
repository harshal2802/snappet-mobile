# Prompt: Persist the Kilter planned session (KilterPlan + KilterPlanItem)

**File**: pdd/prompts/features/kilter-planned-session/01-persisted-plan-model.md
**Created**: 2026-06-16
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: kilter-planned-session/DESIGN.md → PR 01 (P0, keystone)
**Source**: User UX report (four Kilter plan disconnects); see DESIGN.md
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make the planned session a **persisted, frozen-on-Start entity with per-pick state**, decoupled from
the volatile `KilterRecommender` output. This is the keystone every other PR in the feature stacks on:
it is what lets a completed Send/Project pick stay ticked (instead of being filtered out and reshuffled
on the next log), and what gives the run a stable home to return to. This PR is pure model + logic +
tests — no UI wiring yet (PR 02 consumes it).

## Context the implementer needs

- Today the plan is ephemeral `@State` in `KilterPlanView` recomputed via `.task(id: planKey)`; "done"
  is re-derived by `loggedThisSession` (`logs ∩ currentId`). See DESIGN.md for the full defect trace.
- `KilterSession`/`KilterLogEntry` (`KilterModels.swift`) and `KilterSessionManager`
  (`KilterBoardController.swift`) have **no** plan concept.
- `KilterLogEntry` has no stable UUID id — plan-item completion is resolved by `climbUUID`, not a log id.
- Embedded Codable arrays on an `@Model` are the established pattern (`KilterSession.hrSeries:
  [HRPoint]`), so `KilterPlan.items: [KilterPlanItem]` keeps this to **one** new `@Model` + a trivial
  lightweight migration.
- Adding a `@Model` requires registering it in `SnappetSchema.models` (`SnappetCore.swift`) **and**
  adding a `BackupRow` in `SnappetBackup.swift` — `SnappetBackupTests.testCodecCoversEverySchemaModel`
  and the record-count round-trip are tripwires.

## Approach

- New `ios/App/Snappet/Features/Kilter/KilterPlanLogic.swift` (Foundation-only, no SwiftData):
  `KilterPlanItemStatus`, `KilterPlanItem` (Codable value), `KilterPlanProgress` pure namespace.
- `KilterPlan` `@Model` added to `KilterModels.swift` (embedded `items: [KilterPlanItem]`, `sessionId`,
  `completedAt`, options snapshot).
- Register `KilterPlan.self` in `SnappetSchema.models`; add `KilterPlanRow` + File/snapshot/restore/
  recordCount wiring in `SnappetBackup.swift`.
- Tests in `ios/App/SnappetTests/KilterPlanLogicTests.swift`.
- Knowledge graph: add `kilter-planned-session` node + edges in `docs/knowledge-graph/data.js`.

## Output

- `KilterPlanLogic.swift` — status enum, item value type, `KilterPlanProgress` (`items(from:)`,
  `applyingLog`, `progress`, `nextPending`, `skipping`, `allResolved`).
- `KilterPlan` `@Model` in `KilterModels.swift`.
- Registration + backup edits in `SnappetCore.swift` / `SnappetBackup.swift`.
- `KilterPlanLogicTests.swift` incl. the send/project "stays done, no reshuffle" regression test.
- Graph node + edges; `decisions.md` entry.

## Acceptance criteria

- [ ] `applyingLog` flips the lowest-order pending item for a climb to `sent`/`attempted`; an off-plan
      climb leaves the plan unchanged; a later send upgrades an `attempted` item to `sent`.
- [ ] A sent Send/Project pick remains present and `.sent` (regression test asserts count + order
      unchanged) — the original defect cannot recur in the persisted model.
- [ ] `KilterPlan` registered in schema + covered by `SnappetBackup` (backup tests green).
- [ ] App target type-checks (Swift 6, 0 warnings); `SnappetTests` green on the simulator.
- [ ] No platform imports in `KilterPlanLogic.swift` (Foundation only); no `HighlightEngine` change.
- [ ] `decisions.md` records: plan persisted + frozen on Start; done-state from `PlanItem.status`;
      completion keyed by `climbUUID` (no log id); items embedded Codable (not a relationship).

## Constraints

- On-device only; additive migration (existing stores decode with zero plans).
- Pure logic stays SwiftData-free so it runs in `SnappetTests` without a simulator.

## Test plan

1. `cd ios/App && xcodegen generate` then
   `xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:SnappetTests/KilterPlanLogicTests -only-testing:SnappetTests/SnappetBackupTests`.
2. Eyeball the regression test: sending a Project pick keeps it in the list, ticked.
