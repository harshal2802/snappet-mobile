# Prompt: Replace destructive Room migration with real migrations + SAF export/import

**File**: pdd/prompts/features/38-android-room-migrations-backup.md
**Created**: 2026-06-10
**Project type**: Native Android feature (Kotlin / Compose) — code lands in this repo.
**Chain**: Product-review roadmap [#101](https://github.com/harshal2802/snappet-mobile/issues/101) → Wave 1 (lands FIRST: gates every schema-touching issue)
**Source**: GitHub issue [#84](https://github.com/harshal2802/snappet-mobile/issues/84)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The single Room database holding every module's history was built with
`fallbackToDestructiveMigration()` — any version bump (already routine, 1→4) silently
wiped all of it. There was also no export/import anywhere, so the device was a single
point of total loss for an on-device-only product. Make schema changes migrations, never
wipes, and give the user a one-file backup/restore.

## Approach

- **Migrations**: `exportSchema = true` with the KSP `room.schemaLocation` arg; the v4
  schema JSON is **committed** under `app/schemas/`. `fallbackToDestructiveMigration()`
  is gone from the build path entirely — a missing migration now fails loudly in
  development instead of silently erasing data in production. Future version bumps ship
  `autoMigrations`/hand-written `Migration`s; `MigrationBaselineTest`
  (`MigrationTestHelper` over the committed v4 schema) proves v4 data opens intact under
  the current no-fallback builder and is the scaffold every bump extends.
- **Backup, schema-agnostically**: rather than 17 entity DTOs that would drift,
  `SnappetBackup` (pure codec, JVM-tested) encodes a versioned JSON payload of
  column→value row maps read at the SQLite level, and `SnappetBackupManager` walks
  `sqlite_master` for user tables — `SELECT *` on export, transactional
  delete-all+insert on import. A new `@Entity` is covered with zero backup changes.
  Import is strict same-schema-version (cross-version restore is the migration
  pipeline's job) and all-or-nothing.
- **UI**: `BackupScreen` (Export via `CreateDocument`, Import via `OpenDocument` + a
  replace-everything confirmation — the Kilter catalog SAF pattern), reached from a
  Backup & restore action on the App Library's top bar.

## Output

- Modified: `SnappetDatabase.kt`, `AppContainer.kt`, `AppLibraryScreen.kt`,
  `app/build.gradle.kts`, `gradle/libs.versions.toml` (room-testing).
- New: `core/SnappetBackup.kt`, `core/SnappetBackupManager.kt`,
  `ui/backup/BackupScreen.kt`, `app/schemas/...4.json`,
  `test/.../SnappetBackupTest.kt` (JVM), `androidTest/.../BackupRoundTripTest.kt`,
  `androidTest/.../MigrationBaselineTest.kt`.

## Acceptance criteria

- [ ] `exportSchema = true` with the v4 schema JSON committed;
      `fallbackToDestructiveMigration()` gone from the build path.
- [ ] Migration baseline test proves v4 data opens intact under the no-fallback builder
      (the literal v4→v5 auto-migration test lands with the first v5 bump — #87/#92 —
      which this PR makes safe and testable).
- [ ] Export writes one SAF file containing all module data; import restores it.
- [ ] Round-trip instrumented test: export → wipe → import → identical reads across
      modules, and re-export equals the original export.
- [ ] Codec is pure and JVM-unit-tested (storage-class fidelity, foreign-file and
      cross-version rejection).
- [ ] `decisions.md` updated; this prompt committed.

## Constraints

- On-device only: SAF file I/O is user-initiated; nothing uploads anywhere.
- Strict same-version import — never silently "best-effort" restore money/health data.

## Test plan

1. `./gradlew :app:testDebugUnitTest` (codec tests).
2. Emulator: `BackupRoundTripTest` + `MigrationBaselineTest` via
   `adb shell am instrument` (Gradle's connected task wedges on this iCloud-synced
   Desktop — decisions.md 2026-06-09).
3. By hand on the emulator: export → file appears; wipe app data; import → all modules
   show the old data.
