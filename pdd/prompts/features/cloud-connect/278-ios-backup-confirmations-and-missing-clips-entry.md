# Prompt: Backup — confirmations that can always be cancelled; a standing way to the missing-clips list

**File**: pdd/prompts/features/cloud-connect/278-ios-backup-confirmations-and-missing-clips-entry.md
**Created**: 2026-11-21
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 follow-up (on prompt 269's branch, after 277)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Two things found while testing clip copies on a phone (2026-11-21):

1. "Remove all copies from Google Drive…" asked with ONE red button and no Cancel. On current iOS
   a `confirmationDialog` opened from a list row shows as a popover and drops its cancel button.
2. After ✕ on the Clips feed's "N clips aren't on this phone" notice there was no menu entry that
   led back to the list — only "Find clip" on a missing clip itself.

## Product decisions (user, 2026-11-21)

"fix the remove-all confirmation has no Cancel button" → then "add the find missing clips entry and
fix the other three confirmations".

## What changed

- Every destructive question in Cloud & Backup is an `.alert`, which always shows Cancel: remove
  leftovers / empty folders / all copies, the free-up chooser's last step, "Replace all data?"
  (file restore and cloud restore) and "Reset stored data?".
- Cloud & Backup has a "Missing clips" section with a "Find missing clips" row and the count,
  shown whenever any clip is missing. It opens the same `MediaRelinkSheet` as the feed's notice.
  Not shown in the corrupt-store fallback.

## Notes

- The sheet is attached to the Form, not to the section: attached to a `Section` it presented
  with a title and no content.
- Checked on a phone: the remove-all alert shows both buttons and Cancel leaves every copy.
  The other alerts and the new row are covered on the simulator (`BackupUITests`,
  `ClipsFeedUITests.testADismissedMissingClipsNoticeIsStillReachableFromBackup`).
