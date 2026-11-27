# Prompt: A UI-test launch touches nothing outside its in-memory test store

**File**: pdd/prompts/features/studio-review/320-ios-test-launch-isolation.md
**Created**: 2026-11-26
**Project type**: iOS
**Chain**: Outside the P-steps of `PLAN.md` (a "—" row). Built on `studio-v2` at `25a7d0c8`. A device
test from another branch hit this; that branch's seed must join `UITestStore.freshStoreArguments`
(a unit test now fails until it does).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## What happened on the phone

On 2026-11-26 a device UI test launched the app on the person's own iPhone with a seed argument,
`-uiTestSeedStudioDevicePhotos` (from an unmerged branch; `-uiTestSeedStudioHRTiming` and every other
seed except four behaved the same). The app opened the in-memory test store correctly, and the
test-store guard passed. But:

1. **The test store was backed up to the person's Google Drive** as the newest backup (3 sessions,
   8 records). Keeping three backups per phone likely dropped an older real one, and
   `cloudBackup.lastManifest` in the real settings now points at the test backup. The test then
   met the "Welcome back – Snappet found a backup in your Google Drive" restore offer.
2. **The person's settings were deleted.** `SnappetApp.init` removes about 20 settings and sets two
   festival flags on every test-store launch, so each test starts the same. On a phone those are the
   person's: the Clips grid size (`clips.grid.columns`), the Clips level (`clips.level`), the recent
   V grades and the recent gyms were lost.

## Causes

- `RootShell.isUITestLaunch` listed four arguments (`-uiTestFreshStore`, `-uiTestCorruptStore`,
  `-uiTestSeedStudioDemo`, `-uiTestSeedRoutineHistory`). Every other seed in
  `UITestStore.freshStoreArguments` ran the network watch, the restore offer, the cloud backup and
  the clip copies against its test store. `SpotlightIndexer`, `RoutineScheduleSync` and
  `WidgetSnapshotService` each kept their own copy of a short list, and `SessionCascade`,
  `KilterBoardPhotoStore` and `KilterCatalogFixture` looked for `-uiTestFreshStore` only.
- Settings are in `UserDefaults`, which the in-memory store does not isolate, and nothing put them
  back after a test.

## The audit: what a test launch can reach outside the in-memory store

"Test launch" = `UITestStore.isTestLaunch`: any argument in `freshStoreArguments`, `-uiTestCorruptStore`,
or the helper's end-of-run `-uiTestRestorePrefs`. Arguments that only tune a screen (`-uiTestFakeCamera`,
`-uiTestCloudVault`, …) do not choose a store, so alone they are not a test launch; the device tests
that run on the real store on purpose (`ClipCopiesDeviceUITests`, `CloudBackupDeviceUITests`, …) are
untouched. One row per ACTION, with where it is stopped. (A review of the first version found the
clip-copies actions reachable from the UI; rows 3–9 are the fix.)

