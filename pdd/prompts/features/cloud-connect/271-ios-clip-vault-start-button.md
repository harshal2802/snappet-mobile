# Prompt: Clip copies — nothing uploads until "Start copying"

**File**: pdd/prompts/features/cloud-connect/271-ios-clip-vault-start-button.md
**Created**: 2026-11-20
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 follow-up (on prompt 269's branch, after 270)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

On the phone, turning on "Keep clip copies in Google Drive" began uploading at once — before the
person could pick a folder layout (prompt 270). The switch should only open the choices; the first
upload is a deliberate tap.

## Product decisions (user, 2026-11-20)

- The folders option is chosen **before** anything is copied.
- A button starts the copy the first time.

## Approach

- **Pure** (`Core/MediaVault.swift`): `MediaVaultSettings.started` (default false).
  `MediaVaultPolicy.decide` returns `.skip(.notStarted)` when the switch is on but not started
  (no status text — it is not a problem). Settings saved before this field decode `started` as
  `keepCopies`, so copies that were already running keep running.
- **Service**: `runIfNeeded` does nothing until `started`; so app launch, foreground, sign-in and a
  layout change all stay quiet.
- **View** (`ClipVaultSection`): switch on → account row, coverage ("0 of 191 clips copied"),
  Folders, Wi-Fi only and **Start copying** (`mediaVault.start`, disabled until signed in). After
  the tap it becomes **Copy now** as before. Start is asked **once**: switching off only pauses
  (user, 2026-11-20 — a pass in flight stops after the current clip), and switching on again carries
  on from what Drive already holds. While a pass runs the status shows the whole picture
  ("Copying… 32 of 191 clips copied"), not the batch ("1 of 20"), which read as starting over.

## Acceptance

- Unit: policy `.notStarted`; old settings decode; on-but-not-started uploads nothing, and the first
  copy after Start lands in the layout chosen beforehand.
- Unit: off then on copies only what is not there yet (no re-upload).
- UI (`BackupUITests`): switch on shows Start and Folders, no "Copy now".

## Out of scope

- Background uploads. Copies still run only while the app is open.

## Addendum (user, same day): keep copying until everything is done

A pass no longer stops at 20 clips: it copies every clip without a copy while the app stays open.
A clip that will not export or upload is skipped and tried next pass ("1 clip couldn't be copied.
It will be tried again."); three failures in a row stop the pass with the error; the network is
re-checked between clips so a pass that leaves Wi-Fi stops ("Waiting for Wi-Fi.").
