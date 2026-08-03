# Prompt: Closet image pipeline — right-sized photos, cached tiles, and a 1 GB reclaim migration (wardrobe prompt 03)

**File**: pdd/prompts/features/wardrobe/03-closet-image-pipeline-perf.md
**Created**: 2026-08-02
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: wardrobe device-feedback trio → P1 (P2 = multi-photo per item, P3 = rich add form)
**Source**: user device feedback 2026-08-02 ("scroll in the closet hangs after adding so much"),
diagnosed against the real closet pulled off MrRobot — see "The measurement" below.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Closet scrolling hangs once a real closet is loaded. The cause is not the list — it is what the
list is asked to decode. Capture saves the background-removed cut-out as a **full-resolution
lossless RGBA PNG**, and every tile decodes that master to fill a 96pt square. Make the stored
photo proportional to what the app can display, give every tile a thumbnail it can decode off the
main thread and cache, and migrate the closet that already exists so the fix is felt on the user's
device and not only on new items.

This is the perf leg only. Multi-photo (P2) and the richer add form (P3) land on top of the
storage shape this prompt establishes, so `WardrobeItem`'s photo attributes are designed here to
survive both without a second migration.

## The measurement (real device data, not estimates)

Pulled from MrRobot's App Group container (`group.com.snappet.app` — note the app-sandbox copy is
a stale pre-wardrobe leftover), 100 items added in one ~11-hour cataloguing session:

| | count | avg | total |
|---|---|---|---|
| Cut-out PNGs, RGBA, ~3000×2600 | 97 | 10.4 MB | 1010 MB |
| Originals, JPEG 4032×3024 | 3 | 3.7 MB | 11 MB |

**1.01 GB for 100 garments.** One tile therefore reads ~10 MB off disk and decodes it to a
`3024 × 2820 × 4 ≈ 34 MB` bitmap — to fill 96pt (288px @3x). That is ~110× more pixels than the
tile can show, on the main thread, uncached, repeated on every body pass.

## Context the implementer needs

- **`WardrobeCaptureSheet.save()`** (`:220-225`) is the only writer: `cutout.pngData()` for the
  cut-out, `original?.jpegData(compressionQuality: 0.85)` otherwise. No downscale on either path.
- **`WardrobeItemTile`** (`ClosetView.swift:170-190`) is the single choke point and the single
  fix point — it is used in **9 places** at heights 38…240pt (Closet grid 96, detail hero 240,
  StyleCoach 54, OutfitHistory 50, StyleViews 52/44/100, Settings 38, Root 44/40). Every one of
  them decodes the full master today, including the 38pt settings row.
- **Three compounding structural costs in `ClosetView`**, all secondary to the decode but real:
  1. `LazyVGrid` nested inside `LazyVStack` (`:57`) largely defeats laziness — the outer stack
     needs each grid's height, so tiles materialize well ahead of the viewport.
  2. `sections` (`:37-42`) calls `filtered.filter` once **per category** — `filtered` is a
     computed property, so an O(n) filter runs 8× plus once for `.isEmpty`, every body pass.
  3. `stats` (`:16-20`) rebuilds a dictionary over all wear events every body pass.
