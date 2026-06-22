# Prompt: Clips — a video-first media feed tab (vertical slice)

**File**: pdd/prompts/features/82-ios-clips-feed.md
**Created**: 2026-06-21
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: post-v1 Live Workout Capture + Video Studio (#15) → media surfacing
**Source**: product request (Instagram-style video/photo feed) — wireframe in `docs/wireframes/media-feed-wireframe.html`
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Add a new **Clips** tab — a video/photo-first feed where the media *is* the post, Instagram-style —
distinct from the existing **Recap** tab (which shows session-summary *cards* with a small in-card
carousel). One post = one exercise or one climb; its clips are a swipeable carousel; each clip shows
the live HR scorebug + a climb/exercise name overlay (the same look the Studio burns in); a ⋯ menu
opens the Studio scoped to the clip(s) or jumps to the owning session. This is the read-only **vertical
slice**: reactions / share / explore-grid are a deliberate follow-up.

The whole feature is *composition* over existing pieces — there is no new persistence. The session
remains the single source of truth; the feed only reads.

## Context the implementer needs

- The middle tab today is **Recap** (`SuiteTab.feed` → `FeedView`, "sparkles.rectangle.stack"). This
  new tab is a SEPARATE case so the two feeds stay distinct. To avoid a confusing "two tabs both feel
  like Feed", the new tab's case + label is **`clips` / "Clips"** (not "Feed"); RootShell order becomes
  Home · Clips · Recap · Apps.
- Clip→post grouping ALREADY exists and is reused verbatim: `FeedMedia.groups(_:by:.byExercise,nameFor:)`
  buckets a session's media by `groupKey` (`assignedExerciseID` → else `assignedClimbUUID` → else
  "general"); `FeedMedia.ordered(_)` orders a group's clips by `offsetSec`. `MediaInput` has no
  `sessionID`, so bucket `SessionMedia` by `sessionID` at the @Model edge FIRST, then group within each
  session.
- HR overlay: reuse the editor's `HRTileView(tile:values:fraction:)` with a `.scorebug` tile and
  `HROverlayValues(samples:durationSec:maxHR:restHR:)` fed by `FeedMedia.clipHRWindow(...)` — exactly
  how `MediaBrowserView`'s fullscreen viewer composes it (a STYLE-match to the export burn, decisions
  2026-06-21). Posters are STILL frames (`ClipThumbnail`) — the single-active-player discipline holds;
  real inline playback / a fullscreen player is out of slice (device-only anyway).
- The ⋯ menu's three actions map to real entry points:
  - **Edit this clip** → present base `StudioEditorView(project:context:focusClipMediaID:[id]:visibleClipMediaIDs:[id])`.
  - **Edit all · N** → same, `visibleClipMediaIDs = Set(post.clip ids)`, focus = first.
  - **Go to session** → `router.open(module:)` + `router.push(KilterSessionRoute/SessionRoute(id:))`
    (the `CardDetailView` cross-module pattern).
  The project comes from `StudioEntry` (find-or-create by `sessionID`, reconciles late-discovered
  clips). `AppModel` is injected app-wide (`SnappetApp` → `.environment(appModel)`), so the editor's
  `@Environment(AppModel.self)` resolves from the feed. For BOTH gym and Kilter we present the BASE
  `StudioEditorView` (not `KilterClipStudio`) — the Kilter climb-reassign panel is out of slice; the
  editor still loads the same shared project (clips, climb-name overlays, HR tile).

## Approach

Pure core (`Features/Feed/ClipFeedComposer.swift`, Foundation-only, unit-tested in `SnappetTests`):
turns per-session media bundles + climb/exercise name maps into `[ClipFeedPost]` (one per exercise/climb
group, ordered by capture time desc), each post carrying ordered `ClipFeedItem`s with a derived
attempt/set label. No SwiftData, no SwiftUI — `MediaInput`/`FeedMedia`/`HRPoint` only.

Surface (`Features/Feed/ClipsFeedView.swift`): a derive-on-read tab like `FeedView` —
`@Query` `SessionMedia` + `KilterSession`/`WorkoutSession`/`KilterLogEntry`, snapshot into pure values
at the edge, compose, render a `LazyVStack` of post cards. Each card: header (climb/exercise name +
session subtitle + ⋯), a paged carousel of poster + HR-scorebug + name overlay, and a meta line. The
⋯ menu drives a `.fullScreenCover` Studio presentation and router navigation.

