# Prompt: Clip copies — show on the clip that it is copied, and where

**File**: pdd/prompts/features/cloud-connect/272-ios-clip-copy-indicators.md
**Created**: 2026-11-20
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 follow-up (on prompt 269's branch, after 270–271)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Nothing in the Clips feed or on a session said whether a clip has a copy in Google Drive. The only
sign was one total on the Backup screen. Say it on the clip.

## Product decisions (user, 2026-11-20 — "all 3 options")

1. A small cloud mark on a clip that has a copy: the feed post header (for the page showing) and
   every session clip thumbnail (`SessionMediaThumb`: gym detail, Kilter detail, live pager).
2. In the post's "…" menu: "Copied to Snappet Clips / Climbing / 2026-11-14 18.42" with
   **Open in Google Drive**; or a disabled "Not copied to Google Drive yet".
3. A line on the session detail (gym + Kilter): "8 of 9 clips copied to Google Drive".

## Approach

- **Pure** (`Core/MediaVault.swift`): `MediaVaultFolderTree.paths()`, `MediaVaultEntry.driveURL`,
  `MediaVaultIndex.copiedCount(of:)`, `MediaVaultText.location(folders:)` / `.sessionCopies`.
- **Service**: remembers folder id → path from each pass (`folderPaths`, UserDefaults), so "where"
  costs no network call. `showsCopyState` = started, or copies exist; otherwise screens say nothing.
  A copy in a folder the app does not know (moved by the person) reads "Google Drive" — no guess.
- **Views** (`Features/Feed/ClipCopyViews.swift`): `ClipCopyMark`, `ClipCopyMenuItems`,
  `SessionCopyLine` — small leaves that read the vault themselves, so a finished upload redraws the
  mark, not the post or the session screen (Clips feed perf, prompts 106/193).

## Acceptance

- Unit: paths, location text, session line text, copied count, Drive link; after a pass the service
  knows each copy's place and remembers it across launches.
- UI: `ClipsPostUITests` + `BackupUITests` still pass (no vault in use ⇒ nothing new is drawn).

## Out of scope

- The Clips tab's zoomable grid (UIKit cells; a cover stands for several clips).
