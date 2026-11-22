# Prompt: CI knows the phone-only UI test classes

**File**: pdd/prompts/features/cloud-connect/283-ci-register-device-ui-tests.md
**Created**: 2026-11-22
**Project type**: CI (`scripts/ci-ui-shard.py`)
**Chain**: follow-up to prompts 267–278

## Problem

CI on main has failed since the Cloud Connect merges (2026-11-21). Six UI test classes added there
(`CloudBackupDeviceUITests`, `GoogleDeviceUITests`, `ClipCopiesDeviceUITests`,
`ClipCopyActionsDeviceUITests`, `ClipRoundTripDeviceUITests`, `MediaLinkDeviceUITests`) were in no
area of `ci-ui-shard.py`. The coverage check failed, and the UI legs stop at that same check, so no
UI test ran in CI.

## Change

The six classes are listed under the `backup` area. Every test in them skips itself on the
simulator (they need a real phone, Photos and Google Drive), so they cost CI a few seconds.

## Checked

`python3 -m unittest test_ci_ui_shard` (28 pass) and `ci-ui-shard.py --check` (100 classes, 311
tests, 8 shards: ok).
