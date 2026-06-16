# Prompt: Android Kilter share loop — QR share/scan, deep link, paste-frames import

**File**: pdd/prompts/features/63-android-kilter-share-loop.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Compose). Code lands in this repo.
**Chain**: Android Wave 3 → #91
**Source**: GitHub issue [#91](https://github.com/harshal2802/Snappet/issues/91)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Cross-platform climb sharing failed whenever an Android phone was on either end: Android could only
send the raw frames string as gibberish text, with no QR render, no scanner, no deep-link filter, no
import. Close the loop — QR share + scan, `snappet://kilter/climb/<uuid>?angle=<n>` deep link, and
paste-frames import — reusing the existing UUIDv5 content identity.

## Context the implementer needs

- iOS shares `snappet://kilter/climb/<uuid>?angle=<n>` as a QR (`KilterShareView`, `KilterDeepLink`,
  `KilterScannerView`).
- `KilterClimbIdentity` (UUIDv5) and the uuid→climb lookup already exist; reuse for dedup.
- The old share was the text-only `shareFrames` on `KilterDetailScreen`.

## Approach

- Pure: `share/KilterDeepLink` (build + parse the link, JVM-tested).
- Thin edges: `share/QrEncoder` (zxing-core), `share/KilterShareSheet` (QR + link + "Copy hold
  string"), `KilterScannerScreen` (CameraX + ML Kit barcode → parse → resolve uuid → open detail, with
  a "not in your catalog" fallback). Live camera scan is **device-pending**.
- `snappet://kilter` VIEW intent filter + MainActivity routing via the shared `SuiteRouter` +
  `KilterDeepLinkBus`; the same routing also serves `snappet://module/<id>` (issue #99 shortcuts).
- User-language labels ("Share climb", "Copy hold string"); paste-frames import in Create.

## Output

`share/KilterDeepLink.kt`, `share/QrEncoder.kt`, `share/KilterShareSheet.kt`,
`KilterScannerScreen.kt`, `KilterDeepLinkBus.kt`, `core/SuiteRouter.kt`; edits to `KilterDetailScreen`,
`KilterRoot`, `CreateClimbScreen` (paste import), `AndroidManifest`, `MainActivity`. Unit tests for the
deep link (round-trip, junk rejection).

## Acceptance criteria

- [x] Android renders a QR encoding the cross-platform link; deep-link parse is unit-tested both ways.
- [x] `snappet://kilter/climb/<uuid>` opens the app to the climb (router + bus + manifest filter).
- [x] Paste-frames import in Create resolves holds against the installed catalog.
- [x] Share/copy labels are user-readable; no bare "frames" jargon.
- [ ] Live camera QR scan on a real device — **device-pending**.
- [x] Knowledge graph updated.

## Constraints

Offline/on-device, mirroring the iOS feature's no-network design.

## Test plan

1. `./gradlew :app:testDebugUnitTest` — KilterDeepLinkTest green.
2. `assembleDebug` for the camera/manifest wiring.
