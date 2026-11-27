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

"Test launch" = `UITestStore.isTestLaunch`: any argument in `freshStoreArguments`, or
`-uiTestCorruptStore`. Arguments that only tune a screen (`-uiTestFakeCamera`, `-uiTestCloudVault`,
…) do not choose a store, so alone they are not a test launch; the device tests that run on the real
store on purpose (`ClipCopiesDeviceUITests`, `CloudBackupDeviceUITests`, …) are untouched.

| # | Reach | Before | Now |
|---|---|---|---|
| 1 | Cloud backup to Google Drive / iCloud (`CloudBackupService`, `runCloudBackup`, also the manual "Back up now") | Ran for every seed but 4 | **Gated three times**: RootShell, `AppModel.runCloudBackup`, and on a test launch `AppModel.cloudBackup` is built with no vault, an emptied scratch settings suite and a fixed key, so it cannot reach a cloud or read `cloudBackup.lastManifest`. The local test vault (`-uiTestCloudVault`) still works |
| 2 | "Welcome back" restore offer (`checkCloudRestoreOffer`) | as 1 | **Gated**, as 1 |
| 3 | Clip copies to Drive (`MediaVaultService`, `runMediaVault`, incl. Settings switches and the "session ended" resume) | Launch path gated; Settings and the resume path not | **Gated** inside `AppModel.runMediaVault` |
| 4 | Network watch (`startNetworkWatch`) | Gated only for the four | **Gated** inside `AppModel.startNetworkWatch` |
| 5 | HealthKit background delivery (`startWatchWorkoutObserver`) | Ran: its callback imports the person's Health workouts | **Gated** in RootShell |
| 6 | Apple Watch workout import + media re-link (`importWatchWorkouts`) | Gated only for the four | **Gated** (one gate) |
| 7 | Health writes | None exist (the app reads Health only) | Harmless |
| 8 | Routine reminders (`RoutineScheduleSync.replan` → `RoutineReminders.apply`) | Ran for other seeds: `apply([])` removed the person's pending routine reminders | **Gated** (one gate) |
| 9 | Festival reminders, clash alerts, set-end / "Still out?" (`FestivalNotifications`) | Scheduled for the seeded lineup | **Gated** at the scheduling calls; asking for permission still works |
| 10 | Rest-complete alert (`WorkoutNotifications`) | A test's rest alerted the phone | **Gated** |
| 11 | Focus boundaries (`PomodoroNotifications`) | Replaced the person's pending focus alerts (same ids) | **Gated** |
| 12 | Live Activities: launch reconcile (`reconcileLiveActivities`) | The test store has no running session, so it ended the person's real one | **Gated**. A test session's own activity still starts (its `start` ends any other); the next normal launch's reconcile ends it |
| 13 | Spotlight (`SpotlightIndexer`) | Gated only for the four | **Gated** (one gate) |
| 14 | Widget snapshot + check-off outbox in the App Group (`WidgetSnapshotService`) | Gated for three | **Gated** (one gate) |
| 15 | Household widget / watch snapshot (`HouseholdSurfaces`) | Gated by any `-uiTest` prefix | Unchanged (broader than the gate) |
| 16 | Household sync on the local network (`HouseholdPeerService`) | Runs only for a shared household or an open invite in the test store | Harmless: a test household is never paired with a real phone (pairing needs an invite scanned on the other phone) |
| 17 | App actions inbox from Siri / widgets (`drainAppActions`) | Gated only for the four: drained the person's pending actions | **Gated** (one gate) |
| 18 | Kilter catalogs in Application Support (`KilterCatalogFixture` → `KilterCatalogStore.clear`) | `-uiTestFreshStore` **deleted the person's downloaded catalogs** | **Moved**: on a test launch `KilterCatalogStore.shared` is a scratch folder in tmp |
| 19 | Kilter board photos (`KilterBoardPhotoStore`) | Scratch only under `-uiTestFreshStore` | Scratch on every test launch |
| 20 | Kilter "your boards", force max, Watch-import tombstones | Scratch suites (prefix / fresh-store only) | Tombstones and force max now on the one gate; boards keep the prefix rule |
| 21 | Store reset in the fallback banner (`StoreRecovery.resetPersistentStore`) under `-uiTestCorruptStore` | Would delete the **real store files** | **Gated**: a test launch only pretends |
| 22 | Remembered heart-rate band (`StudioDemoSeed.seedRememberedBandIfRequested` → `BandMemory`) | Overwrote the person's band in settings | Settings are restored (row 24) |
| 23 | Watch messages (`LiveWorkoutMessage.allows`) | Any `-uiTest` prefix: not sent | Unchanged (`Shared/`, compiled into the watch too) |
| 24 | **Settings** (`UserDefaults.standard` and the App Group suite) | Cleared and changed by every test launch, never put back | **Snapshot and restore on a phone** (the design below) |
| 25 | Reels, posters, exported files (Documents, Caches, tmp) | Tests add exports; the sweep removes old exports by age, as on a normal launch | Harmless: nothing is deleted that a normal launch would keep |
| 26 | Downloaded guide photos / Kilter generator files | A test that downloads them replaces the same files | Harmless: same content, re-downloadable |
| 27 | App Intents donations, background tasks | None exist | Harmless |
| 28 | Google sign-in (Keychain) | Used only by 1 and 3 | Gated through 1 and 3 |

