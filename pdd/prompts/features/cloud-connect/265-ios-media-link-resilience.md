# Prompt: Media link resilience — clips survive a dead Photos identifier

**File**: pdd/prompts/features/cloud-connect/265-ios-media-link-resilience.md
**Created**: 2026-11-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P1
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Every `SessionMedia` row finds its bytes through a PHAsset `localIdentifier`, which is valid on one
phone's library only. Today a deleted / freed-up / re-imported asset, or a backup restored onto a
new phone, leaves the row pointing at nothing, with a generic "Couldn't load this clip". Make the
link durable: remember enough about each asset to find it again, re-link automatically when the
identifier dies, and say honestly when the footage is gone. Nothing leaves the phone.

## Context the implementer needs

- `SessionMedia` (`Features/WorkoutTracker/SessionMedia.swift`) stores only `localIdentifier` +
  `offsetSec`. Rows are created at ~12 call sites — do NOT touch them; one reconcile pass covers all.
- The same physical asset can legitimately be filed in two sessions (two rows, one identifier —
  see `SessionMediaIdentifierSetTests`).
- `SnappetBackup` restores rows verbatim, so a restore onto another phone carries dead identifiers.
- `RootShell.importWatchWorkouts()` is the existing launch + foreground reconcile hook.
- UI tests run without Photos access; unresolvable seed identifiers must not be called "missing".

## Approach

- **Pure core** `Features/WorkoutTracker/MediaLink.swift` (no Photos/SwiftData): `MediaFingerprint`
  (capture instant, kind, duration, pixel size, original filename), `MediaLinkMatcher` (conservative
  scoring; a tie is no match), `MediaLinkPlanner.plan(rows:library:)` → `.stamp` / `.relink` /
  `.missing` per row.
- **Model**: additive optional columns on `SessionMedia` — `cloudIdentifier` + `link*` fingerprint
  fields — mirrored in `SnappetBackup.SessionMediaRow` (they must travel with a backup).
- **Edge** `Services/MediaLinkService.swift`: gather a `MediaLibrarySnapshot` from PhotoKit off-main
  (`cloudIdentifierMappings` / `localIdentifierMappings`, time-window candidate fetch), apply the plan.
  Only with full `.authorized` access; never prompts.
- **Wiring**: `AppModel.reconcileMediaLinks()` after the watch import (launch + foreground) and after
  a backup restore.
- **UI**: `ClipMediaSurface` distinguishes `.missing` ("Not on this phone") from `.failed`.
- **Studio**: `StudioComposer.avAsset` allows network so an iCloud-offloaded original opens.

## Output

`MediaLink.swift`, `MediaLinkService.swift`, `MediaLinkTests.swift`; edits to `SessionMedia`,
`SnappetBackup`, `AppModel`, `RootShell`, `BackupView`, `ClipMediaSurface`, `StudioComposer`,
`SnappetBackupTests` (seed); knowledge graph; `decisions.md`; `project.md`.

## Acceptance criteria

- [ ] A live clip gains `cloudIdentifier` (when PhotoKit can map it) and a fingerprint after one pass;
      a second pass writes nothing.
- [ ] A row whose identifier is dead re-links via cloud identifier first, else a UNIQUE fingerprint match.
- [ ] An ambiguous fingerprint match (e.g. burst photos) never re-links.
- [ ] Two rows sharing one dead identifier land on the same new asset; two different dead rows never
      share one.
- [ ] Link handles survive `SnappetBackup` export → restore.
- [ ] The feed shows "Not on this phone" only when the library is fully visible and the asset is absent.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated.

## Constraints

- On-device only; no backend/network/accounts. PhotoKit fetching an iCloud original is the OS's
  transfer inside the user's own library, not Snappet sending data anywhere.
- State verification honestly: type-check ≠ device run for Photos features.

## Test plan

1. `xcodebuild test` — `MediaLinkTests` (pure) and `SnappetBackupTests` (round trip with handles).
2. Device, iCloud Photos on: open the app, confirm rows gain `cloudIdentifier`; export a backup,
   restore on a second device signed into the same iCloud, confirm clips play.
3. Device: duplicate a tagged clip in Photos, delete the original, foreground Snappet → the row
   re-links to the duplicate. Delete a clip with no duplicate → "Not on this phone".
4. Device: offload originals (Optimise Storage), open one in Studio → it loads after a download.
