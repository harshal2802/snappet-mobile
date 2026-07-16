# Prompt: Highlights convergence — retire the Workout Reels tile, converge the reel maker (P1–P4)

**File**: pdd/prompts/features/highlights-convergence/P1-P4-highlights-convergence.md
**Created**: 2026-07-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone (product assessment → convergence); wireframes in
`docs/ux-research/workout-reels-v2/wireframes.html`
**Source**: product review 2026-07-15 — "Workout Reels isn't doing anything special anymore"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The standalone **Workout Reels** mini-app has been overtaken by the app it bootstrapped: its
workout-list front half (HealthKit workouts → media in window) was made redundant by the
watch-workouts→Clips import (#283), its export is the app's *weakest* video (it never passed
`hrOverlay:` to `ReelExporter`, so reels ship overlay-less while Studio/Feed exports burn the glass
scorebug), and its output vanishes into Photos where the Clips feed never sees it. But the
capability underneath — an HR-ranked multi-clip montage — is the only one of its kind in the app,
`ReelView` is already reused by Kilter, and `HighlightEngine` powers HRV/recovery/effort elsewhere.

So: **retire the tile, keep and upgrade the machinery.** Reels become (a) an action on every
session ("Make a Highlight Reel", one shared builder), (b) first-class Clips posts (✦ REEL), and
(c) the new flagship **Weekly Highlight Reel** — a cross-session montage nothing else can cut.

## Context the implementer needs

- `ReelExporter.export(_:hrOverlay:)` already supports the burned glass scorebug (the Feed
  "Animate" path uses it via `HROverlayValues` → `.feedClipScorebug` → `StudioOverlays`); the
  flagship `ReelViewModel.export()` called the nil-overlay overload. The engine `Workout` carries
  `hr`/`restBpm`/`maxBpm`, so the overlay inputs are already in hand.
- `MediaLibraryService.saveVideoToPhotos` returns the created PHAsset `localIdentifier` — the
  hook for registering a posted reel as `SessionMedia`.
- `SessionMedia.allIdentifiers` global dedup means a freshly-posted reel asset is never re-imported
  by session auto-discovery (insert the reel row FIRST, before any discovery pass can see the asset).
- The gym session detail already had a bespoke highlight sheet (`SessionHighlightView`/-`ViewModel`)
  that duplicated ReelViewModel's generate→export flow — the P3 convergence deletes it (the
  routine-in-pager precedent: one player, SSOT).
- Retiring the module also retires the only surface that requested HealthKit read authorization on
  a fresh install; the watch-workouts import depends on it invisibly. Requesting it from the launch
  reconcile was tried and REVERTED (unsolicited sheet on every launch until answered; races UI
  tests) — the gap is documented in decisions.md, with a contextual Clips offer as the follow-up.

## Approach

**P1 — reel output upgrade (the 1-line unlock + visible ranking).**
`ReelViewModel.export()` builds `ReelExporter.HROverlay` from the source workout (whole-session
series across the reel — the Animate precedent) behind a `HR overlay` chip; `ReelFormat`
(native / 9:16 / 4:5 / 1:1, pure) threads a `renderAspect` through `makeComposition` so preview
and export share the framing (WYSIWYG); `ReelIntensity` (pure) puts a `PEAK <bpm>` badge on every
highlight row, tinted by the %HRR performance ramp.

**P2 — reels are Clips posts.**
`SessionMedia.reelTitle: String?` (additive → lightweight migration; non-nil = reel + title) →
`MediaInput.reelTitle` → `ClipFeedComposer` emits each reel as its OWN post (`isReel`, never
grouped into a set/climb carousel, no live HR overlay — the pixels carry it). `ClipFeedFilter`
gains a `Reels` chip. `ReelViewModel.postToClips()` (Save to Photos → insert reel-marked
`SessionMedia` on `source.postSessionID`) becomes the payoff's primary CTA.

