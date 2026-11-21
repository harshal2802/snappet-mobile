# Prompt: Clip vault in Google Drive + bring clips back from Google Photos

**File**: pdd/prompts/features/cloud-connect/269-ios-clip-vault-google-photos.md
**Created**: 2026-11-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 (stacked on P3, prompt 268)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Setup**: `docs/google-cloud-setup.md`

## Goal

On the first real library, 1,684 of 1,875 clips had no footage on the phone: Google Photos had freed
it, and the phone has no room to bring it back. Give a clip a home that is not the phone:

1. **Clip copies** (opt-in): copy each session clip to a "Snappet Clips" folder in the person's
   Google Drive; a clip no longer in Photos plays from that copy.
2. **Pick from Google Photos**: the person picks old footage in Google's picker; matches are copied
   Google Photos → Drive, never touching phone storage.

## Product decision (user, 2026-11-19): build the vault.

## Approach

- **Pure** (`Core/MediaVault.swift`): naming (`<SessionMedia.id>.<ext>`), `MediaVaultIndex` from a
  folder listing, `MediaVaultPlanner` (what to upload, coverage), `MediaVaultPolicy`, `MediaSource`
  order (Photos → cache → vault → missing), `MediaVaultCache` (LRU), `GooglePhotosPickerAPI`,
  `GoogleImportPlanner` (reuses `MediaRelinkPlanner` — same rules as a hand pick).
- **Edge** (`Services/MediaVaultService.swift`): `GoogleDriveMediaStore` (`drive.file`, streamed
  upload/download), `MediaVaultExporter` (Photos originals), the service on `AppModel`.
- **UI**: *Clip copies* section in Cloud & Backup; *Pick from Google Photos* in Find missing clips;
  `ClipMediaSurface` falls back to the vault.

## Constraints

- Off by default; hidden without a Google client ID.
- No SwiftData field: the file name is the link, so a restored phone rebuilds the index from a listing.
- "A tie is no match" and "two rows sharing one dead identifier land on the same asset" hold for
  Google picks exactly as for Photos picks.
- A clip row is never rewritten by the vault; Photos stays the first source.
- Say plainly that clip copies are ordinary, unencrypted files in the person's Drive.

## Verification

- Unit: `MediaVaultTests`, `MediaVaultServiceTests` (fake Google + fake library): off = no request;
  copy once into one folder; play from vault with one shared download; index rebuilt on a fresh
  install; Google picks matched / unmatched / failed; picker polling and timeout.
- UI: `BackupUITests` (section present only with Google, off by default), `ClipsFeedUITests`.
- Owed (needs the client ID + a phone): everything against real Google; real playback of a vault
  clip; whether Google's `createTime` lands within the 2 s match window for this library.
