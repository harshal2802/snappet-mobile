# Prompt: Clips — smooth the carousel swipe "takeover" flick

**File**: pdd/prompts/features/95-ios-clips-carousel-takeover-smoothness.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips playback-polish pass (follow-up to 90–94) → user-reported residual "flick" when a
horizontal-carousel swipe settles and the next clip "takes over". Round 5 of the on-device flicker loop
(rounds 1–4 in `decisions.md`: blur off → feed cached → warm-mount deferred → `isReadyForDisplay`-gated
poster→video crossfade).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Kill the residual carousel-swipe "flick" at the exact moment a new clip centers and starts playing — without
reworking the carousel or regressing the native paged-scroll feel.

## Investigation (already done — don't redo)

- **120fps frame analysis of an on-device capture proved the slide itself is frame-clean** (no blank/black/
  poster-drop frame). The flick is a **content discontinuity at takeover**, not a dropped frame.
- A 7-agent design workflow (1 mapper · 3 coded approaches · 3 adversarial judges) localized the ROOT cause:
  `ClipThumbnail`'s video still comes from `AssetPosterLoader.poster` → `PHImageManager.requestImage`, which
  for a **video** returns Photos' arbitrary key-frame thumbnail — **not the clip's frame-0**. The existing
  `isReadyForDisplay` reveal (ClipMediaSurface, 0.18s) then crossfades the player's *actual* frame-0 over that
  *different* still → a visible image JUMP. It only shows on a NORMAL/FAST swipe (the page centers on its
  poster before the warm player decodes); a SLOW swipe is already smooth (neighbour warm + `layerReady` true
  before centering — the user confirmed this tell).
- Judges (2 of 3, third concurring as a graft) picked **eliminate the mismatch at the source** over masking
  it, and **unanimously flagged a `.simultaneousGesture(DragGesture)` on the `TabView(.page)` as the one
  real ship risk** (it can contend the native paged scroll + the tap-to-fullscreen / mute hit-testing) — so
  that idea is deferred, not shipped.

## Approach (Approach B as the spine + two safe grafts)

1. **Frame-0 poster (the fix).** Add `AssetPosterLoader.videoFrameZero(localIdentifier:pointSize:)` —
   `PHImageManager.requestAVAsset` (local-only, mirroring `poster`) → `AVAssetImageGenerator` at `CMTime.zero`
   with `requestedTimeToleranceBefore/After = .zero`, `appliesPreferredTrackTransform = true`,
   `maximumSize = 3× pointSize`; memoized in a `[String:UIImage]` cache; **falls back to `poster(...)`** on any
   failure (iCloud-only with network off, the simulator, an unreadable/edit-list clip). Matches the in-repo
   `SceneScorer.cgImage` convention (`generateCGImagesAsynchronously(forTimes:)` in a
   `withCheckedThrowingContinuation`). Route `ClipThumbnail.load()` video → `videoFrameZero`; photos keep
   `poster`. Now the still == the frame the layer first displays ⇒ the reveal crossfade is image-identical =
   invisible, and even an un-warmed fast-swipe page centers on the **correct** frame (no race to win).
2. **Preroll (kill the static→motion hitch).** ~~In `ClipMediaSurface.load()`, `queue.preroll(atRate: 1.0,
   completionHandler: nil)`.~~ **REMOVED on-device:** calling `preroll` right after constructing the player
   throws `NSInvalidArgumentException` ("AVPlayer cannot service a preroll request until its status is
   ReadyToPlay"). It's a secondary lever; a status-gated preroll can be re-added later only if a play-start
   hitch proves perceptible. (Aside: `preroll` is closure-based — there is NO `async` overload.)
3. **Ease the HR-dot handoff.** Add `.animation(.easeOut(duration: 0.18), value: playing)` to the `HRTileView`
   in `ClipPosterView.hrOverlay` so the scorebug glides from the at-end reading into the live sweep instead of
   snapping. Leave the `playingClip` repoint + the `fraction` ternary (the HR single-source-of-truth)
   untouched.

**Deferred (do NOT ship this round):** the drag-start/earlier warm via a gesture on the `TabView` — revisit
only if device testing still shows a flick on very fast flicks of heavy clips, and prefer a non-gesture warm
(shorten the 400ms post-settle defer) if so.

## Output

- `ios/App/Snappet/Features/Feed/AssetPosterLoader.swift` — `videoFrameZero` + cache + `AVAssetBox`.
- `ios/App/Snappet/Features/Feed/MediaBrowserView.swift` — `ClipThumbnail.load()` routes video → frame-0.
- `ios/App/Snappet/Features/Feed/ClipMediaSurface.swift` — best-effort `preroll`.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — HR-dot `.animation(value: playing)`.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md` (round 5 + the iCloud-fallback choice).

## Acceptance criteria

- [ ] On device: a NORMAL/FAST carousel swipe lands with no visible frame jump as the new clip takes over
      (slow swipe stays smooth). Frame-check a 120fps capture.
- [ ] The video still each page holds is pixel-identical to the frame the player first displays.
- [ ] App type-checks (Swift 6, 0 warnings); sim + device builds green.
- [ ] No regression to tap-to-fullscreen, the mute toggle, single-active playback, or the HR scorebug.
- [ ] `decisions.md` + knowledge graph updated in the same change.

## Constraints

- iOS Swift/SwiftUI only. Keep `TabView(.page)` (deep-research refuted that it janks) and the single-active
  discipline (R12 lesson = recycled vertical rows, not a bounded per-post carousel).
- The frame-0 path is **local-only** for speed; an iCloud-only/not-yet-downloaded clip degrades to the Photos
  thumbnail until local (documented edge — the live player allows network, so its frame-0 may differ for that
  one clip).
- Simulator has no Photos library → `videoFrameZero` falls back to `poster` (which also no-ops on sim); the
  smoothness is **device-only** and must be burned on MrRobot.

## Test plan

1. `xcodebuild build` for sim + device — 0 warnings.
2. On MrRobot: capture the carousel at 120fps, slow + normal + fast swipes across a multi-clip post; confirm
   the takeover frame jump is gone and check decode/memory on the heaviest post.
