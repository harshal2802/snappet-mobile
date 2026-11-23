# Prompt: Copies start again when the network changes while the app is open

**File**: pdd/prompts/features/cloud-connect/293-ios-copies-resume-on-a-network-change.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: follow-up to prompts 281, 284 and 292

## Problem

The backup and the clip copies read the connection once, when a pass starts, and a pass starts only
on launch or when the app comes to the front. With the app left open, joining Wi-Fi or turning Low
Data Mode off did nothing: the status stayed "waiting for Wi-Fi" until the person left and returned.
The user asked for this after asking how long a resume takes once Low Data Mode is off.

## Change

- `CloudBackupNetwork.shouldRecheck(from:to:)` (pure): a different kind of connection, with a
  connection, is worth another look. The first reading is not a change. A change for the worse
  (Wi-Fi to mobile data) also looks again, so the status line says it is waiting.
- `CloudBackupNetworkWatch` (in `Services/CloudVault.swift`): one long-lived `NWPathMonitor`. A burst
  of changes is one look, two seconds after the last of them.
- `AppModel.startNetworkWatch()`, started by the shell on launch (not under UI tests): on a change
  it runs the backup, then the clip copies. Nothing starts while the app is not in front
  (`appIsActive`, set from the scene phase).

Not changed: what a pass may do. "Wi-Fi only", Low Data Mode, the running-session hold and the
backup's spacing policy all still decide inside the pass.

## Second part, from the phone the same day: a rule change stops the clip being sent

The user, on mobile data: "i toggle wifi only off->on. but i still see copy happening. why? can you
make sure all the edge cases are covered?" The rules were asked before a pass and between clips, never
during one. Turning "Wi-Fi only" off let a clip start on mobile data; turning it on again left that
clip to finish, which for a long video is minutes of upload.

- The pass runs as a task the service holds. `stopIfNoLongerAllowed()` asks `MediaVaultPolicy.decide`
  with the settings, network and session as they are now and, on a skip, cancels the task; the status
  line gives the reason. Asked at once when a setting changes and when the network watch reports a
  change (in the background too), and every 5 seconds while a pass runs, which covers what has no
  event: a session starting, signing out, Drive permission removed.
- One pass at a time is now decided before anything is awaited (two starts in the same moment could
  both get through).
- Either "Wi-Fi only" switch starts a look when it changes: off on mobile data starts copying, on
  says "Waiting for Wi-Fi." instead of leaving the status blank.

| What changes during a copy | Before | Now |
|---|---|---|
| "Wi-Fi only" turned on, on mobile data | clip finishes | stops at once |
| Copies switched off | clip finishes | stops at once |
| Wi-Fi lost, "Wi-Fi only" on | iOS refuses the upload | same, and the status follows the change |
| Low Data Mode turned on, "Wi-Fi only" off | clip finishes | stops within 2 s |
| A session starts | clip finishes | stops within 5 s |
| Signed out of Google / permission removed | fails on the next request | stops within 5 s |

The records backup is covered the same way (it was first left out as "one small file"; on the phone
it is about 205 MB). `CloudBackupService.stopIfNoLongerAllowed()` asks `CloudBackupPolicy.precheck` and
cancels while the payload is being sent — only then: once the payload is in the cloud its manifest is
written in a task that cannot be cancelled, so no payload is left without one. The Google Drive vault
now bars the payload from mobile data under "Wi-Fi only" (`CloudVault.write(_:name:wifiOnly:)`); with
iCloud, iOS does the sending and the app cannot.

Not covered, on purpose: a clip the person asks to bring back from Drive is their own request and is
not stopped mid-download.

## Third part, from the phone: what the trace showed

A temporary trace on the device (removed before commit) gave three findings.

1. **The cable is a network.** Plugged into the Mac, iOS routes through `en2` (wired) and the status
   bar still says 5G. "Wi-Fi only" allows a cable (prompt 281), so copies ran. Left as it is; the
   user was told and has not asked for a change.
2. **The status waited for Photos.** A stop during the read of an original showed only when the read
   ended (over ten seconds for a long video). `stopIfNoLongerAllowed` now sets the status itself, and
   `exportStoppable` stops WAITING for the read (`EarlyExit`): the read ends by itself and its file is
   deleted. The Photos export code is unchanged — it makes every copy, and a rewrite could not be
   tested without a real library. A pass asked for while a stopped one is still unwinding runs after it.
3. **Wi-Fi on, 5G still the route.** With Wi-Fi switched on, iOS kept 5G as the path in use and listed
   Wi-Fi only as available, so the status stayed "Waiting for Wi-Fi.". `CloudBackupNetworkProbe` now
   takes a second reading with mobile data prohibited — how uploads travel under "Wi-Fi only" — and
   `CloudBackupNetwork.combine` lets that reading win when it is Wi-Fi. The watch listens to both.
   Small requests (listings, starting an upload) are not pinned and may still use 5G.

Also: Control Centre over the app no longer counts as "away" for the network watch.

User on the phone, 2026-11-23: the four toggle steps work; Wi-Fi coming back resumes ("works").

## Tests

`CloudBackupNetworkWatchTests`: which changes count; a burst is one look after it settles; the same
network again is not a change; going offline before it settles starts nothing.

`MediaVaultServiceTests`, with uploads made slow in the fake: "Wi-Fi only" turned on, Wi-Fi lost, Low
Data Mode on, copies off and a session starting each stop the clip being sent, with the right status
line and nothing in Drive; a pass still allowed is left alone; two starts together are one pass; the status changes at once
during a slow read from Photos; Wi-Fi coming back does not wait for a stopped pass, and its abandoned
read changes nothing.

`CloudBackupServiceTests`, with a slow vault: "Wi-Fi only" on, Wi-Fi lost and a session starting stop
the payload with nothing left in the vault; a run still allowed sends payload and manifest under the
Wi-Fi only rule. `combine`: Wi-Fi that can carry the upload wins; mobile data alone and a hotspot do not.

## Owed on device

With copies waiting and the app left open: join Wi-Fi from Control Centre, and turn Low Data Mode
off from another route (or return quickly); the copy starts within a few seconds.
