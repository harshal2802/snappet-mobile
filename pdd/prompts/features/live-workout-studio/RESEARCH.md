# Research: Live Workout Capture + Video Studio

**Created**: 2026-06-01
**Type**: PDD Research (feasibility + approach selection) — the decision record behind `PLAN.md`.
**Status**: complete — verdicts below; device validation pending (HealthKit/CoreBluetooth/AVFoundation are device-only).
**Source**: user feature brief (2026-06-01), GitHub issue (this repo).
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`, `snappet-core-schema.md`.
**Tracking**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15) (initiative umbrella).

---

## 1. The brief, restated

The user wants to evolve the **WorkoutTracker** routine player (set logger) from a foreground-only
set counter into a live, instrumented, media-rich workout experience, and to add a post-workout
**video studio**. Eleven asks, grouped:

**During the workout (live):**
1. The routine, once started, cannot run in the background.
2. There is no **overall routine timer** (only a per-set rest timer exists).
3. No **live metrics** from Apple Watch / Fitbit-style bands.
4. **Identify the active band** + **trigger the relevant workout** on the watch / band.
5. **Overlay** live fitness data alongside the current-set timer and the overall timer.
6. **See photos/videos** captured during the same workout, attached to the session.

**After the workout (studio):**
7. Improved **post-workout summary** with detailed band data + tagged videos.
8. Per-clip **CapCut-style editing**: split/crop, text overlay, basic edits.
9. **Generate a highlight video** from the user's selection of tagged clips.
10. Generated videos are **shareable / downloadable** to local / Photos.

## 2. What we already have to build on (codebase audit)

| Asset | Where | Reuse |
|---|---|---|
| Pure-Swift selection algorithm | `HighlightEngine` (`HeartRateSeries`, `HighlightSelector`, `FusionSelector`, `ReelPlanner`, `HighlightConfig`) | **Highlight generation (#9)** — feed strength-session HR + tagged clips in, get a `ReelPlan` out. Already platform-free, 18 tests. |
| On-device video stitch | `Services/ReelExporter.makeComposition` (`AVMutableComposition`) + `PhotoClipRenderer` (Ken-Burns) | **Editor + export (#8/#9/#10)** — extend with `AVMutableVideoComposition` for crop/text/transitions. `makeComposition` already shared by preview + export. |
| Post-hoc HR reads | `Services/HealthKitService` (completed `HKWorkout` + HR series) | **Summary HR (#7)** — but it's *post-hoc*; live (#3) needs a new path. |
| Time-window media discovery | `Services/PhotoLibraryService` (PHAsset ± 90 s, → workout-relative offsets) | **Tagged media (#6)** — session-scope it (offsets relative to the live session start). |
| Share sheet | `Reel/ReelView` (`ShareSheet: UIViewControllerRepresentable`) | **Share/download (#10)** — generalize; add `PHPhotoLibrary` save. |
| Set-logging session model | `WorkoutTracker/WorkoutModels.swift` (`WorkoutSession`, `SessionExercise`, end-`Date` rest timer) | **Home flow.** `WorkoutSession.startedAt/completedAt` already define the workout interval the media + HR window keys off. |
| Background-safe timer pattern | `WorkoutPlayerView` rest timer is driven off a target **end `Date`** (survives backgrounding; foreground-corrects in `scenePhase`) | **Overall timer (#2)** uses the same pattern. |

**The big architectural fact:** the two workout apps are currently disjoint — `WorkoutTracker`
(id `workout-log`, SwiftData set logging, **no HealthKit/Photos**) and **Workout Reels** (id `workout`,
HealthKit post-hoc + `HighlightEngine`). This initiative's chosen direction (user, 2026-06-01)
**unifies them**: WorkoutTracker becomes the live-capture home, and finishing a session feeds the
**existing engine** for highlights. Nothing about the engine changes; we add platform I/O in `Services/`
and wiring in the WorkoutTracker module.

## 3. Feasibility findings (per ask)

### 3.1 Live metrics + "trigger the workout on the watch" (#3, #4) — needs a watchOS companion
- A phone app **cannot** read live Apple Watch HR, and **cannot** start the system Workout app remotely.
  The only supported path is a **watchOS companion target** that runs an `HKWorkoutSession` +
  `HKLiveWorkoutBuilder`, and relays samples to the phone over `WCSession`
  ([HKWorkoutSession](https://developer.apple.com/documentation/healthkit/hkworkoutsession),
  [HKLiveWorkoutBuilder](https://developer.apple.com/documentation/healthkit/hkliveworkoutbuilder),
  [WWDC25 "Track workouts with HealthKit"](https://developer.apple.com/videos/play/wwdc2025/322/)).
- "Identify the active band + trigger the relevant workout" → the **phone** tells the **watch app** which
  `HKWorkoutActivityType` to start (mapped from the routine's `SportTag`/category), and the watch starts
  the session. This is the standard and only mechanism. There is no API to drive a Fitbit/Garmin band's
  on-device workout from iOS.
- **Verdict: GO**, contingent on adding a watchOS target (previously deferred — see §5). This is the
  foundational unlock; it also solves background execution (§3.2).

### 3.2 Background execution + overall timer (#1, #2) — solved by the watch session + Live Activity
- A phone-only app **cannot** keep an arbitrary timer/loop running in the background indefinitely. The
  legitimate mechanisms:
  - An **active `HKWorkoutSession` on the watch** keeps the workout alive and HR flowing while
    backgrounded (watchOS "workout processing" background mode) — the metrics keep updating even with the
    phone in pocket.
  - A **Live Activity** (iOS 16.1+) renders the overall timer + live HR on the Lock Screen / Dynamic
    Island; the timer text is driven by a target `Date` so it stays correct without background CPU
    ([WWDC24 Live Activities](https://developer.apple.com/videos/play/wwdc2024/10098/)).
  - The **overall timer itself is just `now - session.startedAt`** rendered off the wall clock — the same
    end-`Date`/`scenePhase`-correction pattern the rest timer already uses (`WorkoutPlayerView`). No
    background CPU needed for correctness; only the *live HR* needs the watch session.
- **Verdict: GO.** Overall timer is trivial and correct today; "runs in background" = the watch session
  (live HR) + a Live Activity (lock-screen visibility) + end-`Date` timers (already proven pattern).

### 3.3 Fitbit / generic bands / "Google Fit air" (#3, #4) — BLE, not cloud
- **Fitbit has no real-time API.** Its Web API is cloud-only, intraday access is gated/approved
  case-by-case, capped to 24 h windows, and bottlenecked by device-sync latency — unusable for a live
  overlay ([Fitbit Intraday](https://dev.fitbit.com/build/reference/web-api/intraday/),
  [no real-time API thread](https://community.fitbit.com/t5/SDK-Development/feature-request-real-time-API-to-retrieve-heart-rate-and-steps/td-p/2700423)).
  It also violates our **on-device-only / no-network** constraint.
- The on-device live path for non-Apple bands (chest straps, Polar/Garmin/Wahoo, any band exposing
  standard HR) is the **BLE Heart Rate Profile** — service `0x180D`, measurement characteristic `0x2A37`,
  via `CoreBluetooth`
  ([HR GATT service](https://medium.com/@igor1994makara/how-to-get-heart-rate-data-from-heart-rate-monitor-using-ble-technology-7f78786fe939)).
  Gives HR (and contact/RR if present); **not** calories/zones/workout-control.
- "Google Fit air": Google Fit APIs are deprecated; **Health Connect** is the Android successor and is
  **Android-only** — it belongs to the (later) Android target, not iOS. On iOS, third-party bands surface
  either via BLE (live) or via HealthKit if their own app writes there (post-hoc).
- **Verdict: GO for Apple Watch (Phase 1) + BLE generic bands (Phase 2). NO-GO for Fitbit live / Google
  Fit on iOS** — out of scope; revisit Fitbit as a *post-hoc HealthKit* source only if a band writes to
  Health. Design the live layer behind a `MetricsSource` protocol so adding BLE later is one conformer.

### 3.4 In-session media (#6) — extend the existing time-window discovery, session-scoped
- Two complementary mechanisms, both on-device:
  - **Auto-discovery** (reuse `PhotoLibraryService`): PHAssets whose `creationDate` ∈
    `[session.startedAt, completedAt] ± pad`, mapped to **session-relative offsets** — the same approach
    Workout Reels uses for an `HKWorkout`, now keyed on the `WorkoutSession` interval.
  - **In-app capture** (new, optional): an `AVCaptureSession` "film a rep" button that writes a clip and
    stamps its session offset directly (no clock-skew guesswork). Heavier; can follow auto-discovery.
- **Verdict: GO.** Start with auto-discovery + manual PHPicker tagging (no clock-skew risk, reuses code);
  in-app capture is a later enhancement.

### 3.5 CapCut-style per-clip editor (#8) — fully on-device with AVFoundation
- All "basic CapCut" operations are first-class AVFoundation, on-device, no backend:
  - **Trim / split**: time-range insertion into `AVMutableComposition` (already done in `ReelExporter`).
  - **Crop / transform / rotate**: `AVMutableVideoCompositionLayerInstruction.setTransform` +
    `renderSize` on an `AVMutableVideoComposition`.
  - **Text / sticker overlays**: `CALayer` tree composited via `AVVideoCompositionCoreAnimationTool`.
  - **Transitions, speed ramps, audio/music**: opacity/transform ramps, `scaleTimeRange`, extra audio
    tracks — all `AVMutableComposition`/`AVMutableVideoComposition`.
- This is exactly the **mixed-orientation normalization** gap already flagged in `project.md` (photo +
  video segments need a unifying `AVVideoComposition`) — the editor work closes it.
- **Verdict: GO.** The user chose the **full** editor (multi-clip timeline, transitions, audio, text,
  crop, speed) for the first studio phase — feasible but it is the largest single track; `PLAN.md`
  decomposes it into independently shippable prompts so the end-to-end loop (edit → highlight → share)
  lands before the long-tail polish.

### 3.6 Enriched summary, highlight generation, share/download (#7, #9, #10) — reuse the engine
- **Summary (#7)**: `SessionDetailView` + an HR chart (Swift Charts over the `HeartRateSeries` resample)
  + a tagged-media gallery. Pure SwiftUI over data we now have.
- **Highlight generation (#9)**: feed the session's HR series + tagged clips (as engine `MediaItem`s,
  offsets relative to `session.startedAt`) + the user's manual selection (as `pinnedIds`) into
  `HighlightEngine` → `ReelPlan` → the editor/exporter. **This is the bridge** that finally connects
  WorkoutTracker to the proven flagship engine. No engine change required.
- **Share/download (#10)**: `UIActivityViewController` (exists) + `PHPhotoLibrary.performChanges` to save
  the exported `.mp4` to Photos. Generalize the existing `ShareSheet`.
- **Verdict: GO.** All three are reuse + wiring.

## 4. Architecture decision (how it stays within the conventions)

```
 watchOS companion (NEW target)            iPhone app (existing)
 ┌──────────────────────────┐   WCSession  ┌─────────────────────────────────────────┐
 │ HKWorkoutSession +        │ ───HR/kcal──►│ Services/                                │
 │ HKLiveWorkoutBuilder      │◄──start(type)│  LiveWorkoutService  (WCSession host)    │
 └──────────────────────────┘              │  MetricsSource (protocol)                │
                                            │   ├ AppleWatchSource (WCSession)         │
 BLE band (Phase 2) ───0x180D/0x2A37──────► │   └ BLEHeartRateSource (CoreBluetooth)   │
                                            │  SessionMediaService (PHAsset discovery) │
                                            │  VideoStudio (AVMutableVideoComposition) │
                                            │  MediaLibraryService (save to Photos)    │
                                            ├─────────────────────────────────────────┤
                                            │ Features/WorkoutTracker/  (home flow)    │
                                            │  live overlay · timers · summary · studio│
                                            ├─────────────────────────────────────────┤
                                            │ HighlightEngine  (UNCHANGED, platform-free)│
                                            │  HR series · selector · ReelPlanner       │
                                            └─────────────────────────────────────────┘
