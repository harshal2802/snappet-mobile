# Prompt: Clips — adaptive tile sizing (no black bars)

**File**: pdd/prompts/features/92-ios-clips-adaptive-tile-size.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips playback-polish pass (2 of 4) → user-reported "all tiles are the same size … black space".
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Every Clips post renders in a fixed full-width × **460pt** box with an aspect-**fit** video, so a portrait
clip shows pillarbox bars (the reported screenshot) and a landscape clip would letterbox. Size each post's
carousel to its clip's **real, orientation-corrected** aspect — clamped Instagram-style — so the media
fills the tile edge-to-edge with no black bars.

## Context the implementer needs

- The carousel hard-codes `.frame(height: 460)` (ClipsFeedView.swift, `ClipPostCard.carousel`); the inline
  player uses `AVPlayerLayer .resizeAspect` on a black backing (StudioPlayerLayerView.swift:22) and the
  still poster aspect-fits — so any clip whose aspect ≠ the box aspect bars.
- **No dimension/aspect is stored** today: `SessionMedia` and `MediaInput` carry only
  localIdentifier/kind/offset/duration/assignment.
- A `TabView(.page)` carousel shares **one** height across a post's clips, so the per-post height must come
  from a **single** clamped aspect, not per-clip.
- An orientation-correct aspect source already exists: `StudioComposer.sourceAspect` computes
  `orientedSize(naturalSize, preferredTransform).width / .height` for video; photos can use
  `PHAsset.pixelWidth/pixelHeight`.

## Approach

- **Persist, don't read on the render path.** Add `var aspectRatio: Double?` (width/height,
  orientation-corrected) to `SessionMedia` — additive optional ⇒ SwiftData lightweight migration (the
  `assignedClimbUUID` pattern).
- **New `ClipAspectResolver`** (`ios/App/Snappet/Services/`, device I/O — keeps AVFoundation/Photos out of
  pure code): `aspect(localIdentifier:kind:) async -> Double?` — photo → `PHAsset.pixelWidth/pixelHeight`;
  video → oriented natural size (reuse the `StudioComposer.sourceAspect` math). In-memory cache by id.
- **Lazy backfill** so existing clips converge with no migration of old rows and no capture-path churn:
  `ClipPostCard` `.task`/`.onAppear` resolves + writes `aspectRatio` for any of its clips still `nil`; the
  `@Query` re-renders and the post resizes once. (New captures backfill the first time they appear too.)
- **Bridge + pure math.** Add `var aspect: Double?` to `MediaInput` (FeedMedia.swift) and copy it in
  `MediaInput.from`. In `ClipFeedComposer.posts`, derive ONE per-post aspect → `ClipFeedPost.aspect: Double`
  = the first non-nil clip's aspect, **clamped to [0.8 (4:5 portrait), 1.91 (1.91:1 landscape)]**,
  defaulting to `0.8` when all nil. Pure ⇒ unit-tested.
- **Layout.** In `ClipPostCard.carousel`, replace `.frame(height: 460)` with a width-driven
  `.frame(height: contentWidth / post.aspect)` (read the card content width). Once the box matches the
  clip's aspect, `.resizeAspect` shows no bars. (A rare mixed-orientation post keeps one height; the
  off-aspect page may fill-crop or fit — acceptable.)

## Output

- `ios/App/Snappet/Features/WorkoutTracker/SessionMedia.swift` — `aspectRatio: Double?`.
- `ios/App/Snappet/Services/ClipAspectResolver.swift` (new).
- `ios/App/Snappet/Features/Feed/FeedMedia.swift` (`MediaInput.aspect`), `FeedInputs.swift` (copy it),
  `ClipFeedComposer.swift` (`ClipFeedPost.aspect` + clamp/pick), `ClipsFeedView.swift` (height + backfill).
- `ios/App/SnappetTests/ClipFeedComposerTests.swift` — clamp/pick/default cases.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/snappet-core-schema.md`
  (the new `SessionMedia.aspectRatio` field).

## Acceptance criteria

- [ ] A portrait clip renders a tall tile with **no side bars**; a landscape clip a short tile with no
      top/bottom bars; tiles never exceed the [4:5 … 1.91:1] clamp.
- [ ] Existing on-device clips backfill their aspect on first view and resize once (no app-wide migration).
- [ ] `ClipFeedComposer`'s clamp/pick/default is unit-tested; full `SnappetTests` green.
- [ ] App type-checks (Swift 6, 0 warnings); SwiftData migration is lightweight (no model-version break).
- [ ] No platform imports in `HighlightEngine`; `decisions.md` + schema updated.

## Constraints

- Keep the feed **derive-on-read** (no new store beyond the additive `aspectRatio`). Device I/O lives only
  in `ClipAspectResolver`; the composer stays pure.
- Simulator / iCloud-only assets can return nil dimensions → fall back to the `0.8` default (fine for
  UITests, which run on the simulator).

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — composer clamp/pick tests + full suite green; build
   0-warning. `ClipsFeedUITests` still green (default aspect on the sim).
2. On a device with a portrait and a landscape clip: confirm both fill their tiles with no black bars.
