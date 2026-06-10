# Prompt: Data backup, export, restore — and surface the silent corrupt-store fallback

**File**: pdd/prompts/features/34-data-backup-export-restore.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: PLAN-ios-to-shippable.md → data-safety
**Source**: GitHub issue [#68](https://github.com/harshal2802/snappet-mobile/issues/68)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Every module (journal, workouts, budgets, habits, Kilter, etc.) lives in a single on-device
SwiftData store with no backup or export path. If the store silently falls back to an empty
in-memory container, the user sees a blank app with no explanation and all changes evaporate
on relaunch. This prompt ships:

1. **Suite-level backup/restore**: all SwiftData models → versioned JSON via `.fileExporter`; restore via `.fileImporter`.
2. **Per-module exports**: Journal → Markdown, Budget/Expense → CSV, Workouts → JSON.
3. **Corrupt-store banner**: capture the fallback flag in `SnappetApp.init()`, surface it as a persistent `FallbackStoreBanner` in `RootShell`, testable via a launch arg.

## Context the implementer needs

- `SnappetApp.swift:42-50` — silent `try? ModelContainer` → in-memory fallback. No flag, no alert.
- `SnappetCore.swift:36-48` — `SnappetSchema.models`: the full list of types at risk.
- `AppModel.swift` — add `isUsingFallbackStore: Bool = false` here; set it in `SnappetApp.init()`.
- `FeedbackStore.swift:36` — `exportAll()` exists; its file URL is accessible via `fileURL`.
- `KilterCatalogSyncView.swift:71` — `.fileImporter` pattern to reuse.
- `ExportShareState.swift` — pure state machine pattern to follow for `DataBackupPhase`.
- `HomeDashboardView.swift` — top-level screen on the Home tab; add backup toolbar button here.

All `@Model` types require DTO structs for serialization — the `@Model` macro is not Codable-compatible.

## Approach

- **`DataBackupService`** (enum, static methods): pure DTO types (`*Backup` structs), `serialize(context:)`,
  `restore(from:into:)`, and format-specific export helpers. `@MainActor` on methods that touch
  `ModelContext`; format helpers are pure.
- **`ExportDocument: FileDocument`**: wraps `Data` for `.fileExporter` — one type handles all formats.
- **`DataBackupView`**: `Form`-based sheet with "Back up all data", "Restore from backup", and four
  per-module export rows. Launched from a toolbar button on `HomeDashboardView`. Single `.fileExporter`
  + single `.fileImporter` modifier (configured by the active action).
- **`FallbackStoreBanner`**: shown as an `.overlay(alignment: .top)` in `RootShell` when
  `app.isUsingFallbackStore`. Dismissable; "Restore" opens `DataBackupView`.
- **`DataBackupPhase`**: pure state enum (`.idle/.busy/.done(String)/.failed(String)`) — testable
  without a device, mirrors `ExportShareState`.

## Output

| File | Action |
|------|--------|
| `ios/App/Snappet/Services/DataBackupService.swift` | New — DTOs + serialize/restore/export logic |
| `ios/App/Snappet/Features/Shell/DataBackupView.swift` | New — UI sheet + `FallbackStoreBanner` |
| `ios/App/SnappetTests/DataBackupTests.swift` | New — pure unit tests |
| `ios/App/Snappet/Core/AppModel.swift` | Add `isUsingFallbackStore: Bool = false` |
| `ios/App/Snappet/SnappetApp.swift` | Capture fallback flag; add `-uiTestSimulateFallbackStore` arg |
| `ios/App/Snappet/Features/Shell/RootShell.swift` | Add `FallbackStoreBanner` overlay |
| `ios/App/Snappet/Features/Home/HomeDashboardView.swift` | Add archivebox toolbar button |
| `docs/knowledge-graph/data.js` | Add `data-backup-view`, `data-backup-service`, `fallback-store-banner` nodes + edges |
| `pdd/context/decisions.md` | Record DTO approach and restore semantics |

## Acceptance criteria

- [x] A backup file round-trips: `serialize(context:)` → JSON → `restore(from:into:)` rebuilds all models
- [x] Journal/Budget/Expense/Workout per-module exports produce non-empty, correctly-formatted output
- [x] `FallbackStoreBanner` is shown when `isUsingFallbackStore == true`; hidden for normal launches
- [x] `-uiTestSimulateFallbackStore` forces the in-memory path and sets the flag
- [x] `DataBackupPhase`, DTO round-trips, and all format helpers are unit-tested in `DataBackupTests`
- [x] No data leaves the device except via user-initiated `.fileExporter`/share actions
- [x] `decisions.md` updated with the DTO mapping and restore-as-full-replace choice
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings) — requires macOS/Xcode

## Constraints

- On-device only; no backend/network/accounts.
- `@Model` types are NOT `Codable` — DTOs are required for serialization.
- Restore = full replace (delete all + insert from bundle); no upsert/merge.
- `schemaVersion: 0` is the initial schema; future changes must increment this and add a migration path.

## Test plan

1. `swift test` in `ios/HighlightEngine` — engine is unchanged (no tests to break there).
2. `DataBackupTests` — run in `SnappetTests` on the simulator; covers round-trip JSON,
   Markdown/CSV/JSON format, `DataBackupPhase` equality. No device or context needed.
3. Launch with `-uiTestSimulateFallbackStore` — verify `FallbackStoreBanner` appears.
4. Launch normally — verify banner is absent, backup toolbar button is present on Home tab.
5. Full round-trip (device/simulator): tap "Back up all data" → save to Files → "Restore from backup"
   → select file → confirm → verify data re-appears. Requires a real or simulated SwiftData store.