Tab wiring: add `SuiteTab.clips`; add the tab item in `ShellTabs` between Home and Recap; add a
`snappet://clips` deep-link host in `RootShell.handle`.

`StudioEntry`: add a `sessionID`-keyed `findOrCreateProject` / `resolveProject` overload (the existing
`WorkoutSession` ones delegate to it) so the feed can resolve a project for a Kilter session too.

Knowledge graph: add `clips-feed` (screen), `clips-feed-core` (engine), `tab-clips` (shell) nodes and
wire links to `model-sessionmedia`, `studio-editor`, `hr-tile-frame`, `kilter-session-detail`, the gym
session detail, and the shell.

## Output

- `pdd/prompts/features/82-ios-clips-feed.md` (this file).
- `ios/App/Snappet/Features/Feed/ClipFeedComposer.swift` — pure `ClipFeedPost`/`ClipFeedItem`/`ClipFeedComposer`.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — the tab view + post card + poster + ⋯ menu.
- `ios/App/SnappetTests/ClipFeedComposerTests.swift` — pure XCTest.
- `ios/App/Snappet/Core/SuiteRouter.swift` — `SuiteTab.clips`.
- `ios/App/Snappet/Features/Shell/RootShell.swift` — tab item + `snappet://clips`.
- `ios/App/Snappet/Features/WorkoutTracker/StudioEntry.swift` — `sessionID`-keyed project resolve.
- `docs/knowledge-graph/data.js` — nodes + links.
- `pdd/context/decisions.md`, `pdd/context/project.md` — the decision + state.

## Acceptance criteria

- [x] A 4th bottom tab "Clips" appears between Home and Recap; `snappet://clips` selects it. *(macOS
      gate: confirmed on the iOS 26.5 sim — screenshot + `ClipsFeedUITests` + cold `simctl openurl`.)*
- [x] The feed shows one post per exercise/climb that has ≥1 clip, newest capture first; a post with N
      clips shows a swipeable carousel with a working page count. *(Grouping/ordering/labels covered by
      `ClipFeedComposerTests`; the carousel UI + page count render with media — owed on-device.)*
- [~] Each poster overlays the HR scorebug (when HR exists for that clip's window) + the climb/exercise
      name + an attempt/set chip. *(Owed on-device — needs real Photos assets + a captured HR series; a
      fresh-store sim shows only the empty state. Reuses the device-validated editor `HRTileView`.)*
- [~] The ⋯ menu opens the Studio scoped to the current clip ("Edit this clip"), to all the post's clips
      ("Edit all · N"), and routes to the owning session ("Go to session"). *(Routing wired to the proven
      `StudioEntry` / `SuiteRouter` entry points; exercising the menu needs a post — owed on-device.)*
- [x] No new `@Model` / no schema change — the feed reads `SessionMedia` + the session models only.
- [x] `ClipFeedComposer` is pure and covered by `ClipFeedComposerTests` (grouping, ordering, labels). *(7/7 green.)*
- [x] App changes type-check (Swift 6, 0 warnings). *(`** TEST BUILD SUCCEEDED **` on the iOS 26.5 SDK;
      full `SnappetTests` suite 1437/0-fail; 0 warnings in the new files.)*
- [x] No platform imports added to `HighlightEngine`. *(`HighlightEngine` untouched.)*
- [x] `decisions.md` updated; knowledge graph updated in the same change.

## Constraints

- On-device only; no backend/network/accounts. No new persistence — derive-on-read over the session.
- This repo can only be BUILT/TESTED on macOS + Xcode. Authored on Linux here; the `xcodebuild`
  type-check + `SnappetTests` run + the simulator pass are owed at the merge gate (state honestly).

## Test plan

1. `cd ios/App && xcodegen generate` (new files auto-included via folder globbing), then
   `xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` —
   `ClipFeedComposerTests` green + whole suite green; 0 warnings.
2. On the sim: open the Clips tab; confirm posts group per climb/exercise, the carousel pages, the HR
   scorebug + name overlay render, and each ⋯ action lands (Studio scoped / session detail).
3. `xcrun simctl openurl booted snappet://clips` selects the tab.
