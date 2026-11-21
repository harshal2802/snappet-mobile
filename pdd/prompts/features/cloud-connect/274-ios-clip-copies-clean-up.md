# Prompt: Clip copies — clean up: remove copies from Drive, free up the phone

**File**: pdd/prompts/features/cloud-connect/274-ios-clip-copies-clean-up.md
**Created**: 2026-11-20
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 follow-up (on prompt 269's branch, after 270–273)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Until now the app only ever added copies. Give the person every way out: remove one copy, remove
them all, have a copy follow its clip's deletion, clear copies of clips that no longer exist, and
remove originals from the phone once Drive holds them.

## Product decisions (user, 2026-11-20 — "build all of them")

1. **Follow deletions** — deleting a clip in Snappet moves its copy to Drive's trash (a switch, on).
2. **Remove leftovers** — copies whose clip is no longer in Snappet are counted and offered.
3. **Remove one copy** — from the clip's "…" menu; that clip is not copied again until asked.
4. **Remove all copies** — the "Snappet Clips" folder goes to the trash and copies switch off.
5. **Free up space** — remove originals from Photos for clips whose copy is confirmed.
   Prerequisite: a Drive-only clip can be **brought back** to Photos, and editing one offers that
   instead of opening an empty Studio.

## Approach

- **Pure** (`Core/MediaVault.swift`): `MediaVaultCleanup.plan` (what to remove without asking vs what
  to offer), `.isVerified`, `.freeable`; `MediaVaultTag.bytesKey` (the size sent travels on the Drive
  file); `MediaVaultPlanner` takes `excluding`.
- **Service**: remembers the clip ids it saw at the end of each pass (`knownClips`) — a clip that
  was known and is gone was deleted HERE. `cleanUp` runs at the start of a pass. `removeLeftovers`,
  `removeCopy(of:)` / `copyAgain`, `removeAllCopies`, `freeUpSpace`, `bringBack`.
  `MediaVaultExporter` gains `delete(localIdentifiers:)` and `save(file:isVideo:)`.
- **Views**: "Manage copies" screen from the Clip copies section (`ClipCopiesManageView`); clip menu
  gains Remove copy / Bring back / Copy again; `bringBackToEdit` alert on the three "edit clip" paths.

## Safety rules (each has a test)

- Drive removals are `trashed: true`, never DELETE — 30 days to undo.
- Nothing is removed without asking unless THIS phone had the clip and it is gone. An empty store,
  a restore (`storeWasReplaced`), or more than 10 clips and over a quarter of the known ones
  vanishing at once ⇒ offered, not done.
- An original leaves the phone only if a listing taken at that moment shows the copy with exactly
  the size that was sent (older copies: the original is measured). Two clips sharing one asset must
  both be confirmed. iOS shows its own confirmation; Recently Deleted keeps them 30 days.
- A clip that is only in Drive cannot have its copy removed from its menu.

## Known limits

- Follow-deletions acts on the next pass, not at the moment of deletion.
- Reels built from a session skip Drive-only clips until they are brought back.
- The Manage copies screen has no UI test (it needs a signed-in Google account).
