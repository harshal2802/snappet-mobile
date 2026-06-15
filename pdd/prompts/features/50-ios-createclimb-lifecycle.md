# Prompt: iOS — complete the create-a-climb lifecycle (edit / rename / delete + live grade estimate)

**File**: pdd/prompts/features/50-ios-createclimb-lifecycle.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI / SwiftData) — code lands in this repo.
**Chain**: 2026-06-09 product review → iOS tracker [#100](https://github.com/harshal2802/Snappet/issues/100), Wave 3 (Kilter polish).
**Source**: GitHub issue [#76](https://github.com/harshal2802/Snappet/issues/76)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Create-a-climb was create-only. A misplaced hold, a typo'd name, or junk generator output lived in
"Mine" forever — no edit, rename, or delete anywhere — and because the UUIDv5 content identity makes
"Save anyway" re-open the existing row, a bad climb was genuinely irreplaceable while the duplicate
checker kept nagging against it. Separately, hand-authored climbs always saved ungraded
(`predictedGrade: nil`) even though a pure on-device grade estimator already ships for the Generate
tab. Close the lifecycle and give setters difficulty feedback while they author.

## Context the implementer needs

- `Features/Kilter/CreateClimbView.swift` — create/save only; `saveManual` passed `predictedGrade: nil`;
  `commit` re-opens the existing row on a content-uuid match; the Generate tab already renders
  "Predicted …" from `KilterClimbGenerator.predictGrade` (a pure linear model over `meta.gradeModel`,
  no ONNX session needed). The hold→token vocab (`HOLD_<placementId>_<roleId>`) lives on
  `KilterGeneratorModel.stoi`.
- `Features/Kilter/KilterClimbDetailView.swift` — created climbs resolve via `createdClimb(uuid)?.asClimb`
  and render in this same screen, but only catalog-climb actions (share/favorite) existed.
- `Features/Kilter/KilterRootView.swift` — `createdListItems` Mine rows had no swipe/context actions.
- `Features/Kilter/KilterCreatedClimb.swift` — the `@Model`; `KilterLogEntry.climbName` is a **stored
  snapshot** (History reads it directly), so a deleted climb's logged ascents stay readable as orphans.
- `KilterClimbIdentity.uuid(forLayout:frames:)` is content-derived; `KilterCatalog.parseFrames` and the
  free `kilterFrames(from:)` round-trip frames ⇄ `[placementId: KilterAuthorRole]`.

## Approach

1. **Live grade estimate (manual tab).** Pure `KilterClimbGenerator.holdTokens(forAssignments:model:)`
   (maps each placed `(placementId, role)` through `stoi`, dropping out-of-vocab holds) +
   `estimateManualGrade(...)` (nil when nothing resolves). Load just the generator **meta** when already
   installed — never trigger the 9 MB download from authoring. Show an "Estimated grade ≈ Vx" chip,
   reactive to hold changes, labeled a model estimate.
2. **Edit.** `CreateClimbView` gains an `editing: KilterCreatedClimb?`: seed the manual editor from its
   holds/name/conditions (one-shot, guarding the `layoutId`-change hold-clear). On save, re-derive the
   uuid — unchanged holds update the row in place; changed holds **migrate** the climb's logged ascents
   (and its favorite) to the new identity and delete the old row. The duplicate check excludes the climb
   being edited.
3. **Rename / Delete.** From the detail screen (an ellipsis menu, created climbs only) and the Mine swipe
   actions. Delete keeps logged ascents (orphan, name-snapshot preserved), drops a stale favorite, and —
   by removing the row from Mine — frees the duplicate checker. Confirm delete, surfacing the kept-ascents
   count. One shared `KilterCreatedClimb.delete(_:in:)` so the policy can't drift between the two surfaces.

## Output

- `Features/Kilter/KilterClimbGenerator.swift` — `holdTokens` + `estimateManualGrade` (pure).
- `Features/Kilter/CreateClimbView.swift` — grade chip, `editing:` seed, edit-aware `commit` + `migrateReferences`.
- `Features/Kilter/KilterClimbDetailView.swift` — Edit/Rename/Delete menu + presenters for created climbs.
- `Features/Kilter/KilterRootView.swift` — Mine-row swipe edit/delete + delete confirm.
- `Features/Kilter/KilterCreatedClimb.swift` — shared `delete(_:in:)`.
- `SnappetTests/KilterGradeEstimateTests.swift` — pure estimator + frames round-trip coverage.
- `pdd/context/decisions.md` + `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [ ] A created climb can be renamed, re-edited (identity re-derived), and deleted; Mine reflects it.
- [ ] Deleting a climb with log entries handles them explicitly and is confirmed.
- [ ] Duplicate checker no longer traps users against climbs they deleted.
- [ ] Manual tab shows a live grade estimate when meta is installed; pure mapping unit-tested.
- [ ] Golden UUIDv5 vector still passes (cross-platform dedup with Android preserved).

## Constraints

- On-device only; no download triggered by authoring (grade estimate is meta-only, gated on installed).
- The content-uuid identity is unchanged — editing holds is, by construction, a new climb; that's why
  logs migrate rather than silently re-point an unchanged uuid.
- The Android port (PR #66) needs the same lifecycle eventually — track separately.

## Test plan

`xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,id=…iPhone 17 Pro…'` — the new
pure tests plus the existing `KilterCreateClimbTests` golden vector must stay green.
