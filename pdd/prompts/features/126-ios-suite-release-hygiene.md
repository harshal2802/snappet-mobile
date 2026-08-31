# Prompt: Suite release hygiene — honest counts, current privacy strings, dead code out

**File**: pdd/prompts/features/126-ios-suite-release-hygiene.md
**Created**: 2026-08-30
**Project type**: Native iOS chore (Swift / SwiftUI) — code lands in this repo.
**Chain**: release-readiness review 2026-08-30 → suite-level findings (P4 of 4 fix PRs)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Close the small suite-level findings before release: copy that lies, privacy strings that
predate two whole mini-apps, and the only two genuinely dead types in the codebase.

## Context the implementer needs

- `HomeDashboardView`'s first-run hero says "Or browse all **9** apps" — `ModuleRegistry.all`
  has 10 (Wardrobe and Festival landed after the copy).
- `NSCameraUsageDescription` lists workout clips / receipts / Kilter QR, but not wardrobe
  garment capture or the festival poster scan; `NSPhotoLibraryUsageDescription` doesn't mention
  wardrobe imports. The strings' one job is honesty about why access is requested.
- A type-level liveness sweep over all 785 top-level types found exactly two with no references
  anywhere: `EntityRollupChip` (`EntityCard.swift`) and `WorkoutStatCard`
  (`WorkoutDashboardSection.swift`, whose own comment says "retained for any callers" — there
  are none). The two ~25-line wrapping-chip layouts (`FlowLayout` in Journal, `FlexibleHStack`
  in Wardrobe) were deliberately NOT unified: both are private, tiny, and a shared DesignSystem
  API is more surface than the duplication costs.

## Approach / Output

- `HomeDashboardView.swift`: derive the count — `"all \(ModuleRegistry.all.count) apps"`.
- `Resources/Info.plist`: extend the camera + photo-library strings (wardrobe capture, poster
  scan, wardrobe imports; keep the everything-on-device framing).
- Delete `EntityRollupChip` and `WorkoutStatCard`.

## Acceptance criteria

- [ ] The hero count can never drift again (derived from the registry).
- [ ] Privacy strings name every camera/photo surface that exists today.
- [ ] The two dead types are gone; nothing references them (build proves it).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).

## Constraints

- Copy-and-deletion only — no behavior changes.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`.
2. `SuiteSmokeTests` UI slice (the first-run hero renders on a fresh store).
