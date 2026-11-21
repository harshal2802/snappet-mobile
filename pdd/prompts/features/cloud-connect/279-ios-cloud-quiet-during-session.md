# Prompt: Cloud work stays out of a running session; Wi-Fi only is enforced at the connection

**File**: pdd/prompts/features/cloud-connect/279-ios-cloud-quiet-during-session.md
**Created**: 2026-11-21
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → follow-up after the stack merged (#467, #463–#466)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Reported from the phone the day the stack merged (2026-11-21), with backup set to Google Drive
(a 204 MB backup) and clip copies on:

1. Clips kept copying when the phone was not on Wi-Fi.
2. The phone got warm while a session was on.
3. Leaving the app during a session and coming back did not return to the session screen.
4. Tapping the session's banner opened the app somewhere else.

## What was wrong (read from the code; no crash report was available — the phone was on Wi-Fi pairing only)

- Every time the app came forward AND every time it went to the background, the automatic backup
  read the whole store on the main thread (`SnappetBackup.snapshot`) and hashed it BEFORE asking
  whether a backup was even due. During a session that is every glance at another app.
- The same hooks started a clip-copy pass (Drive listing, Photos export, MD5, upload) and a
  library scan on every return, session or not.
- On the way to the background a due backup began an upload that cannot finish there, under a
  background task with no expiration handler. iOS closes an app that overstays one. A closed app
  comes back on Home: that is 3 and 4.
- Wi-Fi only was checked between clips. An upload already in flight carried on over mobile data.

## What changed

- `SessionQuietTime` (pure): a session is running while its Live Activity is up or the store holds
  an unfinished session started in the last 12 hours. `AppModel.sessionIsRunning()` answers it.
- While a session is running: no automatic backup, no clip-copy pass (a pass under way stops
  before its next clip), no library scan. The status lines say "Paused while a session is
  running." "Back up now" still works — the person asked.
- `CloudBackupPolicy.precheck` + `isTooSoon`: off / unhealthy store / session / offline / Wi-Fi
  only / too soon are all decided before the store is read. The rule from 2026-11-20 holds: a
  backup that is no longer in the cloud is replaced at once, spacing or not.
- The automatic backup no longer starts when the app goes to the background. Its background task
  (`BackgroundTaskHold`) ends itself when iOS calls time.
- A Wi-Fi-only clip upload is sent with `allowsExpensiveNetworkAccess = false` and
  `allowsCellularAccess = false`, so the system stops it when Wi-Fi goes.

- A fresh start of the app while a gym workout is still running opens that workout's screen
  (user, 2026-11-21: "yes"). `SessionReturn` (pure): the workout started within the last 4 hours
  and no link has already chosen a destination; an older one stays on Home's "Resume" card. It
  uses the Home card's own route (`pendingWorkoutResume` + the Gym Tracker).

## Measured on the phone, then fixed (same day)

After the build above the user still found the return to a session slow. A temporary probe
(timestamps, a 50 ms hitch monitor and a main-thread sampler writing to Documents — never
committed) on the user's store (417 sessions) showed the app was NOT being closed for those taps,
and where the time went:

| What | Cost | Fix |
|---|---|---|
| Gym dashboard "personal records": `topSet` once per exercise, each a walk of the whole history, read three times a redraw | ~1.2 s per redraw, several redraws per banner tap | `WorkoutMath.topSets` — one pass; computed once per redraw |
| Gym dashboard "recent sessions": recomputed once per row | ~0.15 s per redraw | computed once per redraw |
| Backup snapshot on the main context when a backup was due | 1.4 s freeze | read on a context of its own, off the main thread |
| Home "Recent wins" recomputed on every redraw | ~0.9 s | worked out when the finished sessions or the day change |
| Home re-derived from every session on every return, even behind another tab | ~0.4 s | the clock is refreshed only while Home is the tab on screen |
| Widget snapshot and Apple Watch import during the return | 0.15–0.3 s each | 2 s after the return; the import not at all while a session runs |
| Launch housekeeping (widget snapshot, reminders, Spotlight, …) before the first screen | ~0.5 s | routing first; housekeeping 2 s later |

Banner tap from a minimised session: 3.5–4.5 s before → about 0.4 s after (same phone, debug build).

## Not changed

- Playing a freed clip over mobile data after "Play anyway" (the person's choice, per clip).
- The backup upload itself still holds the sealed file in memory (about 200 MB here). Worth a
  streamed upload later.
- The Kilter Live Activity has no tap link (the workout one has `snappet://workout`).
- The fresh starts seen in the probe log were the user closing the app by hand to test that case
  (confirmed). No evidence was found of iOS closing the app; no crash report could be read over
  Wi-Fi pairing, so the original "closed in the background" reading stays unconfirmed.

## Verification

- Unit: `CloudBackupServiceTests` (nothing uploads on its own mid-session, "Back up now" does;
  what is ruled out before the store is read; the quiet-time rule), `MediaVaultServiceTests`
  (nothing copied or listed mid-session, a pass stops when a session starts, Wi-Fi-only uploads
  are barred from cellular at the request), `MediaVaultTests` policy. Whole unit suite green.
- UI: `WorkoutBrokenLinksUITests.testAFreshStartWithAWorkoutRunningOpensTheWorkout` and
  `…WithAForgottenWorkoutStaysOnHome`, on the new `-uiTestSeedRunningWorkout[Old]` seeds.
- Phone: installed 2026-11-21 (store counts identical before and after, settings unchanged). Owed
  from the user — a session with the app left and re-opened, and a copy pass with Wi-Fi off.
