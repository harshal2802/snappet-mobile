# Prompt: Clip copies — folders the person chooses

**File**: pdd/prompts/features/cloud-connect/270-ios-clip-vault-folder-layout.md
**Created**: 2026-11-20
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 follow-up (on prompt 269's branch)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Prompt 269 put every clip copy in one flat Drive folder, named by its internal id
(`3f2a….mov`). A person cannot browse that. Arrange the copies so the folder reads like the
person's own library, and let them choose the arrangement.

## Product decisions (user, 2026-11-20)

- Four layouts, picked next to the Clip copies switch: **By session** (default) · **By activity,
  then session** · **By month** · **One folder**.
- A session folder is named by the session's start **date and time**.
- "Activity" is the Clips tab's activity (Climbing, Strength, Cardio, Racket, Dance, Mobility,
  Festival, Other), resolved per SESSION so a session stays in one folder. Not per exercise.
- A festival night sits under its festival's name; the artist goes in the FILE name.
- Changing the layout reorganizes the copies already in Drive.

## Approach

- **Pure** (`Core/MediaVault.swift`): `MediaVaultLayout`, `MediaVaultClipInfo` → `MediaVaultPaths.placement`
  (folders + file name, written in a fixed time zone), `MediaVaultPlacement.stamp` (FNV-1a of the
  place), `MediaVaultTag` (private Drive properties), `MediaVaultFolderTree` (find before create),
  `MediaVaultOrganizer.moves`, `MediaVaultIndex.keepingRecentUploads`.
- **The link moves out of the file name** into Drive `appProperties` (`snappet=clip`, `clip=<row id>`,
  `placed=<stamp>`). Copies made by prompt 269 (id in the name, in the root) are still recognized
  and are filed and tagged on the next pass.
- **Edge** (`Services/MediaVaultService.swift`): list by the marker, list folders, create nested
  folders, `relocate` (one PATCH: rename + re-tag + move, no bytes), `MediaVaultCatalog` reads each
  clip's facts off the store the way the Clips tab does.
- **UI**: a *Folders* picker with a sample path, and an "Organizing n of m…" status.

## Constraints

- No SwiftData field, no migration; a restored phone still rebuilds the index from a Drive listing.
- Moving is never re-uploading.
- The app moves a copy only when the place IT wants changes (the stamp differs). A rename or move the
  person made in Drive is left alone until then.
- Never delete or trash a folder: with `drive.file` the app cannot see files the person put there.
- Fetched files are cached by clip id, not by Drive name (names may repeat).
- New activities need no change here: the folder is the activity's display label.

## Verification

- Unit (`MediaVaultTests`): old settings load; each layout's path; time zone; festival + artist;
  name cleaning; stamp stability; index from tagged / legacy / foreign files; lagging listing;
  folder tree; organizer; request shapes.
- Unit (`MediaVaultServiceTests`, fake Drive with folders, properties and PATCH): copy into the
  session folder; layout change moves without exporting; a Drive rename is left alone and still
  plays; a prompt-269 copy is filed, not uploaded again; festival night + later artist tag; a Google
  Photos pick is filed like any copy.
- UI: `BackupUITests`.
- Owed (needs the phone and real Drive): that `appProperties` set on a resumable upload are returned
  by the marker query, and that one PATCH can rename, re-tag and move.
