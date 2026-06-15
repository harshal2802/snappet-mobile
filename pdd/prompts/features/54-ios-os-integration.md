# Prompt: Open Snappet to the OS — App Group + widget snapshot read path (Phase 1 of 4)

**File**: pdd/prompts/features/54-ios-os-integration.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → OS integration (iOS)
**Source**: GitHub issue [#81](https://github.com/harshal2802/snappet-mobile/issues/81)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The suite has zero presence outside its own UI: the widget bundle vends only Live Activities, there
are no home-screen widgets, no Siri/Shortcuts intents, and nothing in Spotlight. Issue #81 fixes this
in four stacked PRs (widgets → intents → Spotlight), and the first thing every later phase needs is a
**place both the app and the widget extension can read the same data** — today the SwiftData store
lives in the app's *private* container and the entitlements grant HealthKit only.

This Phase 1 PR builds that foundation: an **App Group** and a small, versioned, read-only **snapshot**
the widget extension reads. We deliberately chose the snapshot over moving the live SwiftData store into
the App Group (see Approach + decisions.md): the snapshot keeps the widget completely isolated from the
frequently-bumped `SnappetSchema`, needs no store-location migration, has no cross-process SQLite
locking, and is entirely unit-testable without a device. The actual Today widget UI and the interactive
check-off (which writes back through an App-Group outbox reconciled by the app) land in Phase 2 on top of
this read path.

## Context the implementer needs

- **No App Group today.** `Snappet/Resources/Snappet.entitlements` has HealthKit keys only;
  `project.yml`'s `Snappet` target declares those same keys under `entitlements.properties` (XcodeGen
  writes the .entitlements file from `properties` on generate — keep both in sync). The `SnappetWidgets`
  app-extension target has **no** `entitlements:` block at all yet.
- **The store is private.** `SnappetApp.init` builds `ModelContainer(for: Schema(SnappetSchema.models))`
  in the default (app-private) location. `SnappetSchema.models` is 22 `@Model` types and grows often —
  a strong reason to keep the widget off it.
- **The Today facts already exist as pure functions.** `Features/Home/TodayDigest.swift`
  (`habitsToday`, `focusToday`, …) and `Features/Habit/HabitMilestones.swift` (`streak(days:today:)`)
  are pure, clock-injected, and unit-tested. The snapshot builder is just these functions serialized —
  no new derivation logic, no drift from what Home/Habit show.
- **The `Shared/` path is compiled into both the app and the widget extension** (project.yml: both
  targets list `- path: Shared`). The Live Activity contracts (`PomodoroActivityAttributes`, …) live
  there for exactly this reason — the snapshot contract + the App-Group store key belong there too.
- `WidgetCenter` (WidgetKit) lives in the **app** target to nudge a reload after a snapshot write; it is
  a no-op when no widget is installed (true through all of Phase 1, since the widget UI is Phase 2).

## Approach

**Decision — snapshot, not the live store in the App Group.** Recorded in decisions.md. Rationale:
isolate the widget from `SnappetSchema` churn (the schema bumps almost every PR); no irreversible
store-location migration; no two-process SQLite locking; pure/testable. The cost — the widget reflects
data as of the last snapshot write, and a widget-originated mutation reconciles into the canonical store
on next app open — is acceptable and is handled in Phase 2 via an App-Group outbox.

1. **App Group entitlement** `group.com.snappet.app` on the **app** and the **`SnappetWidgets`** targets
   — `project.yml` `entitlements.properties` for both, the app's `Snappet.entitlements`, and a **new**
   `SnappetWidgets/SnappetWidgets.entitlements`. Never the generated `.xcodeproj`.
2. **`Shared/SnappetWidgetSnapshot.swift`** — a versioned `Codable`/`Sendable`/`Equatable` value type:
   `version`, `generatedAt`, `dayStart`, `[HabitItem(id,name,symbol,doneToday)]`, `dayStreak`,
   `focusMinutesToday`, with computed `habitsRemaining`/`habitsTotal`. Resilient decode
   (`decodeIfPresent` + defaults; reject a `version` newer than this binary understands) — the repo's
   migration-safe Codable discipline, so a widget reading a snapshot written by an older app build can't
   crash.
