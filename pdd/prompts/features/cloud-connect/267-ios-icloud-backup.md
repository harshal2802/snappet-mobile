# Prompt: Automatic encrypted backup to iCloud

**File**: pdd/prompts/features/cloud-connect/267-ios-icloud-backup.md
**Created**: 2026-11-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P2 (stacked on P1b, prompt 266)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Design**: `docs/ux-research/cloud-connect/index.html` (backup flow, wireframes 1–3)

## Goal

Snappet's records live only on the phone; the only safety net is a backup file the person must
remember to export. Add an **opt-in** automatic backup: the existing `SnappetBackup` file, encrypted
on the phone, kept in the person's own iCloud, restorable on a new phone. Backup, not sync.

## Product decisions (user, 2026-11-19)

- **Opt-in exception** to on-device-only: off by default, recorded in `decisions.md`, privacy copy updated.
- **Heart-rate samples: a switch, default off.** Off = the samples are left out of the cloud file.
- The backup is **encrypted on the phone** before it leaves.

## Approach

- **Pure** (`Core/CloudBackup.swift`): `CloudBackupSettings` (destination off/iCloud, includeHeartRate
  false, wifiOnly true); `CloudBackupPolicy.decide` (off / unhealthy store / no account / empty /
  unchanged / offline / waiting for Wi-Fi / too soon / upload), `toDelete` (keep 3 per device),
  `restoreOffer` (empty install only, never a declined one); `CloudBackupManifest`; `CloudBackupCrypto`
  (ChaCha20-Poly1305, magic header); `CloudBackupPayload.prepare` (stable content hash, HR stripping).
- **Edge** (`Services/CloudVault.swift`, `CloudBackupService.swift`): `CloudVault` protocol;
  `ICloudVault` (ubiquity container `iCloud.com.snappet.app/Backups`, file-coordinated);
  `FolderVault` (tests); keychain key (synchronizable); the service on `AppModel`.
- **UI**: BackupView becomes **Cloud & Backup** with an *Automatic backup* section; *Cloud backups*
  list with a replace-everything confirmation; a *Welcome back* offer on an empty install.
- One restore path: `AppModel.applyRestore` (file importer and cloud restore both use it).

## Constraints

- Off = nothing leaves the phone, and no control implies otherwise.
- Never upload an empty store or the in-memory fallback store.
- Never delete another device's backups.
- The iCloud entitlement must NOT switch SwiftData to CloudKit sync (`cloudKitDatabase: .none`).
- No new SwiftData fields (settings in UserDefaults) — no migration.

## Verification

- Unit: `CloudBackupTests`, `CloudBackupServiceTests` (full loop against a folder vault),
  `StoreConfigurationTests`; full `SnappetTests`.
- UI: `BackupUITests` (incl. `testAutomaticBackupIsOptInBacksUpAndRestores` against `-uiTestCloudVault`).
- Device-owed: a real iCloud upload, a restore on a second iPhone (key via iCloud Keychain),
  the Health re-read after restore, release signing with the iCloud capability.