| # | Action | Before | Now, on a test launch |
|---|---|---|---|
| 1 | Automatic cloud backup on launch / foreground / network change / session end (`runCloudBackup`) | Ran for every seed but 4 | **Refused** in `RootShell` and at the top of `AppModel.runCloudBackup` |
| 2 | Manual "Back up now", choosing a destination (`CloudBackupViews` → `runCloudBackup(manual:)`) | Reached the person's Drive / iCloud | **Refused** in `AppModel.runCloudBackup`; and the test launch's `CloudBackupService` has no vault at all (`hasVault` false for every destination), an emptied scratch settings suite (the real `cloudBackup.lastManifest` is never read or written) and a fixed key. `-uiTestCloudVault` keeps the local test folder |
| 3 | "Welcome back" restore offer (`checkCloudRestoreOffer`) | Offered the person's Drive backup | **Refused** in `AppModel.checkCloudRestoreOffer`; no vault to read anyway |
| 4 | Clip-copy passes (`runMediaVault`, Settings switches, session-end resume, network watch) | Launch path gated; Settings and resume not | **Refused** in `AppModel.runMediaVault`; the network watch is not started |
| 5 | Clip copies: coverage / index refresh, "Move to trash" leftovers (`removeLeftovers`), "Remove all copies" (`removeAllCopies`), per-clip remove / copy again (`ClipCopyViews`) | Real `MediaVaultService` with the real index and the real signed-in account: leftovers compared the person's Drive index with the TEST store and would trash every real copy | **Inert**: the test launch's `MediaVaultService` (`AppModel.makeMediaVault`) has an emptied scratch suite instead of the real index / known / excluded clips, scratch cache and poster folders, the test launch's Google account (never signed in) and an offline HTTP client, so `canUseDrive` is false and every Drive call fails |
| 6 | Google sign-in state, token refresh, "Sign out" (`GoogleAccount`, `CloudBackupViews` → `google.signOut()`) | The person's Keychain tokens; sign-out deleted them | **Stand-in**: `GoogleAccount.make` gives a test launch in-memory tokens only (the Keychain is never read, so sign-out clears nothing real) and `OfflineGoogleHTTP`. `-uiTestGoogleSignedIn` is a signed-in stand-in with fake in-memory tokens, offline too |
| 7 | Drive vault and authorized Drive calls (`GoogleDriveVault.forSharedAccount`, `GoogleAuthorizedHTTP.forSharedAccount`) | Network with the shared account's token | **Offline** whenever `GoogleAccount.isOffline` (any test launch or Google stand-in) |
| 8 | Free up space: delete copied clips from Photos (`PhotosMediaVaultExporter.delete`) | Deleted the person's assets | **Refused** unless every asset was made by this launch (`TestLaunchAssets`) |
| 9 | Bring a clip back from Drive (`exporter.save`), set its date (`setCreationDate`) | Wrote to Photos | Unreachable (row 5); a save is noted as owned, a date change needs ownership |
| 10 | Photos: bake in place (`ClipBakeService.saveToOriginal`) | Changed the person's asset | **Refused** unless owned |
| 11 | Photos: bake and replace (`ClipBakeService.replaceOriginal`) | Created a copy, deleted the person's original | **Refused before anything is created** unless the original is owned; the new asset is noted as owned |
| 12 | Photos: overwrite a clip, delete from Photos (`MediaLibraryService.overwriteVideoAsset`, `deleteAssets`; session detail, the player, racket videos) | Changed / deleted the person's assets | **Refused** unless owned (throws `TestLaunchAssets.Refused`) |
| 13 | Photos: save a recording / photo / video (`MediaLibraryService.saveVideoToPhotos`, `savePhoto`, `saveRecording`) | Adds to the library | Allowed (adds only); the new asset is **owned**, so the test may delete or change it later |
| 14 | Photos: media discovery by date for a session (`SessionMediaService` window and `rawAssets`, `PhotoLibraryService.media(in:)`, `MediaLinkService` fingerprint re-link) | A seeded session dated "now" picked up the person's own footage from that window | **Owned assets only**. A manual pick by identifier is still taken (the test chose it; attaching it is read-only) |
| 15 | HealthKit background delivery (`startWatchWorkoutObserver`) | Its callback imported the person's Health workouts | **Not started** (`RootShell`) |
| 16 | Apple Watch workout import + media re-link (`importWatchWorkouts`) | Gated only for the four | **Refused** (one gate) |
| 17 | Health writes | None exist | Harmless |
| 18 | Routine reminders (`RoutineScheduleSync.replan` → `RoutineReminders.apply`) | `apply([])` removed the person's pending routine reminders | **Refused** (one gate) |
| 19 | Festival reminders, clash alert, set-end, "Still out?" (`FestivalNotifications`) | Scheduled for the seeded lineup | **Refused** at each scheduling call; asking for permission still works |
| 20 | Rest-complete alert (`WorkoutNotifications.scheduleRestComplete`) | A test's rest alerted the phone | **Refused** |
| 21 | Focus alerts: schedule and clear (`PomodoroNotifications.scheduleBoundaries`, `clear`) | Replaced / cleared the person's pending focus alerts (same ids) | **Refused** both |
| 22 | Focus Live Activity adoption at launch (`AppModel` → `pomodoroLiveActivity.adoptRunning`) | Adopted the person's running focus, so the test could pause or end it | **Not adopted** |
| 23 | Workout / board Live Activity reconcile at launch (`reconcileLiveActivities`) | Ended the person's running one (the test store has none) | **Refused**. A test session's own activity still starts (and its `start` ends any other workout activity: only if the person has a workout running during a device run) |
| 24 | Spotlight (`SpotlightIndexer.reindex`, `remove`) | Gated only for the four | **Refused** (one gate) |
| 25 | Widget snapshot + widget check-off outbox in the App Group (`WidgetSnapshotService.refresh`) | Gated for three | **Refused** (one gate) |
| 26 | Household widget / watch snapshot (`HouseholdSurfaces.publish`) | Any `-uiTest` prefix: not written | Unchanged (broader than the gate) |
| 27 | Household sync on the local network (`HouseholdPeerService`) | Runs only for a shared household or an open invite in the test store | Harmless: a test household is never paired with a real phone (pairing needs an invite scanned on the other phone) |
| 28 | App actions inbox from Siri / widgets (`drainAppActions`) | Drained the person's pending actions | **Refused** (one gate) |
| 29 | Kilter catalogs: clear / install the fixture (`KilterCatalogFixture` → `KilterCatalogStore`) | `-uiTestFreshStore` (or `-uiTestInstallKilterCatalog` alone) deleted the person's downloaded catalogs and `kilter.*` settings | **Only on a test launch**, and there `KilterCatalogStore.shared` is a scratch folder in tmp; `-uiTestInstallKilterCatalog` alone does nothing |
| 30 | Kilter board photos (`KilterBoardPhotoStore`) | Scratch only under `-uiTestFreshStore` | Scratch on every test launch |
| 31 | Kilter "your boards", force max, Watch-import tombstones | Scratch suites (prefix / fresh-store only) | Tombstones and force max on the one gate; boards keep the prefix rule |
| 32 | Store reset in the fallback banner (`StoreRecovery.resetPersistentStore`) under `-uiTestCorruptStore` | Would delete the **real store files** | **Refused**: a test launch only pretends |
| 33 | Seeds writing rows (`*Seed.seedIfRequested`) | Ran on their own argument | **Each refuses** unless `UITestStore.isFreshStore`, so an unlisted seed can never write into the on-disk store |
| 34 | Remembered heart-rate band (`StudioDemoSeed.seedRememberedBandIfRequested` → `BandMemory`) | Overwrote the person's band in settings | Only once the settings are saved (row 36); restored with them |
| 35 | Watch messages (`LiveWorkoutMessage.allows`) | Any `-uiTest` prefix: not sent | Unchanged (`Shared/`, compiled into the watch too) |
| 36 | **Settings**: clearing ~20 keys, festival flags, `kilter.*`, `clips.missing.dismissedAtCount`, everything tests change (`UserDefaults.standard` and the App Group suite) | Cleared and changed by every test launch, never put back | **Snapshot and restore on a phone** (the design below); a launch whose snapshot failed touches none of them |
| 37 | Reels, posters, exported files (Documents, Caches, tmp) | Tests add exports; the sweep removes old exports by age, as on a normal launch | Harmless: nothing is deleted that a normal launch would keep |
| 38 | Downloaded guide photos / Kilter generator files | A test that downloads them replaces the same files | Harmless: same content, re-downloadable |
| 39 | App Intents donations, background tasks | None exist | Harmless |