**P3 — entry migration + tile retirement.**
`ReelSource.workoutSession(...)` (mirrors `.kilterSession`) feeds the shared `ReelView` from the
gym session detail's "Make a Highlight Reel" (the old sheet pair is deleted). The Workout module
(tile, list, module-scoped onboarding, AppModel phase/bootstrap/workouts) is deleted; the App
Library hero re-points to Weekly Highlights (same `appLibrary.flagship` id), the Home fresh-install
CTA to the Gym Tracker, and `ModuleChoice.workoutReels` is removed. HealthKit priming stays with
the Gym Tracker's HR surfaces (the launch-reconcile request was reverted — decisions.md).

**P4 — Weekly Highlight Reel.**
Pure `WeeklyHighlights`: the week's media-bearing sessions stitch onto ONE synthetic timeline
(HR + media offsets + boost windows shift by the running span) → a single engine `Workout` the
whole existing pipeline consumes unchanged; `ReelSource.week` marks it `trimToHighlights` (a week
condenses to moments). Surfaces: a hero card at the top of Clips (offer = ≥2 video clips this
week, decided over the composed posts) and the App Library flagship hero, both pushing
`WeeklyReelHostView` (the store edge).

## Output

- `Features/Reel/ReelFormat.swift`, `Features/Reel/WeeklyHighlights.swift` (pure) +
  `Features/Reel/WeeklyReelHostView.swift`; upgrades to `ReelViewModel`/`ReelView`/`ReelExporter`.
- Feed: `reelTitle` on `SessionMedia`/`MediaInput`, reel posts + `isReel` in `ClipFeedComposer`,
  `reelsOnly` in `ClipFeedFilter`, ✦ REEL badge + Reels chip + weekly hero in `ClipsFeedView`.
- Deletions: `Features/Workout/`, `Features/Onboarding/OnboardingView.swift`,
  `SessionHighlightView(+ViewModel).swift`, the AppModel phase/bootstrap surface, the gym
  dashboard's stale reels cross-link, `ModuleChoice.workoutReels`.
- Tests: `ReelFormatTests`, `WeeklyHighlightsTests`, reel-post + reels-chip additions to
  `ClipFeedComposerTests`/`ClipFeedFilterTests`; retired-surface tests removed.

## Acceptance criteria

- [x] Exported session reels burn the glass HR scorebug (toggleable), in the chosen format preset.
- [x] Preview and export share the same canvas (`makeComposition(renderAspect:)`).
- [x] Highlight rows show `PEAK <bpm>` on the performance ramp; no HR in window → score fallback.
- [x] "Post to Clips" lands the reel as its own ✦ REEL post; a Reels filter chip narrows to them;
      reel posts draw no live HR overlay; auto-discovery never duplicates the posted asset.
- [x] Gym + Kilter session details feed the SAME `ReelView`; the bespoke highlight sheet is gone.
- [x] The Workout Reels tile, list, and onboarding are deleted; App Library hero + Home CTA
      re-pointed; the smoke test covers the 8 remaining modules.
- [x] Weekly cut: stitched sessions never overlap on the synthetic timeline; the offer needs ≥2
      in-week video clips (reel posts excluded); the builder posts under the latest session.
- [x] App changes type-check against the iOS 18 SDK (Swift 6); unit suite green.
- [x] No platform imports added to `HighlightEngine` (engine untouched).
- [x] `decisions.md` updated; knowledge graph updated in the same change.

## Constraints

- On-device only; engine stays platform-free and UNCHANGED.
- Additive SwiftData columns only (`reelTitle` optional → lightweight migration).
- Honest verification: overlay burn + Photos round-trips are device-only (simulator has no H.264
  encoder / no Photos) — sim runs passthrough; the device leg is listed in the test plan.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — unit suite incl. the new pure tests.
2. `make ios-sim SIMULATOR='iPhone 17 Pro'` — full app type-check/build.
3. **Device leg (MrRobot)**: session with clips → Make a Highlight Reel → format 9:16 + overlay →
   export → Post to Clips → ✦ REEL post plays raw with burned scorebug; weekly hero appears with
   ≥2 clips this week and cuts a cross-session montage.
