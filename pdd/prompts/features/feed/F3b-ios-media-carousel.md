# Prompt: F3b — iOS session media carousel + grouped browser + fullscreen viewer (per-clip HR overlay + name tag)

**File**: pdd/prompts/features/feed/F3b-ios-media-carousel.md
**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: PLAN.md → F3b (depends on F3; consumes F0/F0b/F2; feeds F4)
**Source**: GitHub epic "Recap Feed" → issue [#227](https://github.com/harshal2802/Snappet/issues/227) "F3b iOS session media carousel + grouped browser + fullscreen viewer"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`
**Design**: `/tmp/feed-dossier/_locked-design.md` §5 (clipReady row + media cards), §6.3 (Pillar 3: auto-clip + HR overlay + name tagging), §7 (degradation: `SessionMedia` iOS-only), §8 (F3 lineage), §9 (reuse: `SessionMedia`/`ReelExporter`/`HighlightEngine`/`HRTile`/`StudioOverlays`)

## Goal

F3 gives a session card *one* inline auto-clip hero (the single active `AVPlayer` nearest viewport center). F3b makes the card own **all** of the session's media: an **Instagram-style carousel** of every `SessionMedia` clip/photo (paging dots + count badge + edge peek), a **grouped media browser** that re-buckets a session's media By exercise / By session / All over `assignedExerciseID`/`assignedClimbUUID` (`SessionMedia.swift:47-59`), and a **fullscreen Instagram-post viewer** where each clip carries a **per-clip HR overlay** (aligned via `SessionMedia.offsetSec` to the session's `hrSeries`/HealthKit timeline) plus an **exercise/climb name tag**. Tapping Share/Animate from the viewer burns that exact overlay into a clip via `ReelExporter` + `AVVideoCompositionCoreAnimationTool` (the WYSIWYG preview → export contract). This realizes Pillar 3's "auto-clip with HR overlay + name tagging" (`_locked-design.md:198`) at the *card* level, so the user sees their whole session's footage in context — not just the single auto-pick. iOS-only: `SessionMedia` does not exist on Android (`_locked-design.md:213`), so this never composes there. The **grouping + offset→HR alignment logic is pure and unit-tested**; the export/share/Photos paths are device-burn.

## Context the implementer needs

- **F3b is additive to F3's card, not a rewrite.** F3 shipped the inline single-clip hero. F3b adds a horizontally-paged carousel *into the same `FeedSessionCard` media slot* and a "View all (N)" affordance into the grouped browser. The keystone rule holds: no new `FeedCardKind` is invented here — F3b renders the media already attached to F0's `a1`/`a2` session cards and the `clipReady` eligibility (`_locked-design.md:177`); it edits **only** the F3 card view + new viewer files, never the F0 ordering core or composer registry.
- **`SessionMedia` is the source of truth** (`SessionMedia.swift:24`, SwiftData `@Model`). Per-clip fields F3b leans on: `id`, `sessionID` (`:31`), `localIdentifier` (the PHAsset handle, `:33`), `kindRaw`/`kind` (`:35`,`:81` — `.photo`/`.video`), **`offsetSec`** (session-relative start, `:37` — the HR-alignment key), `durationSec` (`:39`), `assignedExerciseID` (`:47`), `assignedSetIndex` (`:49`), **`assignedClimbUUID`** (`:59`), `isGeneral` (`:91`). Carousel order = stable sort by `offsetSec` then `id`.
- **Grouping toggle (By exercise / By session / All)** is a pure function over `[SessionMedia]`:
  - *By exercise/climb* → bucket on the non-nil of `assignedExerciseID` (workout) or `assignedClimbUUID` (climb), with the `isGeneral` (`SessionMedia.swift:91`) clips collected into a "General" bucket — never dropped.
  - *By session* → one bucket per `sessionID`, header = that session's discipline/date (the cross-session browser case, when the card surfaces media from more than one logged session).
  - *All* → flat, `offsetSec`-ordered.
  Bucket headers and ordering must be deterministic (stable by first-clip `offsetSec`, then bucket key) so the unit test pins exact output.
- **Per-clip HR overlay alignment is the pure heart of F3b.** Given a clip's `offsetSec` + `durationSec` and the session's HR timeline, compute the HR window `[offsetSec, offsetSec+durationSec]` and resolve the overlay payload: instantaneous/avg/peak BPM + zone for that window. Reuse the existing per-climb effort math (`KilterSessionStats.timeline[].effort`, `KilterSessionStats.swift:94-118`) and HR-window resolution (`WorkoutHRStats.secondsByZone`/`edwardsTRIMP`, `WorkoutHRStats.swift:16,76`) as the *source of zone/strain values*; F3b only slices them to the clip's offset window — it must **not** re-derive HR math. iOS HR series lives on `KilterSession.hrSeries` (`KilterModels.swift:326`, `[HRPoint]`); workout HR via the session's `hrSeries`/`WorkoutHRStats`. When the session has no HR (`hrSeries` empty), the overlay degrades to the name tag only (no empty chart — same degrade-by-absence rule as `_locked-design.md:196`).
- **Name tag** = the exercise or climb display name for the clip's bucket, resolved from `assignedExerciseID`/`assignedClimbUUID`. It is rendered into the visual **and** persisted as the structured `audienceTo`-style ref so a future account flip can resolve it (`_locked-design.md:198`, §4.5) — for F3b the display name is what's burned in; the ref is carried alongside.
- **Fullscreen viewer = Instagram-post grammar:** full-bleed paged `TabView(.page)` over the grouped/ordered clips, single active `AVPlayer` (extend F3's single-player discipline — only the centered page plays, others are paused/released), swipe between clips, HR overlay + name tag pinned, a Share/Animate button per clip. Tap-to-pause, double-tap reacts (reuse F2's reaction path).
- **WYSIWYG overlay → export contract.** The on-screen overlay and the burned overlay must be the *same* styling. Reuse the Glass-HUD overlay kit: `HRTile`/`HRTileView` (`HRTile.swift:224`, `HRTileView.swift:13`) for the visual, and `StudioOverlays.makeAnimationTool(...)` / `StudioOverlays.hrTileLayer(...)` (`StudioOverlays.swift:35,112`) for the `AVVideoCompositionCoreAnimationTool` burn. Export runs through `ReelExporter.export(_:)` (`ReelExporter.swift:24,164`). Heed the dossier export gotchas (`_locked-design.md:198`): drive only built-in CALayer props (custom props don't export), layer-instruction background = clear, run off-main-thread with cancellable progress, music omitted.
- **Asset loading** goes through `SessionMediaService` (`SessionMediaService.swift:14`) — fetch the `AVAsset`/thumbnail by `localIdentifier` (`SessionMediaService.swift:132`, `forIdentifiers:`). Never touch `PHAsset` directly from the view.
- **Share/Animate handoff:** F3b's viewer Share button is the entry into F4's `ShareComposerCover` pre-seeded with this clip + its resolved overlay; F3b stands up the **Animate export call path** end-to-end (overlay → `StudioOverlays` tool → `ReelExporter`) since that is the device-burn deliverable here, and appends a `ShareEvent` row (`channel: "export:instagram"` etc., `_locked-design.md:109`). The full template picker UI is F4's; F3b's Share is the direct "Animate this clip with its overlay" path.
- New files live in `ios/App/Snappet/Features/Feed/` (F0 created the dir); F3 created the inline-clip files this builds on.

## Approach

- `Feed/FeedMediaGrouping.swift` (**pure, testable**): `enum MediaGroupMode { byExercise, bySession, all }`; `struct MediaBucket { key, title, clips: [SessionMedia-snapshot], nameRef: ActivityRef? }`; `func group(_ media: [MediaSnapshot], mode:) -> [MediaBucket]` with deterministic ordering and a General bucket. Operates on a plain-value `MediaSnapshot` (id/offsetSec/durationSec/kind/assignedExerciseID/assignedClimbUUID/sessionID/displayName) so it runs in unit tests without SwiftData.
- `Feed/FeedClipHROverlay.swift` (**pure, testable**): `func overlayWindow(offsetSec:durationSec:hr:[HRPoint]) -> ClipHROverlay?` returning `{ avgBpm, peakBpm, zone, sparkline:[Double] }` sliced to the clip window, plus the name tag; returns `nil`/name-only when HR is absent. Slices existing `KilterSessionStats`/`WorkoutHRStats` outputs — no new HR math.
- `Feed/FeedMediaCarousel.swift`: the in-card horizontally-paged carousel (dots + "N" count badge + edge peek), thumbnails via `SessionMediaService`, "View all (N)" → grouped browser. Slots into F3's `FeedSessionCard` media area.
- `Feed/FeedMediaBrowser.swift`: the grouped browser sheet — segmented By exercise / By session / All toggle bound to `FeedMediaGrouping.group(...)`, bucket sections with name-tag headers, tap → fullscreen viewer at that index.
- `Feed/FeedMediaViewer.swift`: fullscreen Instagram-post `TabView(.page)`; single active `AVPlayer` (centered page only); `HRTileView`-rendered overlay + name tag pinned per clip; per-clip Share/Animate button.
- `Feed/FeedClipAnimateExport.swift`: the Animate path — build `ResolvedHRTile`/overlay items from `FeedClipHROverlay`, hand to `StudioOverlays.makeAnimationTool` → `ReelExporter.export`, off-main with cancellable progress, then append a `ShareEvent`. This is the device-burn edge; keep all decision/payload-shaping in the pure files above.
- Unit tests cover grouping (all three modes incl. General + cross-session) and offset→HR-window alignment (boundaries: clip fully before/after HR coverage, partial overlap, zero-duration photo, empty `hrSeries`). XCUITest covers card carousel paging → browser toggle → fullscreen swipe → overlay visible → Share affordance.

## Output

- `Feed/FeedMediaGrouping.swift` — pure `MediaGroupMode`/`MediaBucket`/`group(_:mode:)` over value snapshots (deterministic, General bucket).
- `Feed/FeedClipHROverlay.swift` — pure `overlayWindow(offsetSec:durationSec:hr:)` slicing existing HR stats + name tag; degrades to name-only when HR absent.
- `Feed/FeedMediaCarousel.swift` — in-card paged carousel (dots + count badge + peek + "View all").
- `Feed/FeedMediaBrowser.swift` — grouped browser sheet (By exercise/By session/All toggle, name-tag headers).
- `Feed/FeedMediaViewer.swift` — fullscreen Instagram-post viewer (single active `AVPlayer`, per-clip HR overlay + name tag, Share/Animate).
- `Feed/FeedClipAnimateExport.swift` — overlay-burn export path (`StudioOverlays` + `ReelExporter`), cancellable off-main, appends `ShareEvent`.
- Edit `Feed/FeedSessionCard.swift` (from F3) — swap the single-clip hero slot to host the carousel + "View all (N)".
- `SnappetTests/FeedMediaGroupingTests.swift` — all three group modes, General bucket, cross-session, ordering determinism.
- `SnappetTests/FeedClipHROverlayTests.swift` — offset→HR-window alignment boundary cases + empty-HR degradation.
- `SnappetUITests/FeedMediaCarouselUITests.swift` — carousel paging → browser toggle → fullscreen swipe → overlay + Share affordance.
- `docs/knowledge-graph/data.js` — add `feed-media-carousel`, `feed-media-browser`, `feed-media-viewer` nodes; `contains` edge feed→feed-media-carousel, `navigate` edges feed-media-carousel→feed-media-browser→feed-media-viewer, `uses` edges feed-media-viewer→`reel-exporter` (export), feed-media-viewer→`feed-export` (Share/Animate → F4 ShareComposer), `uses` edge feed-media-carousel→`session-media`.

## Acceptance criteria

- [ ] A session card shows an Instagram-style carousel of **all** its `SessionMedia` (paging dots + "N" count badge + edge peek), `offsetSec`-ordered; "View all (N)" opens the grouped browser. No regression to F3's auto-play (single active `AVPlayer`, centered item only).
- [ ] The grouped browser's By exercise / By session / All toggle re-buckets via `FeedMediaGrouping.group(...)` over `assignedExerciseID`/`assignedClimbUUID`/`sessionID`; `isGeneral` clips land in a "General" bucket (never dropped); bucket order/titles are deterministic.
- [ ] The fullscreen viewer is an Instagram-post `TabView(.page)` with a single active `AVPlayer`; each clip shows its **per-clip HR overlay** (aligned via `offsetSec`→`hrSeries` window, reusing existing `KilterSessionStats`/`WorkoutHRStats` values, not re-derived) + the **exercise/climb name tag**; a session with no HR degrades to name-tag-only (no empty chart).
- [ ] Share/Animate from the viewer burns the on-screen overlay into a clip via `StudioOverlays.makeAnimationTool` + `ReelExporter.export` (WYSIWYG: preview styling == burned styling), runs off-main with cancellable progress, omits music, and appends a `ShareEvent` row. (Device-burn — see Test plan.)
- [ ] `FeedMediaGrouping` + `FeedClipHROverlay` are pure (value snapshots, no SwiftData/AVFoundation imports) and fully unit-tested incl. boundary + empty-HR cases.
- [ ] iOS-only by construction (consumes `SessionMedia`); no Android impact. No new `FeedCardKind`/composer-registry entry added — the F0 ordering core is untouched.
- [ ] App type-checks against the iOS 18 SDK (Swift 6, 0 warnings); `decisions.md` updated if a non-obvious choice was made (e.g. overlay-window resolution at clip boundaries).

## Constraints

- On-device only; derive-on-read. Reuse `SessionMedia`/`SessionMediaService`, `HRTile`/`HRTileView`, `StudioOverlays`, `ReelExporter`, and F2's reaction path — no new media model, no new brand tokens, no re-derivation of HR math. Edit only the F3 card view + new viewer files; never the F0 composer/ordering core (keystone rule).
- Single active `AVPlayer` across carousel + viewer (memory discipline carried from F3). Overlay export must drive only built-in CALayer props, clear layer-instruction background, off-main with cancellable progress, music omitted (clean IG/iMessage handoff).
- State verification honestly: type-check ≠ device run. AVFoundation overlay export, the OS share sheet, and Photos `AVAsset` loading are **device-burn** — they cannot be proven in the simulator.

## Test plan

1. Unit: `FeedMediaGroupingTests` (By exercise/By session/All + General + cross-session + ordering) and `FeedClipHROverlayTests` (clip before/after/partial-overlap HR coverage, zero-duration photo, empty `hrSeries` → name-only) green; build-for-testing.
2. XCUITest: launch into Recap → open a session card with seeded `SessionMedia` → page the carousel (dots/count update) → "View all" → toggle By exercise/By session/All → open fullscreen → swipe between clips → assert HR overlay + name tag present → assert Share/Animate affordance. Sim wedge → `xcrun simctl shutdown all`, re-run.
3. Device-burn (real iPhone, real Photos library + HR session): verify the carousel loads actual clips, the fullscreen overlay matches per-clip HR, and Share/Animate exports a clip with the burned overlay (WYSIWYG) to the OS share sheet with a `ShareEvent` appended — flagged as a device-burn item, not sim-provable.