```

**Rules honored:** `HighlightEngine` gets **zero** new platform imports — live HR becomes plain
`HRSample`s at the `Services` boundary, exactly like the post-hoc path. All new platform I/O is a
`Services/` type. New SwiftData `@Model`s (tagged media, generated reels, per-clip edits) register in the
one central `SnappetSchema.models` line. WorkoutTracker keeps riding the App Library's `NavigationStack`
(no nested stack). The `MetricsSource` protocol mirrors the `HighlightSelector` pluggability pattern so
Apple Watch → BLE → (post-hoc HealthKit) is a swap, never a rewrite.

## 5. What this supersedes (prior deferrals being reopened)

This initiative deliberately reverses three Phase-1 scoping calls — recorded so the plan doesn't read as
contradicting `decisions.md`:
- *"v1 reads COMPLETED workouts (post-hoc), not a live watchOS session"* (2026-05-30) — still true for the
  **flagship Reels** app; this initiative adds a **live** path for **WorkoutTracker**, alongside it.
- *"Out of scope for v1: watchOS live-HR capture, generic BLE bands, in-app capture"*
  (`PLAN-ios-to-shippable.md`) — these are exactly Phase 1–2 here. v1-shippable does **not** depend on
  this; this is the **next** initiative on top of a shipped v1.
- The selector was kept pluggable *specifically* so this day could come without an engine rewrite — that
  bet pays off here.

## 6. Open questions for the device gate (honest unknowns)
- **WCSession relay latency / battery** under a real workout — unmeasured; validate on a paired device
  (target: HR overlay lag < ~3 s, acceptable battery).
- **Live media tagging during an active session** — does PHAsset discovery see just-captured clips mid-
  session, or only after the Camera app finalizes them? Likely needs in-app capture for true real-time.
- **Full-editor export time / memory** for a multi-clip composition with overlays on-device — needs a
  device profiling pass before committing to transitions/speed-ramps depth.
- **Live Activity update budget** — confirm the timer + HR refresh cadence stays within ActivityKit limits.

These are the §"after P1" device-gate checks in `PLAN.md`; none block authoring the plan or the watchOS
foundation.
