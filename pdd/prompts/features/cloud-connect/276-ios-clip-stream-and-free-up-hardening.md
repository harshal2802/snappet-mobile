# Prompt: Clip copies — stream large clips from Drive; harden free-up and Drive-only playback

**File**: pdd/prompts/features/cloud-connect/276-ios-clip-stream-and-free-up-hardening.md
**Created**: 2026-11-20
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 follow-up (on prompt 269's branch, after 275)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Once originals can leave the phone (274, 275), a clip that is only in Drive has to behave well:
start quickly when it is large, respect "Wi-Fi only", say why when it cannot be fetched, keep its
thumbnail, and never have left the phone on weak evidence.

## Product decisions (user, 2026-11-20)

"if clip is bigger in size do we have option to stream that clip?" → "yes build it and also fix the
gaps above." The gaps were the eight listed in the edge-case review, plus one found while building
(a freed clip lost its thumbnail).

## What changed

1. **Streaming.** A video over 25 MB that is only in Drive plays through an
   `AVAssetResourceLoaderDelegate` that reads byte ranges from Drive (1 MB per request), signed
   with the person's Google account. Smaller clips and photos still download whole and replay from
   the cache. Streamed bytes are not cached.
2. **Wi-Fi only applies to fetches.** On cellular the clip's surface says where it is and how big,
   with "Play anyway" (remembered for that clip until relaunch). A cached clip needs no network.
3. **Why it cannot play is said**: signed out, offline, Wi-Fi only, or the copy is gone from Drive
   (then the entry is forgotten and the ordinary "Not on this phone / Find clip" screen shows).
   A long fetch shows "Loading from Google Drive…".
4. **Checksum, not only size.** The MD5 of what was sent is written on the Drive file
   (`appProperties.md5`); free-up compares it with Drive's own `md5Checksum` from a fresh listing.
   Copies made before this are read and hashed at free-up time.
5. **Limited Photos access.** When the whole library cannot be seen, no clip is called Drive-only,
   nothing is offered for removal, nothing is copied, and the screens ask for full access.
6. **Thumbnails survive.** A still of each original is saved (Application Support/ClipPosters)
   before it leaves the phone; the poster loader falls back to it. Removed when the clip is brought
   back; not left behind when iOS's confirmation is declined.
7. **Bring back** does nothing when the original has reappeared (recovered from Recently Deleted),
   so Photos does not get a duplicate. Its failure paths are tested.
8. **Studio.** The free-up chooser says how many selected clips sit on a Studio project's timeline.

## Approach

- **Pure** (`Core/MediaVault.swift`): `MediaVaultFetch` (mode, blocked, chunks, rangeHeader,
  contentType), `MediaVaultCleanup.isVerified` (size + MD5) and `.needsMeasuring`,
  `MediaVaultTag.md5Key`, `MediaVaultText.blocked` / `.usedInStudio`, `SkipReason.needsPhotos`.
- **Edge**: `Services/MediaVaultStream.swift` (`MediaVaultRangeReader`, `MediaVaultStreamLoader`);
  `MediaVaultHash`, `MediaVaultPosters`; service `playback(for:isVideo:)`, `fetchPlan`,
  `allowOnCellular`, `libraryVisible`, `clipsUsedInStudio`. `MediaVaultExporter` gains
  `canSeeWholeLibrary()` and `poster(localIdentifier:)`.
- **Views**: `ClipMediaSurface` (stream item, blocked placeholder, loading line),
  `AssetPosterLoader.savedPoster`, wording in Manage copies and the chooser.

## Known limits

- **Google sign-in lapses every 7 days while the Google Cloud project is in "Testing".** The app
  now says "sign in" instead of showing a broken clip, but the fix is publishing the OAuth app in
  Google Cloud Console — an account action, not code.
- Streaming against real Drive is not verified by an automated test; the range reader is tested
  against the fake, the AVFoundation delegate is not.
- A clip brought back and ALSO recovered from Recently Deleted afterwards leaves one extra asset in
  Photos; the app cannot see or prevent that order.
- A clip that became Drive-only before this build (or on a restored phone) has no saved thumbnail.
- Reels built from a session still skip Drive-only clips.
