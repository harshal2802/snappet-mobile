# Prompt: "Save to original" and "Replace original" no longer quit the app

**File**: pdd/prompts/features/studio-review/322-ios-photos-change-isolation.md
**Created**: 2026-11-27
**Project type**: iOS
**Chain**: a crash found by the phone tests of `studio-v2` (prompt 319's device run). Built on
`studio-v2` (76b47cb8, after #500).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## What changes for the user

In the Studio, Export → "Save to original · revertible" and Export → "Replace original" save the
edit instead of quitting the app.

## Problem

On the phone (iPhone 13 Pro Max, iOS 27.2.1, Debug build of `studio-v2`): Studio → a clip → trim →
Export → "Save to original · revertible" → the app quits. The crash log
(`Snappet-2026-11-26-231943.ips`) shows `EXC_BREAKPOINT` in `dispatch_assert_queue_fail` ←
`swift_task_checkIsolated` ← `swift_task_isCurrentExecutorWithFlagsImpl` ← "closure #2 in
`ClipBakeService.saveToOriginal`" ← `-[PHPhotoLibrary _performCancellableChanges:…]_block_invoke`,
on the queue `com.apple.PHPhotoLibrary.transaction.high`.

## Cause

`ClipBakeService` is `@MainActor` (since prompt 117). The SDK gives `performChanges` a plain
`dispatch_block_t` (not `@Sendable`). In Swift 6 a closure that is not `@Sendable`, written in a
main-actor function, is a main-actor closure, and the compiler adds a check at its start that it
runs on the main actor. Photos runs a change block on its own queue, so the check failed and
stopped the app. "Closure #2" is the change block that sets the rendition; `replaceOriginal` has
two blocks of the same kind (create the new video, delete the original).

## Is `main` affected? Yes.

- `origin/main`'s `ClipBakeService.swift` is the same `@MainActor final class` with the same three
  `performChanges { … }` closures. They have not changed since prompt 117 (#281, 0407168d, 2026-07-10).
  Every target is built with `SWIFT_VERSION: 6.0`. So every build since July crashes on Save to
  original and on Replace original, including the TestFlight builds (latest 25). Prompt 117's device
  steps for the bake were never run, so nobody saw it.
- `studio-v2` only added the `ClipBaking` protocol (also `@MainActor`) and `currentDuration`. That
  did not change the closures.
- Prompt 320 (`studio/320-test-launch-isolation`, d1e6ce89, not merged) adds `TestLaunchAssets`
  guard lines before and after the blocks. It does not change their isolation.
- The compiled app confirms it. In a simulator build of `studio-v2` (before this fix),
  `otool -tV Snappet.debug.dylib` shows a call to `swift_task_isCurrentExecutor` in "closure #2 in
  `saveToOriginal`", "closure #1 / #2 in `replaceOriginal`", and the editing-input completion
  ("closure #2 in closure #1 in `saveToOriginal`").

## Change

`ClipBakeService` (Services):

- `PhotosChange` (new, nested): `setRendition(_:on:)`, `createVideo(at:into:)` and
  `deleteAssets(_:)` build the three change blocks in `nonisolated` functions and return them as
  `@Sendable () -> Void`. They capture only Sendable values: `PHAsset` (Sendable in the SDK), a URL,
  the boxed `PHContentEditingOutput`, and `IDBox`, which carries the new asset's id out of the block.
- `editingInput(for:)` (new, `nonisolated static`): the `requestContentEditingInput` request with
  its `canHandleAdjustmentData` and completion blocks, moved out of the main actor.
- `saveToOriginal` / `replaceOriginal` hand those blocks to `performChanges`. The logic is the same:
  deletion is still a second block, and a cancelled deletion still throws `deletionCancelled`.
  Prompt 320's guard and `noteCreated` lines still fit around them: `placeholderID` and its
  `guard let newID` line are unchanged on purpose, and prompt 320's `ClipBakeService` diff applies
  to this file with no conflict (`git apply --check`). Prompt 320's `MediaLibraryService` changes
  are not touched here.

Nothing turns Swift 6 checking off. The fix is to build these closures outside the main actor.

## Audit: closures that Apple frameworks may call off the main thread

Method: (1) grep every callback API in `ios/App` (Snappet, Shared, SnappetWatch, SnappetWidgets,
SnappetShare); (2) look up each SDK block's annotation (Photos, AVFoundation and WatchConnectivity
blocks are plain, not `@Sendable`); (3) list every function in the compiled app, share extension,
widgets and Watch app that calls `swift_task_isCurrentExecutor` (2,746 in the app, almost all
SwiftUI closures that run on main). A closure is only at risk if it is in that list **and** the
framework calls it off the main thread.

| Where | Callback | Verdict |
|---|---|---|
| `ClipBakeService.saveToOriginal` | `performChanges` (rendition) | **Fixed.** The crash. Photos' own queue |
| `ClipBakeService.saveToOriginal` | `requestContentEditingInput` completion + `canHandleAdjustmentData` | **Fixed** (moved to `nonisolated editingInput`). Did not crash on the phone (Photos called it on main), but nothing promises that |
| `ClipBakeService.replaceOriginal` | `performChanges` ×2 (create, delete) | **Fixed.** Same as the crash |
| `ClipMediaSurface.load` (feed / full-screen player) | `requestPlayerItem` result handler | **Fixed** (moved to `nonisolated playerItem(for:)`). The SDK says "called on an arbitrary queue". No crash seen, so Photos calls it on main in practice, but nothing promises that |
| `SnappetScannerView` "Allow camera" | `AVCaptureDevice.requestAccess` completion | **Fixed** (uses the `async` form). The SDK says "called on an arbitrary dispatch queue", and the compiled closure has the check. A first-time camera grant from the QR scanner would most likely have quit the app |
| `AppleWatchMetricsSource.send` | `WCSession.sendMessage` error handler | **Fixed** (`@Sendable`). WatchConnectivity runs it on a background queue when a message to the Watch fails, and the compiled closure has the check |
| `RacketWatchRelay.send` | `WCSession.sendMessage` error handler | **Fixed** (`@Sendable`), same as above |
| `MediaLibraryService` (save / overwrite / delete) | `performChanges`, `requestContentEditingInput` | Safe. A nonisolated `Sendable` class |
| `PhotosMediaVaultExporter` (backup / free up space) | `performChanges` ×3, `requestImage`, `PHAssetResourceManager` | Safe. A nonisolated struct |
| `AssetPosterLoader.poster` | `requestImage`, high-quality, not synchronous | Safe. Photos calls it on the main thread today |
| `SessionMediaThumb` / `AddClimbSheet` thumb / `RacketVideoLibrary.poster` / `ClipMediaSurface` photo | `requestImage`, high-quality, not synchronous | **Fixed in the follow-up** (all four call the `nonisolated` `PhotosImageRequest.image`). Photos calls it on the main thread today, but the SDK does not promise that |
| `AssetPosterLoader.extractFrameZero`, `RacketVideoLibrary.request`, `StudioComposer`, `ReelExporter`, `SceneScorer`, `ClipShareService`, `StudioMediaAvailabilityService`, `RacketMotionReader`, `PhotoClipRenderer`, `ClipAspectResolver` | `requestAVAsset`, `generateCGImagesAsynchronously`, `requestImage`, `finishWriting` | Safe. Already `nonisolated`, or in Sendable / nonisolated types (no check in the binary) |
| `HealthKitService` | `HKObserverQuery`, `HKSampleQuery`, background delivery | Safe. `@unchecked Sendable`, nonisolated |
| `WorkoutWatchManager` (Watch) | `beginCollection` / `endCollection`, HK delegates | Safe. HealthKit blocks are `@Sendable`, delegates `nonisolated` (no check in the Watch binary) |
| `RacketRecorder`, `RacketScanCenter`, `RacketPlayback`, `ClipPlaybackController`, `StudioEditorViewModel` | `NotificationCenter.addObserver`, `addPeriodicTimeObserver` | Safe. Every one passes `queue: .main` |
| `RacketLevelMeter` | `startDeviceMotionUpdates` | Safe. `to: .main` |
| `RacketScanCenter.beginBackground` | `beginBackgroundTask` expiration | Safe. Called on main |
| `KilterBoardController`, `ForceSensor`, `BLEHeartRateMetricsSource` | CoreBluetooth delegates | Safe. `CBCentralManager(queue: nil)` (main), `nonisolated` delegates + `assumeIsolated` / `Task { @MainActor }` |
| `KilterLocationService` | CoreLocation delegates | Safe. The manager is made on main, delegates `assumeIsolated` |
| `SnappetQRScannerController` | metadata delegate | Safe. `queue: .main` |
| `RoutineReminders` | `UNUserNotificationCenterDelegate` | Safe. `nonisolated`, hops with `DispatchQueue.main.async` |
| `Festival` / `Pomodoro` / `WorkoutNotifications` | `requestAuthorization(options:)` completion | Safe. The compiled closures have no check (UserNotifications blocks are `@Sendable`) |
| `CameraController`, `RacketRecorder`, `SnappetQRScannerController`, `ClipAudioSession`, `KilterCatalog`, `FeedbackStore`, `StudioCompositor` | `DispatchQueue.async` | Safe. `DispatchQueue` takes `@Sendable` work, checked by the compiler |
| `HouseholdPeerService` / `HouseholdConnection` | `NWListener` / `NWBrowser` / `NWConnection` handlers | Safe. All started with `queue: .main`, handlers `assumeIsolated` |
| `MediaVaultService.exportStoppable`, `GoogleAccount`, `CloudBackupService` | continuations, `Task.detached`, sync closures | Safe. Nothing a framework calls back |
| `CloudVault` | `NWPathMonitor.pathUpdateHandler` | Safe. `@Sendable` in Network, in structs |
| `ShareViewController` (share extension) | `loadDataRepresentation` completion | Safe. No check in the extension binary (`@Sendable`) |
| `WatchConnectivityLink` (Watch) | `WCSessionDelegate`, `sendMessage` | Safe. `@unchecked Sendable`, nonisolated |
| URLSession | — | Only `async` APIs are used |
| `RacketPlayerViews` player layer (`currentItem.status`, `isReadyForDisplay`), `StudioEditorViewModel.attachTransport` (`timeControlStatus`, item `status`), `StudioPlayerLayerView.Coordinator` (`isReadyForDisplay`) | KVO `observe(_:options:changeHandler:)` | Safe (added in the follow-up). Foundation types the change handler `@Sendable`, so these closures belong to no actor and have no check; each one only hops to main (`DispatchQueue.main.async` / `Task { @MainActor }`) before touching the view or the model |
| `BackgroundTaskHold` (`CloudBackupService.swift`) | `beginBackgroundTask` expiration handler | Safe (added in the follow-up). UIKit calls it synchronously on the main thread; the handler uses `MainActor.assumeIsolated` |

There are no `@preconcurrency` conformances in the app, so no delegate witness gets a hidden check.

## Tests

`ClipBakePhotosIsolationTests` (new, SnappetTests) calls the real writes against the simulator's
Photos library, on videos that each test adds itself:

- `testSaveToOriginalWritesTheRenditionWithoutStoppingTheApp`: adds a 2 s video, bakes a 1 s render
  onto it, and checks that the asset has an edited rendition 1 s long.
- `testReplaceOriginalSavesTheRenderWithoutStoppingTheApp`: the destructive bake's first block
  (saves the render as a new video). The original's id is not in the library, so the deletion
  block, which shows the system's delete dialog, does not run. The deletion block is built the
  same way as the other two blocks.

Both tests need full Photos access for the app on the simulator. Without it they are skipped, and
they never ask for it (an unanswered system dialog would stay up and block the UI tests that run
after them). On the iOS 26.5 simulator, `xcrun simctl privacy <sim> grant photos com.snappet.app`
is written to TCC but PhotoKit still reports "not determined". So access was given once by
answering the app's dialog with "Allow Full Access" (a throwaway UI test tapped it; not committed),
and it lasts for that simulator. Parallel testing runs on clones that do not carry the grant, so
the tests are skipped there; run them with `-parallel-testing-enabled NO`. The test videos are not
deleted: Photos would ask before deleting, and that dialog would stay up too. They are tiny grey
videos in the simulator's library (three per run).

### Runs (a simulator of its own, iPhone 17 Pro, iOS 26.5, Photos granted)

- **Before the fix** (`studio-v2`'s `ClipBakeService`, same tests): both tests stop the test
  process (`Restarting after unexpected exit, crash`). The simulator's crash reports match the
  phone's: `EXC_BREAKPOINT`, `_dispatch_assert_queue_fail` ← `_swift_task_checkIsolatedSwift` ←
  `swift_task_isCurrentExecutorWithFlagsImpl` ← "closure #2 in `ClipBakeService.saveToOriginal`"
  (and "closure #1 in `ClipBakeService.replaceOriginal`") ← `-[PHPhotoLibrary
  _performCancellableChanges:…]_block_invoke`, on `com.apple.PHPhotoLibrary.changes`.
- **After**: `ClipBakePhotosIsolationTests`: Executed 2 tests, with 0 failures.
- Binary check: comparing the before and after builds, the isolation checks are gone from the
  three bake change blocks, the editing-input completion, both `sendMessage` error handlers and the
  feed's player-item handler. No other function changed.
- Full unit suite (`SnappetTests`, no parallel testing): Executed 3784 tests, with 11 tests
  skipped and 0 failures.
- UI: `LiveWorkoutStudioWalkthroughTests`, `StudioSelfCheckUITests`, `ClipsFeedUITests` (15; the
  feed's player) and `FestivalUITests` (11; the QR scanner screens) passed. `StudioHRTimingUITests`
  failed once on its 90 s wait for "Export as new video" to finish (the Mac's load average was
  above 300; a screenshot during the rerun showed the export still running at 57 %, no dialog).
  Run again alone: Executed 1 test, with 0 failures.
- Device compile (`generic/platform=iOS`, Debug, fresh derived data): BUILD SUCCEEDED, no
  warnings in the changed files.

## Follow-up (review of #502)

- `requestImage` result handlers formed in main-actor code moved to one `nonisolated` helper,
  `PhotosImageRequest.image(for:targetSize:contentMode:network:)` (new,
  `Snappet/Services/PhotosImageRequest.swift`): `ClipMediaSurface` (photo clips),
  `RacketVideoLibrary.poster`, the `AddClimbSheet` thumb and `SessionDetailView`'s media thumb.
  Same options as before at each call site (high quality, not synchronous, network on only for
  `ClipMediaSurface`).
- The KVO observers and the background-task expiration handler are in the audit table (safe).
- CI runs the isolation tests. The SnappetTests leg has a new step: `PhotosAccessGrantUITests`
  launches the app with `-uiTestRequestPhotosAccess` (DEBUG only: the app asks for Photos at
  launch) and taps "Allow Full Access" on the system dialog; then `ClipBakePhotosIsolationTests`
  run with `-parallel-testing-enabled NO` and `SNAPPET_REQUIRE_PHOTOS=1`, which turns their skip
  into a failure. The grant test skips itself unless `SNAPPET_GRANT_PHOTOS=1`, so the ordinary UI
  legs never change what other tests see. It is in the `studio` area of `ci-ui-shard.py`.
- Nits: `ClipMediaSurface`'s `Box` doc comment is back on `Box`. `StudioMediaAvailabilityService`
  drops `AssetBox`: `PHAsset` is `Sendable` (`NS_SWIFT_SENDABLE` in the SDK), so the comment
  "PHAsset is not Sendable" was wrong.

### Follow-up runs (a new simulator of its own, iPhone 17 Pro, iOS 26.5)

- Binary check (device build): no `requestImage` handler has an isolation check any more. The
  checks still in `ClipMediaSurface.load`, `RacketVideoLibrary.poster` and `AssetPosterLoader.poster`
  are synchronous closures that run in place on the main thread (`Optional.map`, a `CMTime`
  helper, a closure that dispatches to a global queue).
- The CI sequence, from a fresh simulator: isolation tests with `SNAPPET_REQUIRE_PHOTOS=1` before
  the grant: 2 failures ("Full Photos access is not granted…"), as intended. The grant test with
  `SNAPPET_GRANT_PHOTOS=1`: tapped "Allow Full Access", passed. Isolation tests again: Executed 2
  tests, with 0 failures.
- Full unit suite (no parallel testing): Executed 3784 tests, with 11 tests skipped and 0 failures.
- UI, on the erased simulator (no Photos access, like CI's UI legs): `ClipsFeedUITests` (15),
  `RacketPlayerUITests` (8), `RacketVideosUITests` (2), `PreviousClimbSetterPhotosTests`,
  `LiveWorkoutStudioWalkthroughTests`, `SuiteSmokeTests` passed; `PhotosAccessGrantUITests` skipped.
  Executed 29 tests, with 1 test skipped and 0 failures.
- `ci-ui-shard.py --check` and its 28 unit tests pass.
- Device compile (`generic/platform=iOS`, Debug, fresh derived data): BUILD SUCCEEDED, no
  warnings in the changed files. The `AssetBox` removal is device-only code and compiled there.

## Not done

- The deletion block of Replace original is not run by a test (the system dialog). It is built the
  same way as the two blocks that are tested, and the binary scan shows it has no isolation check.
- The other fixed closures (QR "Allow camera", Watch send failures, the feed's player item) have no
  test that reaches them: each needs a first-time camera prompt, a paired Watch failing a send,
  or Photos calling back off the main thread. The binary scan shows the checks are gone.

## Owed on device

1. Install this build on the phone.
2. Studio → a clip → trim → Export → "Save to original · revertible". The app stays open, the clip
   shows BAKED, and Photos shows the trimmed video (Photos → Edit → Revert still works).
3. Studio → a throwaway clip → Export → "Replace original". iOS asks to delete. Allow it: the clip
   now points at the new video and the original is in Recently Deleted. Run it again on another
   throwaway clip and choose Don't Allow: the message says nothing changed, and the app stays open.
