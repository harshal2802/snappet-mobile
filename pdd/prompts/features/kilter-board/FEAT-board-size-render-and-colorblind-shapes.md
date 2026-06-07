# Prompt: Kilter Board — pick board size on the climb page, render the board at that size, and color-blind hold shapes

**File**: pdd/prompts/features/kilter-board/FEAT-board-size-render-and-colorblind-shapes.md
**Created**: 2026-06-07
**Project type**: Native iOS + Android feature (Swift / Kotlin) — code lands in this repo.
**Chain**: Kilter Board mini-app (#35) → board-render fidelity + accessibility →
[FIX-board-size-led-mapping] (this builds on the board-size preference that fix introduced)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`,
`pdd/prompts/features/kilter-board/RESEARCH.md`

## Goal

Three board-design improvements on the climb screen, in one job:

1. **Board size lives next to layout.** A user picks their physical board size right on the browse page
   (a chip beside Layout), not only buried in Settings / the "wrong holds?" escape hatch. The choice is
   cached (it already is — `kilter.productSizeId`), seeded per layout, and reset when the layout changes.
2. **The on-screen board reflects the chosen size.** Today every size of a layout renders an *identical*
   schematic, because the grid + aspect come from the whole layout's hole extent — board size only
   affected which LEDs light. Make the rendered grid + aspect + hold normalization track the selected
   `product_size`, so a 7×10 reads shorter than a 12×14 and the lit holds sit on the right grid.
3. **Color-blind-friendly holds.** Replace the all-circles render with a distinct **shape per role**
   (start / hand / finish / foot) so the route is legible without relying on hue. Colors stay; shape is
   the redundant channel. The legend teaches the shape code.

No real board photos: this repo ships **no** Aurora data (#42) and the board background images are
copyrighted Aurora CDN assets keyed by `product_sizes_layouts_sets.image_filename`, so they can't be
committed. The schematic is improved instead (size-accurate), not replaced with a photo.

## Context the implementer needs

- **Where the size already is**: `kilter.productSizeId` (`@AppStorage` / SharedPreferences), pickable in
  `KilterSettingsView`/`KilterSettingsScreen` and the inline "wrong holds?" control on the detail screen.
  It is **not** on the browse filter bar. `KilterCatalog.sizes(forLayout:)`/`defaultSizeId`/
  `effectiveSizeId` already exist.
- **Why the render ignores size today**: `KilterCatalog.boardGeometry(forLayout:)` computes the extent +
  grid from `MIN/MAX(h.x,h.y)` over *all* the layout's placements, and `holds(for:sizeId:)` normalizes
  against that same whole-layout extent. `sizeId` only selects the `leds` LED mapping.
- **The size-accurate basis**: the `leds` table is keyed `(product_size_id, hole_id) → position`. The set
  of `hole_id`s wired for a size **is** that physical board's hole set (7×10 ≈ 225, 12×14 ≈ 527, …). Its
  bounding box ≈ the visible board rectangle for that size. This is authoritative, already loaded for LED
  mapping, and present in both the synthetic fixture and a real catalog. (A future catalog exposing
  `product_sizes.edge_*` could crop pixel-perfectly; the LED-hole-set bbox is the portable approximation.)
- **The render sites**: iOS `KilterBoardView` (used by `KilterClimbDetailView`); Android `KilterBoard`
  (used by `KilterDetailScreen`). All lit holds are circles today; the grid dots are faint circles.
- **Fixtures are mirrored 4×**: `tools/kilter/build_test_fixture.py`, the checked-in
  `tools/kilter/kilter-fixture.sqlite3`, and the Swift / Kotlin `KilterCatalogFixture`. The two existing
  sizes both cover all 25 holes (both named "5 x 5"), so they can't *prove* size-accurate geometry — a
  third, genuinely smaller size is needed.

## Approach

- **Catalog (pure, both platforms)** — `KilterCatalog.{swift,kt}`:
  - Add a size-aware render extent: `renderExtent(forLayout:sizeId:)` = bbox of the layout's holes that
    are wired for the size (`leds` keys ∩ the layout's placement holes). `sizeId == 0` or a size with no
    LED set → the whole-layout extent (preserves today's behavior + older catalogs).
  - `boardGeometry(forLayout:sizeId:Int = 0)` builds the grid from that same hole set + aspect from that
    extent; cache by `(layoutId, sizeId)`. `holds(for:sizeId:)` normalizes x/y against `renderExtent` so
    lit holds line up with the size grid. LED-position resolution is unchanged (still `effectiveSizeId`).
  - Add a **pure** `KilterHoldShape` (`circle/triangle/square/diamond`) with `forRole(_:)`:
    start→triangle, finish→square, foot→diamond, hand/middle/default→circle.
- **Board render** — `KilterBoardView.swift` / `KilterBoard.kt`: draw each lit hold as its role's shape
  (stroked when unlit, filled + glow when lit); grid dots stay faint circles. Legends in
  `KilterClimbDetailView` / `KilterDetailScreen` draw the role shapes, not plain dots.
- **Size on the climb page** — `KilterRootView.swift` / `KilterRoot.kt`: a "Size" chip beside Layout,
  shown when `sizes(forLayout:).count > 1`, bound to `kilter.productSizeId`, with the same
  seed-default / reset-on-layout-change guard Settings uses. The detail screen passes the selected
  `sizeId` to `boardGeometry` and recomputes geometry **and** holds when the size changes.
- **Fixture** — add a 3rd product size (a 5×3 "Test Mini" covering only the bottom three rows, holes
  1–15) to all four mirrors so `boardGeometry(sizeId: 3)` differs (15 holes, aspect 2.0) from sizes 1/2
  (25 holes, aspect 1.0). Update the `[1,2] → [1,2,3]` size assertions; add geometry + shape tests.

## Output

- `KilterCatalog.swift` / `KilterCatalog.kt` — size-aware `renderExtent`/`boardGeometry(sizeId:)`/`holds`
  normalization + `KilterHoldShape.forRole`.
- `KilterModels.swift` — `KilterHoldShape` (pure, no SwiftUI).
- `KilterBoardView.swift` / `KilterBoard.kt` — per-role shapes; `KilterClimbDetailView.swift` /
  `KilterDetailScreen.kt` — pass `sizeId` to geometry, recompute on size change, shape legend.
- `KilterRootView.swift` / `KilterRoot.kt` — Size chip + seed/reset.
- `tools/kilter/build_test_fixture.py` + regenerated `kilter-fixture.sqlite3` + Swift/Kotlin
  `KilterCatalogFixture` — 3-size fixture.
- `KilterCatalogStoreTests.swift` / `KilterCatalogStoreTest.kt` — updated size asserts + new
  size-accurate-geometry test; a pure `KilterHoldShape` mapping test on each platform.
- `docs/knowledge-graph/data.js` (`kilter-catalog`, `kilter-catalog-db`, `kilter-detail`) + `decisions.md`
  + `project.md` updated in the same change.

## Acceptance criteria

- [ ] A Size chip appears next to Layout on the browse page when the layout has >1 size; the choice
      persists, seeds to the layout default, and resets when the layout changes.
- [ ] `boardGeometry(forLayout:sizeId:)` returns a different grid/aspect per size where the sizes differ
      (proven by the fixture's 3rd size); `sizeId 0` and sizes with no LED set fall back to whole-layout.
- [ ] Lit holds normalize to the same size extent as the grid (they line up); changing the size on the
      detail screen re-renders the board at the new size.
- [ ] Every lit hold draws its role's shape (start triangle / hand circle / finish square / foot diamond),
      colors retained; the legend shows the shapes. `KilterHoldShape.forRole` is unit-tested off-device.
- [ ] LED-address selection + `led_color` behavior is unchanged (the prior board-size fix's test stays
      green); 3-size fixture mirrored across all four sources.
- [ ] iOS type-checks (Swift 6, 0 warnings); Android compiles; `decisions.md` + knowledge graph updated.
- [ ] **Device-pending**: shape legibility for a real color-blind user, and that the board photo absence
      is acceptable, are visual judgments to confirm on a device.

## Constraints

- On-device only; no backend/network/accounts; no copyrighted board images committed. Keep iOS + Android
  behavior-identical and the catalog logic pure (unit-testable without a simulator).
- Don't change the wire format or the LED address/`led_color` source — this is the on-screen render basis
  + a redundant shape channel, not the BLE packet.
- State verification honestly: unit tests prove the geometry math + shape mapping; shape *legibility* and
  the missing-photo trade-off are device/visual judgments.

## Test plan

1. iOS: `xcodebuild test -scheme Snappet -only-testing:SnappetTests` runs the updated size test, the new
   size-accurate-geometry test, and the `KilterHoldShape` mapping test. Android: `./gradlew
   :app:testDebugUnitTest` (pure shape test) + `assembleDebugAndroidTest` (instrumented mirrors).
2. Regenerate the binary fixture: `python3 tools/kilter/build_test_fixture.py --out
   tools/kilter/kilter-fixture.sqlite3` and confirm it still validates (climbCount 4).
3. By eye on the simulator: pick a layout with >1 size, switch sizes on the browse chip, open a climb,
   confirm the board reshapes and holds draw role-coded shapes with a matching legend.
