# Prompt: Clips — WYSIWYG feed HR (render the session's saved Studio tile)

**File**: pdd/prompts/features/89-ios-clips-wysiwyg-hr.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 84 (Clips HR SSOT) → the optional WYSIWYG follow-up (#2)
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## Goal

Make the Clips feed poster's HR overlay reflect the **session's saved Studio HR tile** — so editing the
HR chart in the Studio (⋯ → Edit this clip) updates the feed poster — instead of the fixed
`.feedClipScorebug` house style. (This answers the on-device Q "if I edit the HR chart, does the feed
update?": with prompt 89, yes.) A **product call** flagged earlier — feeds usually keep a stable house
style; this opts the feed into WYSIWYG.

## Context the implementer needs

- The Studio stores its HR tile at `StudioProject.hrOverlay?.tile` (an `HRTile`), edited via
  `StudioEditorViewModel`. One project per session (`StudioEntry`, `sessionID`-keyed).
- The poster builds its overlay through the `ClipHROverlay` SSOT (prompt 84) → `HRTileView`. The tile's
  **content** (template / metrics / colours) is WYSIWYG; the feed keeps its own placement (the compact
  bottom strip), NOT the project's export-canvas geometry.

## Approach

- `ClipHROverlay.make(…, tile: HRTile? = nil)`: when `tile` is supplied, use it; else `.feedClipScorebug`
  (the Recap viewer + any non-Clips caller pass nil and keep the house style).
- `ClipsFeedView`: `@Query [StudioProject]` (so a Studio edit re-renders the feed) → a
  `sessionHRTile: [UUID: HRTile]` map (sessionID → `hrOverlay?.tile`, present only when customized) →
  thread `sessionHRTile[post.sessionID]` to `ClipPostCard` → into `ClipHROverlay.make(tile:)`. No
  find-or-create — read existing projects only (no side effects); no saved tile → the scorebug fallback.

## Output

- `ios/App/Snappet/Features/Feed/ClipHROverlay.swift` (the `tile:` override) + `ClipHROverlayTests`.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — the projects query + the tile map + threading.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] When a session has a customized Studio HR tile, the feed poster renders THAT tile (template/metrics/
      colours); editing it in the Studio updates the feed. No saved tile → the `.feedClipScorebug` fallback.
- [ ] The Recap fullscreen viewer is unchanged (still the scorebug — passes `tile: nil`).
- [ ] `ClipHROverlay.make(tile:)` covered by a unit test. App type-checks (Swift 6, 0 warnings); suite green.

## Constraints

- No new persistence — read the existing `StudioProject`. The feed renders the tile at its OWN placement
  (the compact strip), not the project's export geometry; a big template (e.g. hero) will read compact in
  the feed (acceptable tradeoff for the common scorebug case).

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — the `make(tile:)` test + suite green, 0 warnings;
   `ClipsFeedUITests` green.
2. On a device: edit a clip's HR tile in the Studio (toggle a metric / change the template), return to the
   feed → the poster reflects it.
