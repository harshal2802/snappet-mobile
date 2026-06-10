# Prompt: Data backup, export, and restore — plus corrupt-store surface

**File**: pdd/prompts/features/20-ios-data-backup-export-restore.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue #68 (data-safety, P1)
**Source**: GitHub issue [#68](https://github.com/harshal2802/snappet-mobile/issues/68)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Every mini-app's data lives in a single on-device SwiftData store with no backend and no
export path. This change adds three safety layers: (1) a suite-level backup that round-trips
all schema models to a versioned JSON file via `.fileExporter` / `.fileImporter`, (2)
per-module text exports (Journal → Markdown, Budget/Expense → CSV, workout history → JSON),
and (3) a persistent visible banner when the store failed to open and the app fell back to an
empty in-memory container (currently silent — `SnappetApp.swift:45-49`).

## Context the implementer needs

- The silent fallback is in `SnappetApp.swift:45-49`: `try? ModelContainer(for: schema)` →
  else `isStoredInMemoryOnly: true`. Nothing captures the failure; the user sees a blank app.
- `SnappetSchema.models` (`SnappetCore.swift:36-48`) lists 20 `@Model` types across 8 mini-apps.
- `FeedbackStore.exportAll()` (`Core/FeedbackStore.swift:36`) is documented "export my data"
  but has zero call sites.
- `WorkoutSettingsView.swift:53` has a "Your data" section (counts only); this is the entry
  point for the new Data Management sheet.
- File-import pattern: `KilterCatalogSyncView.swift:71` — `.fileImporter` + async handler.
- `SessionMedia` and `ClipEdit` reference `PHAsset.localIdentifier` (device-specific) and are
  NOT included in the portable backup; this is noted in the bundle header.
- `StudioProject` likewise references local PHAsset identifiers; it is excluded from backup.

## Approach

**Pure layer** (`Core/DataBackup/`, no SwiftUI/SwiftData imports, fully unit-testable):
- `SnappetBackup.swift` — Codable snapshot structs mirroring each `@Model`, plus
  `SnappetBackupBundle` (versioned root with `schemaVersion: Int` and `exportedAt: Date`).
- `SnappetExporter.swift` — pure functions: `bundleJSON`, `journalMarkdown`,
  `expenseCSV`, `budgetCSV`, `workoutSessionsJSON`.
- `SnappetRestorer.swift` — pure function: `restoreBundle(from: Data)`.
- `BackupState.swift` — value-type state machine (idle / preparingBundle / bundleReady /
  restoring / restored / failed) with pure transition methods; mirrors `ExportShareState`.

**SwiftUI surface** (`Core/DataBackup/DataManagementView.swift`):
- Presented as a sheet from `WorkoutSettingsView`'s "Your data" section (and, later, any
  module's settings).
- Fetches all snapshots from the `@Environment(\.modelContext)`, builds a bundle, triggers
  `.fileExporter`; on restore reads the imported file, decodes the bundle, deletes old rows,
  and inserts new ones.
- Per-module export section: Journal Markdown, Expense/Budget CSV, Workout JSON, and the
  `FeedbackStore` JSONL (shared via share sheet).

**Corrupt-store surface** (`SnappetApp.swift` + `AppModel.swift` + `RootShell.swift`):
- `SnappetApp.init` captures `storeCorrupted: Bool` when the `else` fallback fires
  (and when `-uiTestCorruptStore` is passed) and stamps it onto `AppModel.storeCorrupted`.
- `RootShell` reads `appModel.storeCorrupted` and presents a persistent `.alert` explaining
  the situation and offering a "Restore from backup" path into `DataManagementView`.

**Knowledge graph**: add `DataManagementView` node + `BackupService` core node + links.

## Output

New files:
- `ios/App/Snappet/Core/DataBackup/SnappetBackup.swift`
- `ios/App/Snappet/Core/DataBackup/SnappetExporter.swift`
- `ios/App/Snappet/Core/DataBackup/SnappetRestorer.swift`
- `ios/App/Snappet/Core/DataBackup/BackupState.swift`
- `ios/App/Snappet/Core/DataBackup/DataManagementView.swift`
- `ios/App/SnappetTests/BackupExportTests.swift`

Modified files:
- `ios/App/Snappet/SnappetApp.swift` — capture `storeCorrupted` flag
- `ios/App/Snappet/Core/AppModel.swift` — `var storeCorrupted: Bool`
- `ios/App/Snappet/Features/Shell/RootShell.swift` — corrupt-store alert
- `ios/App/Snappet/Features/WorkoutTracker/WorkoutSettingsView.swift` — nav to DataManagementView
- `docs/knowledge-graph/data.js` — DataManagementView + BackupService nodes/links
- `pdd/context/decisions.md` — record non-obvious choices

## Acceptance criteria

- [ ] A backup file containing all schema models round-trips: write to Files, restore on a fresh store.
- [ ] Journal/Budget/Expense/workout exports produce readable Markdown/CSV/JSON.
- [ ] When `appModel.storeCorrupted == true` a visible alert appears (testable via `-uiTestCorruptStore`).
- [ ] Serialization/restore logic is pure and unit-tested in `SnappetTests` without a simulator.
- [ ] `FeedbackStore.exportAll()` is wired into the Data Management surface.
- [ ] No data leaves the device except via user-initiated Files/share actions.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated.

## Constraints

- On-device only; no backend/network/accounts.
- `SessionMedia`, `ClipEdit`, `StudioProject` excluded from portable backup (PHAsset ids are
  device-local; noted in the bundle and UI).
- State verification honestly: type-check ≠ device run for `.fileExporter` / `.fileImporter`.

## Test plan

1. `xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
   — runs `BackupExportTests` (pure serialization round-trips, state-machine transitions,
   text-format spot checks).
2. Corrupt-store banner: launch with `-uiTestCorruptStore` → alert must appear at startup.
3. Manual device: tap "Back up my data" → Files → pick the file → "Restore" → data persists
   after re-launch.
