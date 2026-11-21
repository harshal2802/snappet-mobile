# Prompt: Clip copies — remove folders a layout change emptied; no two copies with one name

**File**: pdd/prompts/features/cloud-connect/273-ios-clip-vault-tidy-and-names.md
**Created**: 2026-11-20
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 follow-up (on prompt 269's branch, after 270–272)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

First real run on the phone (60 copies, By session → By activity): 17 old session folders were left
empty at the top of "Snappet Clips", and two photos shot 0.09 s apart got the same file name.

## Product decisions (user, 2026-11-20)

- After a layout change the app notices the folders it emptied and **offers** to remove them once the
  reorganising is done. The person chooses; it is never automatic.

## Approach

- **Pure**: `MediaVaultFolderTree.emptyFolders(occupied:)` — folders with no copy in them or below;
  returns the count and the topmost ones. `GoogleDriveAPI.trash(id:)` (PATCH `trashed: true`).
  `MediaVaultPaths.placements(_:layout:timeZone:)` — same folder + same name ⇒ later clips get
  " 2", " 3" in capture order (ties by id), so the result is the same on every pass and phone.
- **Service**: `emptyFolderCount` is set at the end of a pass, and only when no copy is still waiting
  to be moved. `removeEmptyFolders()` lists folders and copies AGAIN, recomputes, and trashes only
  what is empty right then.
- **View**: "17 empty folders left in Snappet Clips" + "Remove empty folders…" → confirmation.

## Safety

- Trash, never delete: Drive keeps it 30 days.
- `drive.file` shows the app only its own files. A file the person put in one of these folders is
  invisible to the app and would go to the trash with the folder — the confirmation says so.

## Acceptance

- Unit: empty-folder maths; a layout change offers exactly the emptied folder and removes nothing by
  itself; removing trashes it and leaves the copy; a folder that gained a copy since is kept;
  same-second names differ and are stable.
- UI: `BackupUITests` still pass.