## The design

1. **One gate.** `UITestStore.isTestLaunch(_:)` (pure) and `UITestStore.onTestLaunch` (this process)
   replace `RootShell.isUITestLaunch`, `SpotlightIndexer.isUITestLaunch`,
   `RoutineScheduleSync.isUITestLaunch`, `WidgetSnapshotService.isUITestLaunch` and the
   `-uiTestFreshStore`-only checks. `TestLaunchIsolation.cloudBackupRuns` / `cloudCopiesRun` are the
   cloud rules on top of it. The corrupt-store launch now shows the test-store marker too.
2. **Settings snapshot (`TestLaunchPrefs`), on a real phone only.** First thing in
   `SnappetApp.init`, before any other code reads a setting:
   - a test launch with no snapshot saves the app's persistent domain and the App Group's
     (`group.com.snappet.app`) to `Library/SnappetTestLaunch/settings-snapshot.plist`;
   - a test launch with a snapshot keeps it (it holds the real settings; the later ones are test
     settings);
   - a normal launch with a snapshot puts both domains back exactly (keys the tests added are
     removed) and then deletes the file; a crash in between restores again next time;
   - a snapshot of any age restores; an unreadable one is deleted and never retried.
   On the simulator it is off: the unit-test host and simulator UI runs keep today's behaviour
   (a restore between UI tests would undo what the suite expects from one launch to the next).
3. **Read-out.** The test-store marker's accessibility value says what the launch keeps away from:
   `cloud backup off; restore offer off; copies off; network watch off; prefs saved`. On a real
   device `launchCheckingTestStore` terminates the app and fails the test before its first tap
   unless the cloud, copies and network watch are off (or the backup goes to the test vault) and the
   settings were saved or kept.

## Tests

- `UITestStoreTests`: every `freshStoreArguments` entry and `-uiTestCorruptStore` is a test launch;
  arguments that do not choose a store are not; the UI-test target's mirror
  (`SnappetUITests/TestStoreGuard.swift`, read from source) equals `freshStoreArguments`; every
  `"-uiTestSeed…"` literal in the app's sources is in the list (the 2026-11-26 seed would fail this).
- `TestLaunchPrefsTests`: the step table; a test launch then a normal launch puts every setting back
  in both domains (removed keys return, added keys go, the snapshot is used once); several test
  launches keep the first snapshot; a 60-day-old snapshot restores; empty settings come back empty;
  a normal launch without a snapshot touches nothing; an unreadable snapshot is dropped; a domain the
  snapshot does not name is left alone; the read-out strings; the cloud rules for every test-launch
  argument with and without the test vault.
- Full unit suite and full UI suite on the simulator; device compile.

## Owed on device

One run of a seeded device test (e.g. `StudioHRTimingUITests` with `-uiTestSeedStudioHRTiming`) on
the person's iPhone, with before/after comparison:
1. Before: the real store's row counts (Settings → Backup shows them), the full settings plist
   (`xcrun devicectl device copy from … Library/Preferences/<bundle id>.plist` and the App Group's), and the Drive backup list (Settings → Backup → Google Drive).
2. Run the test. It must pass the new read-out check (`prefs saved`), and no "Welcome back" sheet may
   appear.
3. Open Snappet normally once (this restores the settings), then compare: same row counts, the
   settings plists identical (apart from keys a normal launch writes itself), the same Drive backups,
   no `Library/SnappetTestLaunch` folder left, Kilter catalogs still installed.
