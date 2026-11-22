# Prompt: Automatic copies and backups wait in Low Data Mode

**File**: pdd/prompts/features/cloud-connect/284-ios-low-data-mode-pauses-cloud-work.md
**Created**: 2026-11-22
**Project type**: iOS
**Chain**: follow-up to prompt 281

## Problem

A Wi-Fi network with iOS Low Data Mode on counted as plain Wi-Fi, so clip copies and automatic
backups ran on a network the person had asked iOS to go easy on.

## Change

- `CloudBackupNetwork.lowData`: unmetered Wi-Fi (or cable) that iOS reports as constrained.
  `classify` takes `isConstrained`. On mobile data the Wi-Fi rule already decides, so the case is
  only reported for Wi-Fi.
- Clip copies skip with "Paused in Low Data Mode." (`MediaVaultPolicy`), and the clip upload request
  is barred from constrained networks by iOS as well.
- Automatic backups skip with the same line (`CloudBackupPolicy.precheck` / `decide`). "Back up now"
  still runs: it is the person asking.
- Playing a clip the person taps is unchanged.

## Tests

`CloudBackupTests.testLowDataModeOnWiFiPausesAutomaticWorkOnly`, the policy table in
`MediaVaultTests`.

## Not done

Low Data Mode on mobile data with "Wi-Fi only" switched off is not consulted.
