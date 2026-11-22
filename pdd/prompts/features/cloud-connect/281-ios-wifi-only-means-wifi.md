# Prompt: "Wi-Fi only" means Wi-Fi

**File**: pdd/prompts/features/cloud-connect/281-ios-wifi-only-means-wifi.md
**Created**: 2026-11-21
**Project type**: iOS
**Chain**: `cloud-connect/PLAN.md` → follow-up to prompt 279
**Context**: `pdd/context/decisions.md`

## Report

After prompt 279 the person still saw clip copies running with no Wi-Fi, and the phone warm, and
switched "Keep clip copies in Google Drive" off.

## Cause

`CloudBackupNetworkProbe` called a connection Wi-Fi when iOS said it was "not expensive". iOS
reports 5G as not expensive on many plans (Cellular → Data Mode → "Allow More Data on 5G"). So on
mobile data the copy pass started: it listed the Drive folders, exported each original out of
Photos and hashed it, and only then did the upload itself get refused (prompt 279 barred that one
request from cellular). The pass counted the refusal as "one bad clip", moved to the next, and gave
up after three. Every return to the app started it again. No video travelled, but the exports and
hashing are the heat, and the counter moved as if clips were being copied.

Not confirmed on the device: the Data Mode setting cannot be read from here. The fix does not
depend on it.

## Change

- `CloudBackupNetwork.classify` (pure): Wi-Fi = connected over Wi-Fi or a cable AND not expensive.
  Anything else that is connected is mobile data. The probe feeds it; both the clip copies and the
  records backup use the probe.
- `CloudBackupNetwork.isNetworkLoss` (pure): a transfer that failed because the network went or was
  refused. The copy pass stops there and says "Waiting for Wi-Fi." (or "Waiting for a connection."
  with Wi-Fi only off) instead of exporting the next clip.

## Unchanged

The upload is still barred from cellular by iOS itself (279). Playing or fetching a clip the person
taps follows its own rule (`MediaVaultFetch.blocked`), which already asks before using mobile data.

## Tests

`CloudBackupTests`: the classify table (inexpensive 5G and hotspot are mobile data), which errors
are a network loss. `MediaVaultServiceTests`: a refused upload stops the pass after one export and
resumes later; with Wi-Fi only off it says offline.

## Not done

Low Data Mode on Wi-Fi still counts as Wi-Fi. Photos may fetch an iCloud-offloaded original during
a copy pass; that now only happens on Wi-Fi because the pass does not start otherwise.
