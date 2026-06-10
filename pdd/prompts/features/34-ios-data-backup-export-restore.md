# Prompt: Data backup, export, and restore + corrupt-store alert

File: pdd/prompts/features/34-ios-data-backup-export-restore.md
Created: 2026-06-10
Project type: Native iOS feature (Swift / SwiftUI)
Chain: Data safety (standalone)
Source: GitHub issue #68
Context: project.md, conventions.md, decisions.md, schema.md

## Goal

Every module — journal, budgets, expenses, habits, workout history (incl. HR series),
Studio projects, Kilter logs and created climbs — lives in a single on-device SwiftData
store with no backend. There is currently no way to export, back up, or restore any of it.
Worse: if the store fails to open the app silently falls back to an empty in-memory
container with no user-visible indication.

This prompt implements:

1. **Suite-level backup**: serialize `SnappetSchema.models` (all 18 types) to a versioned
   JSON file via `.fileExporter`; matching restore via `.fileImporter` (additive import,
   existing rows kept).
2. **Per-module exports**: Journal → Markdown, Budget → CSV, Expense → CSV,
   workout history → JSON.
3. **Corrupt-store banner**: capture a `storeFailedToOpen: Bool` flag in `SnappetApp.init()`
   when the in-memory fallback fires; show a persistent `CorruptStoreBanner` overlay
   (non-dismissable) with a "Restore backup…" CTA.

## Context the implementer needs

- `SnappetApp.swift:42-50` — `try? ModelContainer` with silent in-memory fallback. No flag
  captured, no UI shown. Fix: detect the fallback, stamp `AppModel.storeFailedToOpen = true`
  before body renders.
- `Core/SnappetCore.swift:36-48` — `SnappetSchema.models`: all 18 types are the backup contract.
- `Core/FeedbackStore.swift` — JSONL file pattern (per-thread queue, Application Support dir);
  the backup engine is analogous but works at a higher abstraction (DTO layer + `Codable`).
- `Features/Kilter/KilterCatalogSyncView.swift:71` — `.fileImporter` pattern to reuse for restore.
- `Features/WorkoutTracker/WorkoutSettingsView.swift:53` — "Your data" section; entry point for
  the new `DataManagementView`.

## Approach

### Layering (respects the layering rule)

```
SnappetBackupPayload.swift  ← pure DTOs (Codable structs), no SwiftData import
SnappetBackupEngine.swift   ← pure logic (serialize/deserialize + text formatters), no platform imports
SnappetDataService.swift    ← platform service (fetches @Model objects, calls engine, writes files)
DataManagementView.swift    ← SwiftUI UI (.fileExporter + .fileImporter + per-module export)
CorruptStoreBanner.swift    ← SwiftUI persistent banner (shown when storeFailedToOpen)
```

### Backup format

Versioned JSON: `SnappetBackup { schemaVersion: 1, exportedAt: ISO8601, ... }`.
All 18 model types represented as plain `Codable` DTO structs (one per model, field-for-field).
Complex nested `Codable` composites (`HRPoint`, `ReceiptItem`, `TextOverlay`, etc.) are
preserved as-is; `StudioProject`/`ClipEdit` complex fields (`clips`, `overlays`, etc.) are
embedded as JSON blobs within the DTO.

PHAsset `localIdentifier`s (on `SessionMedia` and `ClipEdit`) are preserved in the backup
but are device-specific — they point at the local Photos library and won't resolve on a
different device. The data is preserved; the bytes travel with the device backup, not this file.

### Restore semantics

Additive import (not a wipe-and-replace): existing rows are kept; incoming rows are inserted.
For models with stable UUIDs (`Routine`, `WorkoutSession`, `Habit`, `ExpenseGroup`,
`BudgetCategory`, `KilterSession`, `KilterFavorite`, `KilterCreatedClimb`) duplicate rows
(same UUID / unique key) are skipped. For models without stable UUIDs (usage records,
completions, transactions, log entries, etc.) all rows are inserted.

### Text exports

- **Journal → Markdown**: `# Journal\n\n## title\n_date_\n**tags**\nbody\n---` per entry,
  newest first.
- **Budget → CSV**: two sections ("## Categories" + "## Transactions"), RFC 4180 escaping.
- **Expense → CSV**: two sections ("## Groups" + "## Expense Records"), RFC 4180 escaping.
- **Workout history → JSON**: completed sessions only, newest first, same DTO shape as the
  backup for toolchain compatibility.

## Output

- `ios/App/Snappet/Core/SnappetBackupPayload.swift` — DTO types + `SnappetBackup` bundle
- `ios/App/Snappet/Core/SnappetBackupEngine.swift` — pure serializer + text formatters
- `ios/App/Snappet/Services/SnappetDataService.swift` — platform service (SwiftData adapter)
- `ios/App/Snappet/Features/Shell/DataManagementView.swift` — backup/restore/export UI
- `ios/App/Snappet/Features/Shell/CorruptStoreBanner.swift` — corrupt-store overlay
- `ios/App/Snappet/SnappetApp.swift` (edit) — detect fallback, stamp `storeFailedToOpen`
- `ios/App/Snappet/Core/AppModel.swift` (edit) — add `var storeFailedToOpen: Bool`
- `ios/App/Snappet/Features/Shell/RootShell.swift` (edit) — show banner when flag is set
- `ios/App/Snappet/Features/WorkoutTracker/WorkoutSettingsView.swift` (edit) — add Data
  Management navigation link to existing "Your data" section
- `ios/App/SnappetTests/SnappetBackupEngineTests.swift` — pure engine unit tests

## Acceptance criteria

- [x] A backup file containing all schema models round-trips (serialize → deserialize) with
  no data loss for all DTO types
- [x] Journal/Budget/Expense/workout exports produce readable Markdown/CSV/JSON via the pure
  engine formatters
- [x] When the store fails to open, `AppModel.storeFailedToOpen = true` is set and
  `CorruptStoreBanner` is shown (testable via a corrupt/missing database file; the banner
  can also be shown by forcing the in-memory fallback path in tests)
- [x] Serialization/restore logic is pure and unit-tested in `SnappetBackupEngineTests`
  without a simulator
- [x] No data leaves the device except via user-initiated `.fileExporter` / share sheet actions

## Constraints

- On-device only; no backend/network/accounts
- No platform imports in SnappetBackupEngine (pure Swift / Foundation only)
- `SnappetDataService` owns all SwiftData interaction for the backup layer
- PHAsset bytes stay in Photos; only the metadata (localIdentifier, offset, duration) is
  backed up (same on-device-only posture as SessionMedia itself)

## Test plan

1. Run `SnappetBackupEngineTests` — all tests pass without a simulator.
2. In Xcode: open the app, navigate Workout Settings → "Back up & export data", tap "Back up
   my data", verify the file saves to Files.
3. On a fresh install / after deleting the on-disk store, import the backup and verify data
   appears.
4. Simulate a corrupt store by renaming the `.store` file: verify the red banner appears on
   launch and the "Restore backup…" CTA opens `DataManagementView`.
