# Prompt: Send a photo with a QR code to Snappet

**File**: pdd/prompts/features/201-ios-qr-photo-import.md
**Created**: 2026-10-21
**Project type**: Native iOS feature (Swift / Share Extension / Vision) — code lands in this repo.
**Context**: `pdd/context/decisions.md`

## Ask

User (2026-10-20): "can we also have option to send photo containing QR code to the snappet app". Third of three
(A: intents #391 → B: universal links #392 → C: this).

## Build

- **Share → Snappet** (new `SnappetShare` app extension, one image):
  - The QR is read on-device (`QRImageDecoder`, downscaled to 3000 px for the extension's memory limit).
  - The first Snappet code wins (`SnappetCodeImport`).
  - The card says what it found ("a Kilter climb") and opens Snappet on it.
  - If iOS won't open the app from the extension, the link waits in the App-Group action inbox (`openLink`) and runs
    the next time Snappet opens.
- **Every in-app scanner gets "Choose from Photos"** (`PhotoCodePickerRow`): Kilter climb, festival lineup, routine
  (the routine sheet's own picker became the shared row; ids kept).
- **A Snappet code of another kind** (a routine in the climb scanner, camera or photo) is no longer refused. It
  opens where it belongs: `SuiteRouter.pendingLink` → the shell's one link router, after the sheet has gone.
- Photos' own QR badge on a picture already offers "Open in Snappet" thanks to the universal links (prompt 200).

## Acceptance criteria

- [x] Unit: pick — own kind wins, another Snappet kind is handed on (snappet:// form), no code, foreign code; https QR
      screenshot decodes; describe; `openLink` codable + routes itself. 2533 green.
- [x] UI: routine scan sheet's Photos button, festival, Kilter walkthrough, workout links green.
- [ ] Device: Photos → Share → Snappet on a climb / routine screenshot opens the app on it; a photo with no code
      says so; Kilter scanner → Choose from Photos with a routine screenshot opens the routine import.
