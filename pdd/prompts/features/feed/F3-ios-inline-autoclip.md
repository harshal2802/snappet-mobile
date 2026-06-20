# Prompt: F3 — iOS inline media auto-clip hero + media-first fallback chain

**File**: pdd/prompts/features/feed/F3-ios-inline-autoclip.md
**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift / SwiftUI / AVFoundation). Code lands in this repo.
**Chain**: PLAN.md → F3 (depends on F1; sibling of F2; feeds F4's Animate path)
**Source**: GitHub epic "Recap Feed" → issue "F3 iOS inline auto-clip hero"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`
**Design**: `/tmp/feed-dossier/_locked-design.md` §5 (clipReady row), §6.3 (Pillar 3 auto-clip), §7 (degradation table), §9 (reuse), §11 wireframes 5–6

## Goal

Make the Recap feed **move**: give the a1/a2 session card a **media-first hero** with a single active, muted, looping `AVPlayer` — the card nearest viewport center plays a session clip, every other card holds a still. The clip is sourced from `SessionMedia` and ranked by `HighlightEngine`/`ReelPlanner` (the same ranking that drives F4's export), and the hero resolves through an honest **fallback chain — clip → photo → generated `DisciplineHero`** — so a session with no media degrades silently into F1's existing hero with no dead surface. This is the iOS "wow" texture the locked design calls out (`_locked-design.md:13`, `198`); it also lights up the **`clipReady` eligibility** (`SessionMedia` video + HR + non-empty `ReelPlan`) that F4's Animate path keys off (`_locked-design.md:177`, `235`). iOS-only by construction: Android has no `SessionMedia`, so the `clipReady` predicate is never eligible and the card falls back to the generated hero (`_locked-design.md:213`).

## Context the implementer needs

- **Keystone rule — new behavior, never a new ordering hack.** F3 adds the **`clipReady` card-kind / registry entry** to the F0 composer (`enum FeedCardKind`, `FeedCard.swift:14`; recipe + `eligibility`/`salience` in `FeedComposer.swift`, same shape as the existing inline-eligibility recipes at `FeedComposer.swift:169-288`). `clipReady` is **not** a separate card in the stream — it is a **payload enrichment + eligibility flag on the a1 session card** (the hero just gains a rankable clip). Do **not** edit the F0 ordering core (`FeedComposer.swift:141-142` salience×recencyDecay) — add the eligibility/payload, nothing more.
- **`SessionMedia` is the source and is iOS-only** (`_locked-design.md:136`, `270`). The model and its I/O live behind `SessionMediaService` (`ios/App/Snappet/Services/SessionMediaService.swift:14`); media is attached per session and surfaced today by `SessionDetailView` (`ios/App/Snappet/Features/WorkoutTracker/SessionDetailView.swift:304` `SessionMediaSection`, `:895` `SessionMediaThumb`). F3 reads video assets through the service — the view never touches the file system directly (layering rule: platform I/O stays in `Services/`).
- **Clip ranking reuses the reel engine — do not reinvent.** Segment selection runs through `SessionHighlightInput` → `HighlightEngine`/`ReelPlanner` to produce a `ReelPlan` (the same plan F4 hands to `ReelExporter`, `ios/App/Snappet/Services/ReelExporter.swift:24`). `HighlightEngine` stays platform-free (no AVFoundation import) — F3 only consumes its ranking output; the actual `AVPlayer`/`AVPlayerItem`/`AVAsset` plumbing lives in a thin Service-layer player coordinator. The inline preview plays the **top-ranked segment** (a time-range loop over the source asset), it does **not** export — export is F4's device-burn path.
- **`clipReady` eligibility (`_locked-design.md:177`):** a session is `clipReady` iff it has **≥1 `SessionMedia` video** AND **HR present** (the `hrSeries` the F2 cards already read) AND a **non-empty `ReelPlan`** from the ranker. All three must hold — a video with no HR, or HR with no rankable segment, is *not* `clipReady` (it still gets the photo/generated-hero fallback; it just can't animate). This predicate is the seam F4's Animate path consumes — keep it a pure function over plain-value inputs so it's unit-testable without a device.
- **Single active player — the scroll-center rule (`_locked-design.md:75`, `198`).** At most **one** `AVPlayer` is instantiated and playing at a time: the card whose frame center is nearest the viewport center. Off-screen / non-central cards show the still hero (clip first frame or photo). On scroll, the active player hands off (pause+release old, attach+play new) with hysteresis so a card straddling center doesn't thrash. Playback is **muted + looping**; respect Low Power Mode and `reduceMotion` (fall back to still). This is a device-burn behavior — the coordinator logic (which index is central, when to hand off) is pure and unit-tested; the `AVPlayer` attach itself is verified on device.
- **Hero fallback chain (`_locked-design.md:213`, wireframes 5–6):** `clip → photo → generated DisciplineHero`. F1 already renders the generated `DisciplineHero` (`ios/App/Snappet/DesignSystem/PulsePro.swift:12`) as the no-media hero; F3 inserts the clip and photo tiers **above** it without changing F1's card shell — the card view asks the hero resolver for the best available tier. A still photo (no video / not central / reduceMotion) reuses the existing thumbnail surface (`SessionDetailView.swift:895` styling).
- **No export, no share sheet, no Photos write in F3** — those are F4 (`_locked-design.md:235`). F3 stops at inline muted-loop playback + `clipReady` eligibility + the enriched payload. The overlay-burn (`StudioOverlays`/`HRTile`, `ios/App/Snappet/Features/WorkoutTracker/StudioOverlays`, `HRTileView.swift:13`) is F4's concern — inline preview shows the clean clip, not the burned overlay.
- New code lands in `ios/App/Snappet/Features/Feed/` (F0/F1 created it); player I/O lands in `ios/App/Snappet/Services/`.

## Approach

- `FeedComposer.swift` / `FeedCard.swift`: add the `clipReady` eligibility + enrich the a1 session payload with a `clipRef`/`ReelPlan` handle when eligible — a new registry-level predicate, **not** an edit to the ordering core. Add the supporting case/field to `FeedCardKind`/`FeedCardPayload` as an additive extension.
- `Feed/FeedClipEligibility.swift`: the pure `clipReady(media:hr:plan:) -> Bool` predicate + the `ReelPlan`-from-`SessionHighlightInput` wiring (calls `HighlightEngine`/`ReelPlanner`, no AVFoundation). Unit-tested.
- `Feed/FeedHeroResolver.swift`: pure `resolveHero(card:) -> HeroTier` (`.clip(range) | .photo(ref) | .generated`) — the fallback-chain decision, unit-tested.
- `Feed/FeedActivePlayerCoordinator.swift`: pure scroll-center logic — given card frames + viewport, return the index that should be active (with hysteresis). Unit-tested with synthetic geometry.
- `Services/FeedClipPlayer.swift` (or extend an existing media service): the thin `AVPlayer`/`AVQueuePlayer` + `AVPlayerLooper` attach/teardown, muted, time-ranged to the top segment; honors Low Power Mode / `reduceMotion`. Device-burn.
- `Feed/FeedSessionCard.swift` (F1's card): swap the hero slot to drive `FeedHeroResolver` → clip player (when central) / still; no change to `StatRibbon`/`.snappetCard()`/edge accent.
- Pure helpers (eligibility, hero resolution, active-index) are testable files; XCUITest covers scroll → central card animates → off-screen card freezes → no-media card shows generated hero.

## Output

- `FeedComposer.swift` + `FeedCard.swift` — additive `clipReady` registry entry + `FeedCardKind`/payload enrichment (no ordering-core edit).
- `Feed/FeedClipEligibility.swift` — pure `clipReady` predicate + `ReelPlan` ranking wiring (`SessionHighlightInput`→`HighlightEngine`/`ReelPlanner`).
- `Feed/FeedHeroResolver.swift` — pure clip→photo→generated fallback-chain resolver.
- `Feed/FeedActivePlayerCoordinator.swift` — pure nearest-viewport-center active-index logic (with hysteresis).
- `Services/FeedClipPlayer.swift` — thin muted/looping `AVPlayer` attach/teardown for the top-ranked segment (Low Power / reduceMotion aware).
- `Feed/FeedSessionCard.swift` — hero slot driven by the resolver (clip when central, still otherwise); F1 shell otherwise unchanged.
- `SnappetTests/FeedClipEligibilityTests.swift` — `clipReady` truth table (video+HR+plan true; each missing → false) + golden eligibility over the F0 corpus.
- `SnappetTests/FeedHeroResolverTests.swift` + `SnappetTests/FeedActivePlayerCoordinatorTests.swift` — fallback-chain ordering + central-index/hysteresis math.
- `SnappetUITests/FeedAutoClipUITests.swift` — scroll → central card animates → off-screen freezes → no-media card shows generated hero.
- `docs/knowledge-graph/data.js` — add `feed-clip-player` (service) node; `uses` edges feed→feed-clip-player and feed-clip-player→`session-media`/`highlight-engine`/`reel-planner`; note `clipReady` feeds `feed-export` (F4).

## Acceptance criteria

- [ ] `clipReady` is added as a `FeedComposer` registry predicate + `FeedCardKind`/payload enrichment — the F0 ordering core (`salience × recencyDecay`) is **not** edited; the new card-kind is registered, not hand-inserted.
- [ ] `clipReady` is true iff a session has ≥1 `SessionMedia` video **and** HR present **and** a non-empty `ReelPlan`; each missing input flips it false (truth table unit-tested) — Android-shared inputs never make it eligible there.
- [ ] The session card hero resolves through **clip → photo → generated `DisciplineHero`**: a clip-eligible session animates; a video-but-not-`clipReady` / non-central / reduceMotion session shows a still; a no-media session shows F1's generated hero unchanged (resolver unit-tested).
- [ ] At most **one** `AVPlayer` plays at a time — the card nearest viewport center; scrolling hands off (old pauses+releases, new attaches+plays) with hysteresis (no thrash); playback is muted + looping; Low Power Mode / `reduceMotion` fall back to still. Active-index logic is unit-tested with synthetic geometry.
- [ ] `HighlightEngine` gains **no** AVFoundation/UIKit import (player I/O stays in `Services/`); the inline preview plays the top-ranked segment and performs **no** export/share/Photos write (deferred to F4).
- [ ] App type-checks (Swift 6, 0 warnings); `decisions.md` records the single-active-player + fallback-chain + clipReady-vs-export-boundary choices.

## Constraints

- On-device only; derive-on-read (no clip caching beyond the active player; no card persistence). Reuse `SessionMedia`/`SessionMediaService`, `SessionHighlightInput`/`HighlightEngine`/`ReelPlanner`, `PulsePro.DisciplineHero`, F1's `FeedSessionCard` shell — no new ranking, no new hero component, no new brand tokens.
- iOS-only by absence: the `clipReady` predicate consumes `SessionMedia` (iOS) so it is never eligible on Android — no Android stub, no dead "Animate" button (Android's clip entry is the deferred Stage-0 `ReelRoot`, out of scope here).
- Single active `AVPlayer`, muted + looping, off-main-thread asset loading; honor Low Power Mode / `reduceMotion`. No export, no overlay-burn, no share sheet in F3.
- Verify honestly: type-check ≠ device run. AVFoundation inline playback, the hand-off-on-scroll, and reduceMotion fallback are **device-burn** items — flag them; sim cannot prove smooth muted-loop playback.

## Test plan

1. Unit: `FeedClipEligibilityTests` (`clipReady` truth table + golden eligibility over the F0 corpus), `FeedHeroResolverTests` (clip→photo→generated ordering, each tier reached), `FeedActivePlayerCoordinatorTests` (nearest-center index + hysteresis across synthetic scroll frames) green; build-for-testing.
2. XCUITest: launch `--start-tab feed` → scroll a clip-eligible session to center → assert it animates → scroll it off → assert it freezes to still → assert a no-media session shows the generated hero. Sim wedge → `xcrun simctl shutdown all`, re-run.
3. Device-burn (real device, flagged): muted/looping playback is smooth; only one card plays at a time; hand-off on fast scroll doesn't thrash; Low Power Mode / reduceMotion fall back to still; no audio leaks. Confirm `clipReady` sessions are exactly those F4 can later Animate.
