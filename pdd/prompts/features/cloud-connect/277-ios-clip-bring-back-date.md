# Prompt: Clip copies — a brought-back clip sits in Photos where it was filmed

**File**: pdd/prompts/features/cloud-connect/277-ios-clip-bring-back-date.md
**Created**: 2026-11-21
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 follow-up (on prompt 269's branch, after 276)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

"Bring back to this iPhone" saves the Drive copy into Photos. Photos dates a new asset from the
file's own metadata; a file with none is filed under the moment it was saved, so an old clip would
appear under today.

## Product decision (user, 2026-11-20)

"yes add the fallback. make sure you cover all the edge cases if there are"

## Rule

After the save, read the date Photos gave the new asset. Only if that date is the moment of the
save (within 2 minutes either side) is it replaced with the date Snappet knows.

- The date Snappet knows, best first: the original's own creation date recorded while it was on
  the phone (`SessionMedia.linkCapturedAt`, prompt 265) → session start + the clip's offset → when
  the clip was added (its session is gone).
- A date the file carries is never overruled, even where it differs from Snappet's.
- Nothing is changed when the known date is missing, before 2000, in the future, or itself within
  2 minutes of the save (a clip filmed just now is correctly "now").
- Failing to set the date does not fail the bring-back.

## Approach

- **Pure**: `MediaVaultRestoreDate.correction(assigned:saveStarted:saveEnded:known:)`.
- **Edge**: `MediaVaultExporter.creationDate(of:)` / `setCreationDate(_:of:)`; the service's
  `restoreDate` runs between the save and repointing the clip.

## Known limits

- Not checked on a real phone: whether Photos reads the embedded date for every kind of file the
  camera and other apps produce. The fallback exists because that is not guaranteed.
- Location, and Photos-only attributes (albums, favourites, edits made in Photos), are not restored
  unless the file itself carries them.
