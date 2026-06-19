# Prompt: Workout-Type Parity — cross-type clip menu (Phase 6, media half)

**File**: pdd/prompts/features/workout-type-parity/06-cross-type-media-menu.md
**Created**: 2026-06-19 · **Chain**: `workout-type-parity/PLAN.md` → Phase 6
**Context**: `pdd/context/*`; design README §5 (Media), wireframe steps 11–13

## Goal
Complete media parity: the deep-tap clip move/remove/delete menu was climb-only; wire it on every
discipline with discipline-aware copy. (The capture + auto-assignment pipeline is already kind-blind.)

## Approach
- Generalize `climbClipMoveTargets(for:)` → `clipMoveTargets(for:)` titling by discipline noun
  ("Attempt N" climb / "Leg N" run / "Set N" strength/timed/dance/other).
- `SetMediaStrip` gains a `moveTargetsLabel` param (default keeps the climb wording); thread it through
  the `ClipContextMenu` modifier + label.
- Wire `moveTargets` + `moveTargetsLabel` + `onReassign` + `onRequestDelete` on the strength + run per-set
  strips (was onEdit-only). `reassignClip` is already discipline-agnostic (keyed by exerciseID+setIndex).
- Update `ClipMoveTargetTests` to the new name + discipline-noun coverage.

## Output
`SessionMediaAssignment.swift` · `SetMediaStrip.swift` · `FreeformPlayerView.swift` · `ClipMoveTargetTests.swift`.

## Acceptance
- [ ] Build clean; ClipMoveTargetTests (Attempt/Leg/Set nouns) + unit suite green; climb clip behavior unchanged.

## Deferred — the analytics half of Phase 6 (separate follow-up)
Pure `StrengthSessionStats`/`RunSessionStats`/`TimedSessionStats` (mirroring `FreeformClimbStats`) → a live
stats RIBBON for all disciplines + a MIXED-session roll-up summary + cross-type milestones (e1RM PR /
longest hold / farthest-fastest run). The completion-summary headline already type-adapts (P0). Also the
"Remove from attempt" clip-menu wording stays climb-worded (functionally correct). And the cross-cutting
items: watch `HKWorkoutActivityType` per discipline, the saved-session `SessionDetailView` SetTileRow
second kind-switch, the `HistorySectionView` discipline facet, the `SnappetBackup` golden + Android
`BackupRoundTripTest`, and the Android wave.