3. **`Shared/WidgetSnapshotStore.swift`** — the one place that knows the App-Group id
   (`group.com.snappet.app`) and the file name. A **pure** `encode`/`decode` pair (unit-tested) plus a
   thin file edge (`containerURL` → atomic write/read of the JSON). Returns `nil` cleanly when the
   container is unavailable (e.g. entitlement not provisioned) or the file is absent/corrupt.
4. **`Snappet/Widgets/WidgetSnapshotBuilder.swift`** — **pure** `build(habits:completions:focusSessions:
   now:calendar:) -> SnappetWidgetSnapshot`, reusing `TodayDigest.focusToday` + `HabitMilestones.streak`
   (best current per-habit streak = the flame value users already see). Unit-tested in `SnappetTests`.
5. **`Snappet/Widgets/WidgetSnapshotService.swift`** — `@MainActor` thin service: fetch the three row
   types from a `ModelContext`, call the builder, `WidgetSnapshotStore.write`, then
   `WidgetCenter.shared.reloadAllTimelines()`. Device-dependent edge → not unit-tested.
6. **Wire on `scenePhase`** in `RootShell` (it owns `modelContext`): refresh on first core build and on
   `.active`/`.background`. Per-mutation refresh calls (habit toggle, focus complete) land with the
   widget UI in Phase 2; scenePhase is enough to prove the read path now.

## Output

- `ios/App/project.yml` — App Group in the `Snappet` target's `entitlements.properties`; a new
  `entitlements:` block (path + property) on `SnappetWidgets`.
- `ios/App/Snappet/Resources/Snappet.entitlements` — add `com.apple.security.application-groups`.
- `ios/App/SnappetWidgets/SnappetWidgets.entitlements` — **new** (app-group only).
- `ios/App/Shared/SnappetWidgetSnapshot.swift` — **new** snapshot contract.
- `ios/App/Shared/WidgetSnapshotStore.swift` — **new** App-Group codec + file edge.
- `ios/App/Snappet/Widgets/WidgetSnapshotBuilder.swift` — **new** pure builder.
- `ios/App/Snappet/Widgets/WidgetSnapshotService.swift` — **new** fetch+write+reload service.
- `ios/App/Snappet/Features/Shell/RootShell.swift` — scenePhase refresh wiring.
- `ios/App/SnappetTests/WidgetSnapshotTests.swift` — **new** codec round-trip, builder-from-rows,
  back-compat (missing keys → defaults; future version rejected).
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md` — same change.

## Acceptance criteria

- [ ] `group.com.snappet.app` is present in the app's and the widget extension's entitlements after
      `xcodegen generate`; the existing app/watch/widget targets still build + embed.
- [ ] A `SnappetWidgetSnapshot` round-trips through `WidgetSnapshotStore.encode`/`decode`; a payload
      missing newer keys decodes with defaults; a payload with a higher `version` is rejected (→ `nil`).
- [ ] `WidgetSnapshotBuilder.build` reproduces `TodayDigest`/`HabitMilestones` facts (habits-remaining,
      best streak, focus-minutes-today) for representative row sets — verified in `SnappetTests`.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings); full simulator suite green.
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` records the snapshot-over-live-store choice + the App-Group device-pending class.

## Constraints

- On-device only; no backend/network/accounts. The snapshot is a local file in the App-Group container.
- Keep `HighlightEngine` platform-free. The snapshot contract + store live in `Shared/`; the only
  platform I/O (the App-Group container URL + file write) sits behind `WidgetSnapshotStore` /
  `WidgetSnapshotService` so the builder + codec stay pure and testable.
- Verify honestly: the App-Group container fully provisions only on a **device** (the group id must be
  registered under the signing team in the portal). The simulator doesn't enforce it, so unit tests +
  target builds verify what's verifiable now; record App-Group-on-device as device-pending.

## Test plan

1. `cd ios/App && xcodegen generate` clean; the app/widget/watch targets build (`build-for-testing`).
2. Unit (simulator): `WidgetSnapshotTests` — codec round-trip, missing-key/future-version back-compat,
   builder-from-rows parity with `TodayDigest`/`HabitMilestones`.
3. Full simulator suite green (no regression in the existing Live Activity / Today paths).
4. Device-pending: the App-Group container resolving + the widget reading the snapshot on hardware
   (lands with the Phase-2 widget UI).