## The design

1. **One gate.** `UITestStore.isTestLaunch(_:)` (pure) and `UITestStore.onTestLaunch` (this process)
   replace `RootShell.isUITestLaunch`, `SpotlightIndexer.isUITestLaunch`,
   `RoutineScheduleSync.isUITestLaunch`, `WidgetSnapshotService.isUITestLaunch` and the
   `-uiTestFreshStore`-only checks. `TestLaunchIsolation.cloudBackupRuns` / `cloudCopiesRun` are the
   cloud rules on top of it. The corrupt-store launch now shows the test-store marker too.
2. **Inert services, built where the app builds them.** `GoogleAccount.make(arguments:)`,
   `AppModel.makeCloudBackup(arguments:)` and `AppModel.makeMediaVault(arguments:google:)` return the
   test stand-ins on a test launch (rows 2, 5, 6). Unit tests call the same functions.
3. **Photos ownership (`TestLaunchAssets`).** An in-memory list of the assets this launch created
   (empty at start; a seed that brings its own assets adds them with `noteCreated`). Every change or
   delete needs every asset on it; discovery by date keeps only owned assets.
4. **Settings snapshot (`TestLaunchPrefs`), on a real phone only.** First thing in `SnappetApp.init`:
   - a test launch with no snapshot saves the app's persistent domain and the App Group's
     (`group.com.snappet.app`) to `Library/SnappetTestLaunch/settings-snapshot.plist`, with the time;
   - a test launch with a snapshot keeps it and stamps `lastTestLaunchAt`;
   - **if the snapshot cannot be written (or stamped), the launch touches no setting**: no clearing,
     no festival flags, no Kilter fixture, no demo band; its read-out says `prefs failed` and the
     device guard stops the test before its first tap;
   - **end of run**: the UI-test helper (`PrefsRestoreAtEnd`, a test observer registered by the first
     guarded launch on a device) relaunches the app with `-uiTestRestorePrefs` when the test bundle
     finishes. That launch restores both domains exactly, deletes the snapshot and shows only
     "Settings restored" (`uiTest.prefsRestored`); no store, no shell;
   - **fallback**: the next normal launch restores only if the latest test launch was at most 6 h ago
     and the settings files on disk did not change more than 30 min after it (a later change was made
     by another launch, e.g. a TestFlight build that knows nothing of snapshots, and must not be rolled
     back). Otherwise the snapshot is moved aside (`settings-snapshot.set-aside-<time>.plist`), kept and
     logged, never restored;
   - a restore first renames the snapshot to `settings-snapshot.restoring.plist`; a failed delete
     afterwards is reported (`restored (snapshot not deleted)`, logged) and can never restore again.
   On the simulator it is off: the unit-test host and simulator UI runs keep today's behaviour.
