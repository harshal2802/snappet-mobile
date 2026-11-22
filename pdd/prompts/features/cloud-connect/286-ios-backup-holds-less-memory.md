# Prompt: The records backup holds less in memory

**File**: pdd/prompts/features/cloud-connect/286-ios-backup-holds-less-memory.md
**Created**: 2026-11-22
**Project type**: iOS
**Chain**: follow-up to prompt 279 (noted there, not fixed)

## Problem

A backup held several copies of the whole payload at once: the encoding used for the hash and the
real encoding were alive together, and the plaintext stayed alive next to the sealed copy for the
whole upload.

## Change

- `CloudBackupPayload.prepare` hashes first, in a helper, so the pinned encoding is released before
  the real one is made.
- `CloudBackupPayload.seal(_:key:)` takes the plaintext out of `Prepared` and seals it. During the
  upload only the sealed copy is held.

The file format, the hash and the key are unchanged.

## Tests

`CloudBackupTests.testSealingLetsGoOfThePlaintextAndStillOpens`; the existing service tests cover
upload and restore.

## Not done / not measured

Memory was not measured on a phone after the change. The payload is still built and sealed in
memory in one piece; streaming it to a file would need a new file format.
