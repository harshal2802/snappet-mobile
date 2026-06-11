# Prompt: iOS data backup, export, restore — and surface the silent corrupt-store fallback

**File**: pdd/prompts/features/47-ios-backup-restore.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 2 (iOS), theme: data safety
**Source**: GitHub issue [#68](https://github.com/harshal2802/snappet-mobile/issues/68); Android counterpart [#84](https://github.com/harshal2802/snappet-mobile/issues/84) (prompt 38)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Every module's data lives in one on-device SwiftData store with no backend *by design* — and
today there is no way to export, back up, or restore any of it. Worse, if the store fails to
open, `SnappetApp` silently falls back to an empty **in-memory** container: the user sees a
blank app with no explanation, and everything they do evaporates on relaunch. Ship the data-
safety triad: (1) a suite-level one-file backup + confirmed replace-everything restore via the
Files app, (2) per-module exports in the format that matters (Journal → Markdown, Budget /
Split Expenses → CSV, workout history → JSON, highlight feedback → JSON), and (3) make the
corrupt-store fallback visible and recoverable.

## Context the implementer needs

- `SnappetApp.swift` is where the fallback fires (`try? ModelContainer` else in-memory) — no
  flag is captured today. `-uiTestFreshStore` / `-uiTestSeedStudioDemo` are the launch-arg
  hook precedents to follow for a `-uiTestCorruptStore` hook.
- `SnappetSchema.models` (`Core/SnappetCore.swift`) is the full inventory — 20 `@Model` types.
  All nested composites (`SessionExercise`, `HRPoint`, `ReceiptItem`, `TimelineClip`,
  `OverlayItem`, …) are already `Codable & Hashable`, so a snapshot codec can reuse them
  verbatim. Relationships are flat UUID/string FKs (suite convention) — restore order is free.
- The Android counterpart (#84) shipped a *schema-agnostic SQLite-level* backup. iOS is
  SwiftData, so the design is necessarily different: serialize the models **explicitly** into
  a versioned envelope, and add a tripwire test so the codec can't silently drift from
  `SnappetSchema.models`. Mirror the shared #84 decisions: replace-everything semantics,
  import confirmed first, strict same-version import as the accepted residual.
- `FeedbackStore.exportAll()` (`Core/FeedbackStore.swift`) is documented "export my data" and
  has zero call sites — wire it into the same consented surface.
- Files-picker precedent: `KilterCatalogSyncView`'s `.fileImporter`. There is no
  `.fileExporter` anywhere yet.
- A sibling worktree (#71) is hoisting Home/SuiteRouter and touches `RootShell` /
  `AppLibraryView` — keep the entry point surgical (one toolbar button on `AppLibraryView`,
  banner wired in `SnappetApp`, everything else in new files).

## Approach

- **`Core/SnappetBackup.swift`** (new): the pure codec. A `SnappetBackup.File` envelope
  (`kind` sentinel + `formatVersion` + `exportedAt` + one `[…Row]` array per `@Model`); each
  `Row` is a `Codable & Hashable` mirror of the model's *stored* properties (raw strings kept
  raw — no enum laundering) with `init(_ model:)` / `make()` both ways. `encode`/`decode` are
  pure (`deferredToDate` for exact `Date` round-trip; `sortedKeys`, no pretty-print — HR
  series keep full fidelity, so compactness is the iCloud-size lever). `snapshot(of:)` /
  `restore(_:into:)` are the thin SwiftData edge: fetch-all → rows, and decode-validated
  replace-everything (delete all + insert all + **one** save, rollback on throw).
  `coveredModels` is the drift tripwire the unit test compares against `SnappetSchema.models`.
- **`Core/ModuleExports.swift`** (new): pure formatters — `journalMarkdown`, `budgetCSV`,
  `expenseCSV` (RFC-4180-style escaping), `workoutHistoryJSON` (pretty, ISO-8601),
  `feedbackJSON` over `FeedbackStore.exportAll()`.
- **`Core/StoreHealth.swift`** (new): `@Observable` launch-time store health (`ok` /
  `fallbackInMemory` / `resetDone`) + `StoreRecovery` (default-store URL derivation + delete
  for the reset path).
- **`Features/Backup/BackupView.swift`** (new): the sheet — Back up my data (`.fileExporter`),
  Restore from backup (`.fileImporter` → decoded preview → destructive confirm → restore),
  per-module export rows. **`Features/Backup/StoreHealthBanner.swift`** (new): the persistent
  fallback banner ("Your data couldn't be opened — changes made now won't be saved.") offering
  Restore from backup / Reset.
- **`SnappetApp.swift`**: capture the fallback into `StoreHealth`, add `-uiTestCorruptStore`,
  attach the banner via `safeAreaInset` (no `RootShell` changes). **`AppLibraryView.swift`**:
  one toolbar button presenting `BackupView`.

## Output

- `ios/App/Snappet/Core/SnappetBackup.swift`, `ModuleExports.swift`, `StoreHealth.swift`
- `ios/App/Snappet/Features/Backup/BackupView.swift`, `StoreHealthBanner.swift`
- Edits: `SnappetApp.swift`, `AppLibraryView.swift` (toolbar button only), `SnappetCore.swift`
  (integrator comment pointing at the codec)
- Tests: `SnappetTests/SnappetBackupTests.swift` (round-trip on in-memory containers — **held
  as properties**, a `ModelContext` doesn't retain its container; schema-coverage tripwire;
  replace + unique-key overlap; reject garbage/wrong version), `SnappetTests/
  ModuleExportsTests.swift`, `SnappetTests/StoreRecoveryTests.swift`,
  `SnappetUITests/BackupUITests.swift` (corrupt-store banner via the launch arg + the backup
  sheet opens)
- `docs/knowledge-graph/data.js` (ios-backup node + links), `pdd/context/decisions.md`,
  `pdd/context/project.md`

## Acceptance criteria

- [ ] A backup file containing **all** schema models round-trips: write to Files, restore on
      a fresh store — every field preserved, incl. workout HR series (with RR intervals) and
      Studio projects (clips/overlays/transitions/audio/FKs).
- [ ] Restore is replace-everything and asks for confirmation first; a non-backup or
      wrong-version file is rejected with a clear message and touches nothing.
- [ ] Journal/Budget/Expense/workout exports produce readable Markdown/CSV/JSON;
      `FeedbackStore.exportAll()` is reachable from the same surface.
- [ ] Store-open failure shows a persistent banner (restore / reset actions) instead of a
      silent blank app; `-uiTestCorruptStore` forces it for tests.
- [ ] Serialization/restore logic is unit-tested in `SnappetTests`; a tripwire test fails if
      `SnappetSchema.models` gains a model the codec doesn't cover.
- [ ] No data leaves the device except user-initiated Files/share actions.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 new warnings); new
      interactive elements have accessibility identifiers.

## Constraints

- On-device only; no backend/network/accounts. The backup file goes only where the user
  points the Files picker.
- Strict same-version import (the #84 shared decision); document migrate-on-import as the
  follow-up, not best-effort restore of money/health data.
- Keep the #71 overlap surgical: `AppLibraryView` gains exactly one toolbar button;
  `RootShell` is untouched.

## Test plan

1. `cd ios/App && xcodegen generate` — clean.
2. Simulator (orchestrator): `SnappetBackupTests` (round-trip, coverage tripwire, replace,
   rejects), `ModuleExportsTests`, `StoreRecoveryTests`, `BackupUITests` green; full existing
   suite unaffected.
3. By hand (device/sim): Apps → toolbar → Back up my data → save to Files; wipe (or fresh
   sim) → Restore from backup → confirm → data back. Launch with `-uiTestCorruptStore` →
   banner shows; Reset → "quit and reopen" state.
