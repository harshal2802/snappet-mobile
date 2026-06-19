# Prompt: E6 — Share a routine via QR

**File**: pdd/prompts/features/workout-redesign/E6-share-routine-qr.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `workout-redesign/PLAN.md` → E6 (wave 3; depends on E4 — the routine model + per-block prescription)
**Source**: GitHub issue [#186](https://github.com/harshal2802/Snappet/issues/186) · Part of epic #179
**Design**: `docs/ux-research/workout-redesign/README.md` §4 "Share routine via QR", §6 (E6 row), §10 Q4 (the
QR size cliff; version `/v1/` from day one); `wireframes.html` Flow 5
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (2026-06-19 E6 entry)

## Goal

Let a user hand a whole **routine** to a friend who has Snappet — offline, no account, no network — by
generalizing Kilter's proven QR stack. Unlike a Kilter climb (a single REFERENCE into a catalog both phones
ship), a user routine lives on no shared catalog, so it must carry the routine itself, kept small by
referencing `exerciseId`s (both phones ship the same 870-row catalog) and **deflate + base64url** into a
compact `snappet://routine/v1/<blob>` URL. Import is **never silent**: a preview confirms it and inserts a
NEW local `Routine` (new UUID), with a graceful "these N exercises aren't in your library" landing.

## Context the implementer needs

- The reuse target is Kilter's offline QR stack: `KilterShareView.qrImage(for:)` (CoreImage
  `CIFilter.qrCodeGenerator()`), `KilterScannerView` (`QRScannerRepresentable` AVFoundation), `KilterDeepLink`
  (`KilterClimbLink` codec + `SnappetDeepLink.route(for:)` + `KilterDeepLinkRouting.explainMissing`).
- `SuiteRouter.pendingKilterClimb` is the one-shot deep-link pattern; `RootShell.onOpenURL → handle(_:)` is
  the route brain; the `snappet` scheme is already registered in `Resources/Info.plist` (no plist change).
- The payload is the post-E4 `RoutineExercise` composite (discipline + per-axis targets + climb/timed
  metadata) inside `Routine` (`WorkoutModels.swift`).
- `RoutineDetailView` (E4) mirrors `KilterClimbDetailView`'s qrcode toolbar button → sheet.

## Approach

1. **`SnappetShareable` protocol** (`Core/SnappetShareable.swift`): `url` + `init?(decoding:)` (+ default
   `encoded`). `KilterClimbLink` and the new `SharedRoutine` both conform, so one scanner + one QR renderer +
   one route pattern serve both. Lift `qrImage` into a shared **`QRCodeImage.make(for:)`** helper (Kilter's
   share view now calls it; pure black-on-white modules).
2. **`SharedRoutine` compact codec** (`Features/WorkoutTracker/SharedRoutine.swift`, pure value + codec):
   a terse `Codable` of the routine (name + per-block `exerciseId` references + discipline + targets + climb/
   timed metadata — NOT full `Exercise` defs) → **raw DEFLATE** (Apple `Compression`, `COMPRESSION_ZLIB`) →
   **base64url** (`Base64URL`) → `snappet://routine/v1/<blob>`. `routineExercises()` rebuilds fresh-id blocks.
   `fitsInScannableQR` / `scannableURLByteCap` decide the **QR-vs-link** fallback;
   `unresolvableExerciseIds(resolving:)` is the `explainMissing` analog. Custom (`custom-…`) exercises: carry
   the inline `displayName` so the block stays legible, and flag the id as unresolvable (import proceeds).
3. **Route + import**: add `case routine(SharedRoutine)` to `SnappetDeepLink.route(for:)` (tried additively —
   climb decode first, so Kilter scanning never regresses); `RootShell.handle` opens `workout-log` + sets
   `SuiteRouter.pendingRoutineImport` (mirrors `pendingKilterClimb`); `WorkoutHomeView` consumes it
   (`initial: true`, self-clearing) → a **`RoutineImportSheet`** preview (name + N blocks + the "not in your
   library" line) → on confirm, insert a NEW `Routine` (new UUID, never overwrite). Generalize the scanner
   ADDITIVELY into `Core/SnappetScannerView.swift` (a decode-closure generic); `KilterScannerView` becomes a
   thin wrapper over it.
4. **Share entry** on `RoutineDetailView`: a qrcode toolbar button → a segmented **My Code / Scan**
   `RoutineShareView`; the QR + an always-present `ShareLink`. Scanning here routes through the same router
   one-shot (one import brain).

## Output

- `Core/SnappetShareable.swift` (protocol + `QRCodeImage`), `Core/SnappetScannerView.swift` (generalized
  scanner + the lifted AVFoundation plumbing).
- `Features/WorkoutTracker/SharedRoutine.swift` (codec + `Base64URL` + `ZlibCodec`), `RoutineImportSheet.swift`,
  `RoutineShareView.swift`.
- `KilterDeepLink.swift` (`+case routine`), `SuiteRouter.swift` (`+pendingRoutineImport`), `RootShell.swift`
  (`+routine` route), `WorkoutTrackerModule.swift` (consume + `importRoutine`), `RoutineDetailView.swift`
  (share entry), `KilterScannerView.swift` (thin wrapper), `KilterShareView.swift` (uses `QRCodeImage`).
- `SnappetTests/SharedRoutineTests.swift` (round-trip + size + explainMissing + version/rejection + codec
  primitives), `RoutineImportRouteTests.swift` (open-path + one-shot + new-UUID), routine cases in
  `KilterDeepLinkTests.swift`. Graph + decisions updated.

## Acceptance criteria

- [x] `SnappetShareable` unifies the climb + routine onto one renderer/scanner/route; `qrImage` lifted to
      `QRCodeImage`.
- [x] `SharedRoutine` round-trips every block field (exerciseId/sets/reps/rest/weight/discipline/targets/
      climb/timed); rebuilt blocks get fresh ids; a strength block stays `disciplineRaw == nil` (byte-stable).
- [x] A realistic 10–12-block routine fits a scannable QR; an oversized one reports `!fitsInScannableQR` and
      still yields a valid link/file URL. Format versioned `/v1/`; a wrong version is rejected.
- [x] `case routine` added; the climb route still wins for a climb URL (no Kilter regression); the scan path
      generalized additively.
- [x] Import is user-confirmed (preview + the unresolvable-ids line) and inserts a NEW `Routine` (new UUID).
- [x] App type-checks against the iOS SDK; pure codec/routing tests pass; `HighlightEngine` untouched.

## Constraints

- iOS only — the Android mirror is deferred to wave H (tracked). The Android Kilter share loop already proves
  the cross-platform `snappet://` shape.
- The camera scan is device-only; everything else (codec, size, explainMissing, route table, one-shot,
  open-path) is pure and unit-tested without a simulator.

## Test plan

1. `xcodebuild build-for-testing` (iPhone 17) — SUCCEEDED.
2. `SharedRoutineTests` + `SharedRoutineCodecPrimitiveTests` + `RoutineImportRouteTests` (codec round-trip,
   measured size + threshold, explainMissing, version/rejection, base64url + deflate primitives, open-path +
   one-shot + new-UUID) — 0 failures.
3. `KilterDeepLinkTests` + `SnappetDeepLinkRouteTests` (incl. the new routine cases + the climb-not-routine
   guard) — 0 failures, Kilter QR/scan path NOT regressed.
