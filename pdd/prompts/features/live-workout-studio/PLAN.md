# PLAN: Live Workout Capture + Video Studio

**Status**: drafting
**Owner**: pdd
**Created**: 2026-06-01
**Scope**: Turn the **WorkoutTracker** routine player into a live, instrumented, media-rich workout, and
add an on-device **video studio** (CapCut-style editing → highlight reel → share). Bridges WorkoutTracker
to the existing `HighlightEngine`.
**Research / decision record**: [`RESEARCH.md`](./RESEARCH.md) (read it first — verdicts + architecture).
**Tracking**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15).
**Chosen direction (user, 2026-06-01)**: Apple Watch companion first · unify WorkoutTracker + engine ·
full CapCut-style editor.

## Where we are

WorkoutTracker is a foreground-only set logger with a per-set rest timer and a plain text summary, with
**no HealthKit/Photos**. The flagship Reels app has the proven `HighlightEngine` + AVFoundation stitch but
reads **completed** workouts post-hoc. This initiative sits **on top of a shipped v1** — it does not block
`PLAN-ios-to-shippable.md`.

## The two tracks

```
 TRACK A — Live capture & metrics ("during")        TRACK B — Video studio ("after")
 A1 watchOS companion + live HR relay  ─┐            B1 Session media tagging ──┐
 A2 Overall timer + background/Live Act.│            B2 Enriched summary + HR ──┤
 A3 MetricsSource abstraction + BLE     │            B3 CapCut-style clip editor│
 A4 Live overlay UI (HR + 2 timers)  ───┘            B4 Highlight gen (engine) ─┤
        │                                            B5 Share / save to Photos ─┘
        └──── A1 finishing a session writes HR ──────────► B2/B4 consume it
                       B1 tagged clips ──────────────────► B3/B4 consume them
```

Track A and Track B are **largely parallel** after A1 — B1/B2 only need the session interval (already
exists) + tagged media; they don't wait on the watch. A1 is the one true foundation (it unlocks live
metrics + background + watch-trigger together). Author each prompt only when its predecessors land.

## Prompt chain

> Numbering is per-initiative (`A1…`, `B1…`) under `pdd/prompts/features/live-workout-studio/`, kept out
> of the flat `01–17` series. One prompt = one PR = one branch (`feat/live-workout-…`).

### Track A — live capture & metrics

| # | Prompt file | Scope | Depends on | Device-only? |
|---|---|---|---|---|
| **A1** | `A1-watchos-companion-live-metrics.md` | New **watchOS target** (`project.yml`): `HKWorkoutSession` + `HKLiveWorkoutBuilder`; `WCSession` relay of live HR/energy to the phone; phone-side `LiveWorkoutService` that **starts the matching `HKWorkoutActivityType`** on the watch from the routine's sport/category. **Authored below** — the unblocking foundation. | — | ✅ paired device |
| **A2** | `A2-overall-timer-background-live-activity.md` | Overall routine timer = `now − session.startedAt` (end-`Date` pattern, foreground-corrected); a **Live Activity** (Lock Screen + Dynamic Island) showing overall timer + live HR; keep-alive via the watch session. | A1 (for live HR in the activity; timer alone needs nothing) | partial |
| **A3** | `A3-metrics-source-abstraction-ble.md` | Extract a `MetricsSource` protocol (mirrors `HighlightSelector` pluggability); conformers `AppleWatchSource` (A1) + **`BLEHeartRateSource`** (CoreBluetooth `0x180D`/`0x2A37`) for chest straps / generic bands; band identification + picker UI. | A1 | ✅ device + a band |
| **A4** | `A4-live-overlay-ui.md` | In `WorkoutPlayerView`: overlay live HR (bpm + zone) with the **current-set rest timer** and the **overall timer**; graceful "no source connected" state. | A1, A2 | partial |

### Track B — video studio

| # | Prompt file | Scope | Depends on | Device-only? |
|---|---|---|---|---|
| **B1** | `B1-session-media-tagging.md` | `SessionMediaService` (reuse `PhotoLibraryService`) — discover PHAssets in `[startedAt, completedAt] ± pad`, map to **session-relative offsets**; new `@Model SessionMedia` (sessionID FK, localIdentifier, offset, kind); manual PHPicker add/remove; show on the live + summary screens. | — (session interval exists) | partial |
| **B2** | `B2-enriched-summary.md` | Rebuild `SessionDetailView`: header stats + **HR chart** (Swift Charts over `HeartRateSeries` resample) + **tagged-media gallery** + per-exercise HR-overlay where available. | B1, (A1 HR or post-hoc) | partial |
| **B3** | `B3-clip-editor.md` | **CapCut-style per-clip editor** on `AVMutableVideoComposition`: trim/split, crop/transform, **text/sticker overlays** (`AVVideoCompositionCoreAnimationTool`), transitions, speed, audio/music. New `VideoStudio` service + `@Model ClipEdit` (non-destructive edit list). Closes the deferred mixed-orientation normalization. | B1 | ✅ device profiling |
| **B4** | `B4-highlight-generation.md` | Feed session HR + tagged clips (engine `MediaItem`s, offsets from `startedAt`) + user selection (`pinnedIds`) into **`HighlightEngine`** → `ReelPlan` → `VideoStudio`/`ReelExporter`. The WorkoutTracker↔engine bridge. **No engine change.** | B1, B3, (A1/B2 HR) | partial |
| **B5** | `B5-share-and-save.md` | Generalize `ShareSheet`; add `MediaLibraryService.saveToPhotos` (`PHPhotoLibrary.performChanges`); wire share/download on every generated/edited video. | B3, B4 | ✅ device (Photos write) |

## Decision gates
- **After A1 (device)**: WCSession relay latency < ~3 s and acceptable battery? If lag is bad, reconsider
  the overlay refresh cadence before A4. Confirm we can start the right `HKWorkoutActivityType` from the phone.
- **After B1 (device)**: does PHAsset discovery surface clips *during* an active session, or only after the
  Camera app finalizes them? If real-time tagging fails, schedule in-app `AVCaptureSession` capture (new B1b).
- **After B3 (device)**: profile full-composition export time + memory with overlays. If a multi-clip +
  transitions + overlay export is too heavy on-device, trim transition/speed-ramp depth before shipping B4.
- **Before A3**: only build BLE once Apple Watch (A1) proves the `MetricsSource` shape end-to-end.

## Out of scope (defer)
- **Fitbit live / Google Fit on iOS** — no real-time API, violates on-device-only (`RESEARCH.md` §3.3).
  A Fitbit/other band is only ever a *post-hoc HealthKit* source if its own app writes to Health.
- **Health Connect** (Android) — belongs to the Android target, not iOS.
- **In-app capture** (`AVCaptureSession`) — only if B1's auto-discovery can't tag live (gate above).
- **Cloud render / accounts / off-device anything** — unchanged hard constraint.

## Notes
- One prompt = one PR; commit the prompt asset with its code. Branch `feat/live-workout-<slug>`.
- `HighlightEngine` stays platform-free — live HR becomes `HRSample`s at the `Services` boundary.
- New `@Model`s register in the single `SnappetSchema.models` line; modules don't nest a `NavigationStack`.
- Device-only features state honestly what was verified (type-check ≠ device run). Record non-obvious
  choices in `decisions.md` the day they're made.