- **The established in-repo pattern** for exactly this problem is `Features/Feed/AssetPosterLoader.swift`
  (clips-feed perf, prompt 106): `NSCache` bounded by `totalCostLimit` with a decoded-bitmap cost
  function, plus `nonisolated` static helpers so decode runs off the MainActor. The view side is
  `ExerciseGuidePhotoViews.swift:37-45`: `.task(id:)` that **resets to nil first** (so a recycled
  identity never shows the previous item's photo) then awaits a `Task.detached(.userInitiated)`.
  Follow both; do not invent a third cache.
- **CloudKit-compatibility is a locked decision** (wardrobe prompt 01): every new stored property
  needs an inline default or must be Optional, no `@Attribute(.unique)`, no SwiftData
  relationships. New photo attributes must obey this.
- **Backup**: adding a `@Model` requires a mirror Row (`SnappetBackupTests.testCodecCoversEverySchemaModel`),
  but that tripwire is **model-level, not property-level**. The thumbnail is derived data, so it
  is deliberately *excluded* from `SnappetBackup` and regenerated on restore — the backup already
  carries ~1 GB of base64 photo bytes and must not carry more.

## Approach

Layered per the repo rules — the sizing *decisions* are pure and unit-tested, the pixel work is a
thin platform edge in `Services/`.

- **Pure policy** — `Features/Wardrobe/WardrobeImagePolicy.swift`. No UIKit. Owns the numbers and
  the arithmetic: display master ≤ **1024px** longest edge (the 240pt detail hero at 3x = 720px,
  so 1024 is right-sized with headroom), thumbnail ≤ **320px** (the largest tile use is 100pt =
  300px @3x). `fittedSize(for:maxEdge:)` returns the aspect-preserving target and **never upscales**;
  `needsDownscale(_:maxEdge:)` gates the migration. Cut-outs keep alpha ⇒ PNG; non-cut-out
  originals ⇒ JPEG. Unit-tested in `SnappetTests` with no simulator.
- **Platform edge** — `Services/WardrobeImageStore.swift`. `nonisolated` downscale via
  `UIGraphicsImageRenderer` with `format.opaque = false` so cut-out alpha survives;
  `prepare(image:isCutout:)` → `(display: Data, thumbnail: Data)`; `decode(_:)` force-decodes
  off-main (bake into a `CGContext`, like `AssetPosterLoader.decoded`) so no decode lands on a
  scroll frame. One `@MainActor` `NSCache` keyed by `itemID + which slot`, cost = decoded bitmap
  bytes, `totalCostLimit` sized for a full grid of thumbnails plus a few heroes.
- **Schema** — `WardrobeModels.swift` gains `var thumbnailData: Data? = nil`. Deliberately **not**
  `.externalStorage`: the whole point is that the grid's bytes ride the row fetch instead of
  costing 100 separate file reads. At ≤320px it is tens of KB, so ~100 items ≈ a few MB.
  `imageData` keeps `.externalStorage` and stays the display master.
- **Views** — `WardrobeItemTile` prefers **`thumbnailData`** and loads async+cached, falling back to
  the master only while the migration is still catching up (see the device-feedback note below).
  A new `WardrobeItemHeroImage` (same file) serves the one 240pt detail hero from `imageData`.
  `ClosetView` gets the three structural fixes: outer `LazyVStack` → `VStack` (≤8 sections, each
  grid still lazy), `sections` computed in a **single** grouping pass, and `filtered`/`stats`
  evaluated once per body rather than per category.
- **Migration** — `Services/WardrobeImageMigration.swift`, kicked off from the Wardrobe root's
  `.onAppear` (not app launch — a user who never opens Wardrobe should not pay for it) as an
  **unstructured task owned by the migration object**, NOT a `.task` modifier. **State is derived
  from the data, not a flag**: an item needs work iff `thumbnailData == nil` or its master exceeds
  the policy. That makes it idempotent, resumable after a kill, and self-healing after a restore.
  Processes **one item at a time inside an `autoreleasepool`** — batching 10 MB decodes is how this
  OOMs — and publishes progress for a dismissible banner.

## Device feedback, first pass (2026-08-02) — two bugs this prompt must not re-introduce

The first build shipped to MrRobot got both of these wrong; the fixes are folded into the Approach
above and pinned by `WardrobeImageMigrationTests`.

1. **The migration must not be owned by a view's `.task`.** SwiftUI cancels a `.task` when its view
   disappears, so tapping "See all ›" from the Wardrobe home into the closet cancelled the run —
   measured, it stopped at **exactly 31 of 100 items**, leaving 69 stranded and external storage at
   747 MB instead of ~126 MB. Own the work in an unstructured `Task` held by the `@Observable`
   migration object (which is `@State` on the root and survives the push).
2. **The tile must fall back to the master when no thumbnail exists yet.** The first revision showed
   the category emoji instead, which reads to the user as data loss. The justification ("falling back
   would reintroduce the stall") was simply wrong: the stall came from `UIImage(data:)` materializing
   the full ~34 MB bitmap, not from the file being large. `CGImageSourceCreateThumbnailAtIndex`
   downsamples *during* decode, so the fallback costs one larger file read and the same small decode.
   Keep the `imageData` touch inside the `.task` — never in the `.task(id:)` identity, which is
   evaluated on every body pass and would turn each one into a 10 MB externalStorage file read.

## Output

- `ios/App/Snappet/Features/Wardrobe/WardrobeImagePolicy.swift` — new, pure.
- `ios/App/Snappet/Services/WardrobeImageStore.swift` — new, platform edge + cache.
- `ios/App/Snappet/Services/WardrobeImageMigration.swift` — new, one-time reclaim.
- `ios/App/Snappet/Features/Wardrobe/WardrobeModels.swift` — `thumbnailData`.
- `ios/App/Snappet/Features/Wardrobe/WardrobeCaptureSheet.swift` — save through the pipeline.
- `ios/App/Snappet/Features/Wardrobe/ClosetView.swift` — tile rewrite, hero view, structural fixes.
- `ios/App/Snappet/Features/Wardrobe/WardrobeItemDetailView.swift` — hero uses the new view.
- `ios/App/Snappet/Features/Wardrobe/WardrobeRootView.swift` — migration kick-off + progress banner.
- `ios/App/SnappetTests/WardrobeImagePolicyTests.swift` — new.
- `pdd/context/decisions.md`, `docs/knowledge-graph/data.js` — same change.

## Acceptance criteria

- [ ] A newly captured cut-out stores a master ≤1024px and a thumbnail ≤320px; a 10 MB capture
      lands as roughly 1 MB + tens of KB.
- [ ] `WardrobeItemTile` reads `imageData` only inside its `.task` fallback — never from
      `tileIdentity` / the view body. No tile ever renders a placeholder for an item that has a photo.
- [ ] The migration survives navigating from the Wardrobe home into the closet mid-run.
- [ ] Migrating the real 100-item closet reclaims ≳880 MB and leaves every tile rendering.
- [ ] Migration is idempotent: running it twice does no work the second time, and killing the app
      mid-run resumes correctly on next open.
- [ ] Closet scrolls without hitching on MrRobot with all 100 items.
- [ ] `thumbnailData` is absent from `SnappetBackup`; a restore regenerates thumbnails via the
      migration path, and the backup round-trip test still passes.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine`; `WardrobeImagePolicy` imports Foundation only.
- [ ] `decisions.md` + `docs/knowledge-graph/data.js` updated in this change.

## Constraints

- On-device only; no backend/network. Downscale is destructive to the stored master by design
  (user-approved 2026-08-02: reclaim ~950 MB rather than keep unusable full-res pixels).
- CloudKit-compatible: inline defaults / Optional, no `.unique`, no relationships.
- State verification honestly: type-check ≠ device run. The reclaim number and the scroll feel are
  **device-only** claims and must be measured on MrRobot before they are reported as done.

## Test plan

1. `WardrobeImagePolicyTests` — fitted sizes preserve aspect, clamp the long edge, never upscale;
   `needsDownscale` is false for already-compliant sizes (so migration terminates).
2. Backup round-trip test still green; confirm the encoded blob does not contain thumbnail bytes.
3. `xcodebuild test -scheme Snappet` unit slice, then the UI slice (real UI changed here).
4. Device: install on MrRobot, open Wardrobe, watch the migration banner complete, then
   `xcrun devicectl device copy from --domain-type appGroupDataContainer --domain-identifier
   group.com.snappet.app` and `du -sh` the `_EXTERNAL_DATA` folder to verify the reclaim.
5. Scroll the full closet on device and confirm the hang is gone.
