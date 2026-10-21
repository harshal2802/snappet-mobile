# Prompt: Opening Clips no longer stalls (Home → Clips)

**File**: pdd/prompts/features/193-ios-clips-tab-switch-perf.md
**Created**: 2026-10-20
**Project type**: Native iOS performance fix (Swift / SwiftUI / RealityKit / Photos) — code lands in this repo.
**Context**: `pdd/context/decisions.md`; earlier Clips perf: prompts 106, 134, 169

## Bug

User (2026-10-19): "every time i touch on clips tab it takes 1-2 seconds to load. can you check why?"

## Measured on device (MrRobot, iPhone 13 Pro Max; 1,805 clips · 370 sessions · 325 posts)

Temporary probes on a throwaway branch: timestamps + a 50 ms frame-gap monitor written to Documents and pulled with
`devicectl device copy from`. Instruments couldn't attach to this iOS 27 phone, so the last round used an in-app
main-thread stack sampler (suspend → read registers → walk frame pointers → `dladdr`).

1. Every return to Clips **rebuilt the whole feed** — a 65–137 ms main-thread snapshot — even with nothing changed.
2. The feed's poster **prefetch** and every video poster request ran a synchronous
   `PHAsset.fetchAssets(withLocalIdentifiers:)` **on main** (~100 ms each on this library). The Clips grid's
   lookups had been moved off-main in October; these two were missed.
3. The big one: **6–8 × ~110 ms stalls for ~1 s after leaving Home**, to ANY tab (Apps → Clips: none), traced by the
   sampler to RealityKit (`CoreRE` ~50 % of main-thread samples). The Home buddy's `BuddyRig.apply` built **new
   `PhysicallyBasedMaterial`s every frame** (body skin + glowing tips), and its animation kept running behind other
   tabs: `onScreen` follows scroll visibility only, and a tab switch never changes it. Removing the RealityView off-Home did NOT help
   (its teardown costs too); SwiftUI body re-evaluation and the buddy's own update code (~5 ms) were ruled out.

## Fix

- `ClipsFeedView`: re-entering the tab rebuilds only when `feedKey` changed since the last build (`builtKey`).
- `AssetPosterLoader.prefetch` / `videoFrameZero`: use the detached, cached `assets(_:)` lookup.
- `BuddyRig`: the body's material is built once per look; the tips' pulsing glow is stepped to 1/20ths and each
  step's material cached (≤ 21 ever) — frames only swap cached materials.
- `BuddyHero`: the buddy animates only while Home is the selected tab.

## Acceptance criteria

- [x] Device probe: re-entry logs "skip rebuild (unchanged)" (no snapshot stall); posters no longer fetch on main.
- [x] Unit + Clips / Home / progression UI suites green.
- [ ] Device: Home ⇄ Clips feels instant (the material fix is verified by feel with the clean build).
