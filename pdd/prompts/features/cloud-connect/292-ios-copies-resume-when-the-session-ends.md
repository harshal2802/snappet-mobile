# Prompt: Copies and the backup start again when the session ends

**File**: pdd/prompts/features/cloud-connect/292-ios-copies-resume-when-the-session-ends.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: follow-up to prompt 279

## Problem

The user, on the phone: "when session is on: it stops copying (which makes sense) but when i end the
session copy is still paused."

Prompt 279 holds the automatic backup and the clip copies while a workout or board session runs.
Both are only started when the app launches or comes to the front. Ending a session does neither, so
the status stayed "paused" until the person left the app and came back.

## Change

- `SessionEndWatch` (in `Core/SessionQuietTime.swift`): while cloud work is being held, ask every 15
  seconds whether a session is still on; the first time it is not, run once and stop. One watch at a
  time. It runs only while something is held, so there is no standing poll.
- `AppModel` starts the watch in the three places work is held: `runMediaVault` returning early for a
  session, a copy pass that a session interrupted, and an automatic `runCloudBackup` during a session.
  When it fires it runs the backup and then the clip copies, the same order as a return to the front.

Not changed: the rule that nothing is copied during a session; the Wi-Fi and Low Data Mode rules,
which the resumed pass checks as any pass does.

## Tests

`SessionEndWatchTests` (in `CloudBackupTests.swift`): fires once after the session ends and not
before; a second start while watching does nothing; cancel stops it; the resumed work can start a new
watch.

## Owed on device

End a gym session and a Kilter session with copies paused: the status line leaves "paused" within
about 15 seconds without leaving the app.
