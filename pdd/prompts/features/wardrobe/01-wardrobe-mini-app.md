# Prompt: Wardrobe mini-app — your private AI stylist (prompt 122)

**File**: pdd/prompts/features/wardrobe/01-wardrobe-mini-app.md
**Created**: 2026-07-11
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone (new mini-app; wireframes approved first — `docs/ux-research/wardrobe/wireframes.html`)
**Source**: user request 2026-07-11 (wardrobe manager; approved with two amendments — see Goal)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

A new **Wardrobe** mini-app: a local-first digital closet with on-device AI styling —
"your private AI stylist that runs entirely on your iPhone." No account, no backend, no
cloud AI; photos and metadata never leave the device. MVP scope (wireframed and
user-approved): capture (camera/Photos) with background removal → on-device auto-tagging
(category · color · pattern · style · material · season) → browse/search/filter closet →
**"For You" suggested-outfits feed** (the user *picks*, not builds — added at wireframe
review) → custom occasion generator → style-coach Q&A → flat-lay collage board → outfit
history + wear log → suite-level backup. Second wireframe-review amendment: **no live
CloudKit yet, but the data model must be CloudKit-compatible from day one** so
Snappet-level sync/backup can be layered on with zero migration.

## Context the implementer needs

- Mini-apps are `AppModule`s collected in `Core/ModuleRegistry.swift`; Wardrobe is the
  first **Lifestyle**-category module (new `ModuleCategory.lifestyle`) with a new rose
  accent (`SnappetColor.wardrobe`, light `#C13A6F` / dark `#E86B99` — the one unused hue family).
- Adding `@Model`s to `SnappetSchema.models` REQUIRES mirror Rows in `Core/SnappetBackup.swift`
  (`SnappetBackupTests.testCodecCoversEverySchemaModel` is the tripwire). This satisfies the
  "Snappet-level backup" requirement — **no wardrobe-only backup codec**.
- The Apple-Intelligence pattern to follow is `Services/WorkoutPlanIntelligence.swift`
  (E7): heuristic floor always computed, FM pass only refines, `#if canImport(FoundationModels)`
  + iOS 26 availability, silent degradation, on-device only.
- Sim/UITests can't use Photos → a seeded **sample closet** (no images; category-emoji
  placeholder tiles) is the fixture path, like the Kilter sim fixtures.

## Approach

Layered per the repo rules — pure decisions, thin platform edges:

- **Pure keystone** (`Features/Wardrobe/`): `WardrobeTags.swift` (closed enums: category /
  color-family with 16-family harmony model / pattern / style→formality / season / temp band /
  occasion→formality window + free-text nudge; Vision-label→category and RGB→family mappings);
  `OutfitComposer.swift` (greedy slot-fill scored on formality fit + color harmony + season +
  freshness, `forYou()` daily feed with rotation/weather/favorite intents, `alternatives()` for
  board swaps, SplitMix64-seeded shuffle); `WearStats.swift` (cost-per-wear, rarely-worn, pills).
- **SwiftData** (`WardrobeModels.swift`): `WardrobeItem` (raws-stay-raw enum fields,
  `@Attribute(.externalStorage) imageData`), `WearEvent` (append-only), `WardrobeOutfit`
  (parallel itemIDs/slotRoles arrays). CloudKit-compatible: inline defaults everywhere,
  no `.unique`, no SwiftData relationships (plain UUID FKs like the rest of the suite).
- **Services**: `WardrobeVision.swift` (subject lift via `VNGenerateForegroundInstanceMaskRequest`,
  `VNClassifyImageRequest`, average-of-opaque-pixels dominant color — pixels only, decisions in
  WardrobeTags); `WardrobeIntelligence.swift` (tag sharpener + style coach on the E7 contract).
- **Views**: `WardrobeRootView` (Closet · For You · Outfits glass bottom bar + privacy empty
  state), `ClosetView`, `WardrobeCaptureSheet`, `WardrobeItemDetailView` (+ edit sheet),
  `StyleCoachView`, `WardrobeStyleViews.swift` (ForYou / Generator / Board), `OutfitHistoryView`,
  `WardrobeSettingsView` (points at the suite `BackupView`).
- **Weather v1** = season-by-month default + manual season/temp override (WeatherKit needs an
  entitlement + capability — recorded follow-up; the composer only consumes a season + temp band).

## Output

Everything above, plus: `ModuleRegistry`/`SnappetColor`/`AppModule` wiring, backup Rows +
seeds in `SnappetBackupTests` (recordCount 28 → 31), `WardrobeSampleCloset` fixture,
unit tests (`OutfitComposerTests`, `WardrobeTagsTests`), `WardrobeUITests` walkthrough,
knowledge-graph nodes/links, wireframes under `docs/ux-research/wardrobe/`.

## Acceptance criteria

- [x] Wardrobe appears in the App Library under Lifestyle; opens to the privacy empty state.
- [x] Sample closet seeds 13 items; closet grid sections/search/filter/wear-pills render.
- [x] Composer: work occasion picks smart pieces over athletic; cool weather adds a layer;
      summer excludes fall-only items; build-around anchors; same seed ⇒ same outfit;
      only owned items ever appear (unit-tested).
- [x] For You emits ≤3 distinct-intent suggestions, deterministic per day, rotation card
      targets the stalest piece (unit-tested).
- [x] Wear today / Wear again write one `WearEvent` per piece; cost-per-wear updates.
- [x] Coach heuristic floor answers cite only owned items (unit-tested); FM pass optional.
- [x] Backup round-trip covers the three new models incl. image bytes (SnappetBackupTests).
- [x] App changes type-check against the iOS 18 SDK (Swift 6); unit suite green (1682).
- [ ] Device legs (owed): camera capture → subject lift on a real garment; Apple-Intelligence
      tag/coach pass on an iOS-26 device; photo-import path with a real Photos library.

## Constraints

- On-device only; no backend/network/accounts; no cloud AI. The AI never *picks* outfit
  items — selection stays in the pure, unit-tested composer; FM only refines copy/tags.
- CloudKit-compatible model shape is a hard constraint (defaults, no unique, optionals).

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — engine/tags/stats/backup suites.
2. `xcodebuild test … -only-testing:SnappetUITests/WardrobeUITests` — sample-closet walkthrough
   (empty state → closet → item → For You → board → save → Outfits).
3. Device (owed): capture a real shirt on MrRobot; verify cut-out, tags, and a For You card.
