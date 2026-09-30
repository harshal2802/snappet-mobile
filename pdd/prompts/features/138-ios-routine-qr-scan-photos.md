# Prompt: Share a routine's schedule over QR; scan from Routines or a photo

**File**: pdd/prompts/features/138-ios-routine-qr-scan-photos.md
**Created**: 2026-09-29
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: routine-schedule — 136 schedule + reminders → 137 Habits link → **138 QR schedule + scan/photo import**
**Design**: `docs/ux-research/routine-schedule/wireframes.html` frames 8–11
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

"Share the routine along with schedule using QR code and also add option to scan QR code in routines
section along with option to upload photo of QR code from gallery."

## Context the implementer needs

- Routine QR share already existed (`SharedRoutine`, `snappet://routine/v1/<deflate+base64url>`), but
  **Scan** was only reachable inside another routine's Share sheet.
- Old app builds must keep importing new codes.
- Presenting the import sheet in the same mutation that dismisses the scanner drops it (festival
  P5/P6 race) — stash + promote in `onDismiss`.

## Approach

- `SharedRoutine.schedule` as an optional `sc` key on the same `/v1/` code (old decoders ignore it;
  no schedule → byte-identical to before; a malformed schedule never sinks the routine). Always
  `forSharing` (no skips); the Habits link is device-local and never shared.
- Share sheet: **Include schedule** toggle (on by default) + updated scan instructions.
- Routines ＋ becomes a menu: New Routine · Scan QR Code · Import from Photos (and the empty state).
- `RoutineScanSheet`: camera scanner + **Choose from Photos**; `Services/QRImageDecoder` (Vision, Core
  Image fallback); pure `RoutinePhotoImport` maps payloads → routine / `noCode` / `notARoutine`, shown
  inline (sheet) or as an alert with "Scan instead" (direct Photos import).
- Import confirm: Schedule section (Add this schedule · Edit via the same editor · Track in Habits,
  off by default). Import applies schedule + link, asks notification permission, re-plans.

## Acceptance criteria

- [x] A scheduled routine's code carries its schedule (≤ 80 extra bytes); toggle off → plain code.
- [x] Older decoders still read the routine; codes without a schedule are unchanged.
- [x] Scan and Import-from-Photos reachable from Routines; a screenshot containing a code imports.
- [x] Import confirm lets the user keep, edit, or drop the schedule; Habits link off by default.
- [x] `RoutineQRScheduleTests` (9, incl. decoding a QR inside a phone-sized screenshot);
      `RoutineScheduleUITests.testScanEntryAndShareIncludesSchedule`; full unit + UI suites green.
- [x] Verified once on the simulator end to end: QR PNG added via `simctl addmedia` → ＋ → Import from
      Photos → import sheet with schedule → Add → Up next (throwaway UI test, not committed: the
      system picker needs a pre-seeded library).

## Test plan

1. `make ios-test SIMULATOR='iPhone 17 Pro'`.
2. Device (owed): phone A shares a scheduled routine; phone B scans it (in-app and with the Camera app)
   and imports a screenshot of it from Photos; reminders arrive on B after accepting permission.
