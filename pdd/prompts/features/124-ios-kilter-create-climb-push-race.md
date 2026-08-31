# Prompt: Kilter — created climb reliably opens (dismiss+push race)

**File**: pdd/prompts/features/124-ios-kilter-create-climb-push-race.md
**Created**: 2026-08-30
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: release-readiness review 2026-08-30 → Kilter findings (P2 of 4 fix PRs)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Saving a new climb should always land on that climb's detail screen. Today
`CreateClimbView` calls `onCreated(uuid)` — whose host closures do
`router.push(KilterClimbRoute(uuid:))` — and then `dismiss()` in the same transaction. Dismissing
a presentation and mutating the navigation path in one mutation is the documented SwiftUI drop
hazard this repo has hit three times (festival prompts 05/06's two-sheet races; the player's
`onViewDetail`, which defers its push one runloop tick for exactly this reason,
`WorkoutTrackerModule.swift` ~227). The result is an intermittently ignored push: the sheet
closes and nothing opens.

## Context the implementer needs

Three hosts present `CreateClimbView`; two of them push on create:

- `KilterRootView` (`showingCreate` sheet): `onCreated: { router.push(KilterClimbRoute(uuid:)) }`
- `KilterCreatedView` (`showingCreate` sheet): same closure
- `KilterClimbDetailView` (remix): mutates only local state — no push, not affected. The edit
  sheets (`onCreated: { _ in }`) are also unaffected.

The repo's established cure is **stash and promote in `onDismiss`** (`pendingIncoming` /
`pendingPosterDraft` in `FestivalRootView`, `pendingSource` in `WardrobeCaptureSheet`).

## Approach

In each affected host: add `@State private var pendingCreatedOpen: String?`; the sheet's
`onCreated` only stashes the uuid (CreateClimbView still dismisses itself); the sheet's
`onDismiss` promotes the stash into `router.push(KilterClimbRoute(uuid:))`. No change to
`CreateClimbView` itself.

## Output

Changed: `KilterRootView.swift`, `KilterCreatedView.swift`. No schema, no engine, no new strings.

## Acceptance criteria

- [ ] Creating a climb from browse (+) and from Your Climbs ("Set a climb") opens its detail
      every time — the push happens only after the sheet is fully gone.
- [ ] The duplicate-detected path ("Open existing") routes the same way.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated (the rule is now a named pattern, not folklore).

## Constraints

- Pure presentation-ordering fix — no behavior change beyond the push reliably landing.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` (no logic change expected to move it).
2. Kilter XCUITest slices for the two touched screens (`KilterUITests`,
   `KilterCreatedGalleryUITests`) — no existing test walks create→save→detail (that flow needs an
   installed catalog), so this fix's positive path is a device/sim manual check.
3. By eye in the sim: create → save → detail opens; repeat several times (the race was
   intermittent).
