# Prompt: Bug-hunt Wave 4 — durability & perf polish (disk-full crash, live fetch, lost unmute)

**File**: pdd/prompts/features/114-ios-bughunt-wave4-durability-polish.md
**Created**: 2026-07-08
**Project type**: Native iOS fix (Swift) — code lands in this repo.
**Chain**: Wave 4 (final) of the 2026-07-07 whole-repo bug hunt (issues #271–#274); Wave 1 was
prompt 111 (#271 → #275), Wave 2 prompt 112 (#272 → #276), Wave 3 prompt 113 (#273 → #277).
**Source**: proactive bug hunt (GitHub issue #274)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Three self-contained P2 hardenings: (F8) the streaming downloaders must not hard-crash on a
full disk, (F7) the live-session clip discovery must not fetch the whole media table on the
MainActor every 20 s, and (F6) an unmute tap while a clip's player is still loading must not be
silently lost.

## Context the implementer needs

- **F8** — `ExercisePhotoStore.download`, `HostedCatalogClient.download` (KilterAuroraSync), and
  `KilterGeneratorAssets.download` all stream bytes through the **legacy**
  `FileHandle.write(_:)`, which raises an ObjC `NSFileHandleOperationException` on a write
  failure — Swift cannot catch it. A device running out of disk mid-download (the guide-photo
  pack is ~52 MB, a Kilter catalog ~165 MB; this repo has literally hit disk-full before) hard-
  crashes instead of surfacing the intended thrown error on the installer phase. The same legacy
  write also sits inside `HostedCatalogClient.gunzip`, which writes the *decompressed* catalog
  (larger than the download) — same bug class, same fix.
- **F7** — `FreeformPlayerView.discoverClips()` runs every ~20 s during a live session and
  fetches **all** `SessionMedia` rows (no predicate, full objects) on the MainActor just to
  build the global auto-discovery dedup id-set. Scales with the whole media library — the same
  pattern prompt 106 evicted from the Clips feed. The identical fetch also lives in
  `SessionDetailView.allMediaIdentifiers` and `KilterBoardController.existingMediaIdentifiers`
  (one-shot paths, same semantics).
- **F6** — `ClipMediaSurface` builds its player async; `load()` snapshots `muted` before the
  background build, and the `.onChange(of: muted)` writer is a no-op while `player` is nil. An
  unmute tap in that window leaves the UI unmuted but the audio muted until a second toggle.

## Approach

- **F8**: `try handle.write(contentsOf:)` in all three download loops + the gunzip inflate loop
  (all already in `throws` contexts; the gunzip write routes through the closure's existing
  `threw` capture). Drop `ExercisePhotoStore.download`'s redundant second `handle.close()`
  (the `defer` owns closing). No behavior change on the happy path.
- **F7**: ONE shared helper, `SessionMedia.allIdentifiers(in:)`, fetching only the
  `localIdentifier` column via `propertiesToFetch`; all three call sites use it. Global-dedup
  semantics (R2/R4) unchanged — pinned by a small in-memory SwiftData test.
- **F6**: re-apply the **live** `muted` in `.onChange(of: state)` when the item flips `.ready` —
  the same live-read discipline the surface already documents for `isActive` (the onChange
  closure is rebuilt each body evaluation, so it reads the current value, not the load-time
  snapshot). Covers both the looping and fullscreen-controller paths.

## Output

- `ios/App/Snappet/Services/ExercisePhotoStore.swift` — throwing writes, single close
- `ios/App/Snappet/Features/Kilter/KilterAuroraSync.swift` — throwing writes (download + gunzip)
- `ios/App/Snappet/Features/Kilter/KilterGeneratorAssets.swift` — throwing writes
- `ios/App/Snappet/Features/WorkoutTracker/SessionMedia.swift` — `allIdentifiers(in:)`
- `ios/App/Snappet/Features/WorkoutTracker/FreeformPlayerView.swift`,
  `…/SessionDetailView.swift`, `ios/App/Snappet/Features/Kilter/KilterBoardController.swift` —
  call the shared helper
- `ios/App/Snappet/Features/Feed/ClipMediaSurface.swift` — live-mute re-apply on `.ready`
- `ios/App/SnappetTests/SessionMediaIdentifierSetTests.swift` — global-dedup contract
- `pdd/context/decisions.md` + `docs/knowledge-graph/data.js` node notes

## Acceptance criteria

- [ ] No `FileHandle.write(_:)` (legacy, non-throwing) remains in the three downloaders or the
      gunzip loop; a failed write throws to the caller's existing error/notice path.
- [ ] All three global dedup id-set sites go through `SessionMedia.allIdentifiers(in:)`
      (identifier-only fetch); the global — not session-scoped — semantics are test-pinned.
- [ ] `ClipMediaSurface` applies the live `muted` when the player becomes ready.
- [ ] App type-checks (Swift 6, 0 new warnings); full `SnappetTests` unit suite green.
- [ ] `decisions.md` + knowledge-graph node descriptions updated.

## Constraints

- No model change (`SessionMedia` gains only a static helper); download wire formats, install
  flows, and dedup semantics unchanged. `HighlightEngine` untouched.
- UI-suite policy: logic/edge hardenings, no visual change → gate on the unit suite + build; no
  new XCUITests.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — full unit suite incl. the new
   `SessionMediaIdentifierSetTests`.
2. Sim (owed, opportunistic): download flows against the `workout.photos.host` override; the
   20 s discovery loop during a live session.
3. Device only (owed): honest disk-full behavior; the real unmute-during-load feel.