5. **Read-out.** The test-store marker's accessibility value says what the launch keeps away from:
   `cloud backup off; restore offer off; copies off; network watch off; prefs saved`. On a real
   device `launchCheckingTestStore` terminates the app and fails the test before its first tap
   unless the cloud, copies and network watch are off (or the backup goes to the test vault) and the
   settings were saved or kept.

## Tests

- `UITestStoreTests`: every `freshStoreArguments` entry, `-uiTestCorruptStore` and `-uiTestRestorePrefs`
  is a test launch; arguments that do not choose a store are not; the UI-test target's mirror
  (`SnappetUITests/TestStoreGuard.swift`, read from source) equals `freshStoreArguments` and names the
  same corrupt-store and restore arguments; every `"-uiTestSeed…"` literal in the app's sources is in
  the list (the 2026-11-26 seed would fail this).
- `TestLaunchPrefsTests`: the step, fallback and may-touch-settings tables; a test run then the restore
  launch puts every setting back in both domains (removed keys return, added keys go, the snapshot is
  used once), however old the run; several test launches keep the first snapshot and stamp the latest;
  a snapshot that cannot be written fails the launch, touches nothing and reads `prefs failed`; a
  normal launch 40 min after the run restores; 7 h after, or after another launch changed settings,
  it sets the snapshot aside and leaves the settings; an unreadable snapshot is set aside; a failed
  delete is reported and never restores again; a domain the snapshot does not name is left alone; the
  read-out strings; the cloud rules.
- `TestLaunchWiringTests` (the real wiring, not the read-out): the account built for test-launch
  arguments is a stand-in (memory tokens, offline), signed out, with no token; the signed-in stand-in
  cannot reach the network; the backup built for a test launch has no vault for any destination; the
  clip copies built for a test launch do not read the person's copies settings and "Remove all copies"
  leaves them untouched; the Photos ownership rules.
- Full unit suite and full UI suite on the simulator; device compile.

## Owed on device

One run of a seeded device test (e.g. `StudioHRTimingUITests` with `-uiTestSeedStudioHRTiming`) on
the person's iPhone, with before/after comparison:
1. Before: the real store's row counts (Settings → Backup shows them), the full settings plists
   (`xcrun devicectl device copy from … Library/Preferences/<bundle id>.plist` and the App Group's),
   the Drive backup list (Settings → Backup → Google Drive) and the Clip copies count.
2. Run the test. It must pass the read-out check (`prefs saved`); no "Welcome back" sheet; Settings →
   Backup shows Google signed out. The run's log must end with `SNAPPET-PREFS settings restored`
   (the end-of-run launch; it is the first time a test observer drives the app after the bundle ends,
   so confirm it works on a device).
3. Without opening Snappet, copy the plists again and compare: identical (no `Library/SnappetTestLaunch`
   snapshot left). Then open Snappet normally: same row counts, the same Drive backups and clip copies,
   Kilter catalogs still installed, still signed in to Google.
