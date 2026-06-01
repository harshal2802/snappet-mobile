# Decisions: Snappet Mobile (iOS)

Reverse-chronological. Each entry: the decision, why, and what it rules out. These are the
non-obvious choices already baked into the v0.1 code — written down so future prompts don't re-litigate
or accidentally reverse them.

## [2026-06-01] A4 — live-metrics overlay UI (HR zone + overall timer + rest timer) (WorkoutTracker)

**Decision**: Implemented prompt A4 (`pdd/prompts/features/live-workout-studio/A4-live-overlay-ui.md`,
branch `feat/live-workout-overlay`). Replaced A1's temporary `liveMetricsDebugRow` in `WorkoutPlayerView`
with a polished **live-metrics overlay** that composes, at a glance: the **live HR** (bpm + zone
color/label + source name), the **overall workout timer** (A2's `overallTimerHeader`), and — on the rest
screen — the **rest countdown**, plus a graceful **no-source** state. This is the user's "overlay fitness
data along with current and overall workout timer" ask (RESEARCH.md §3.2).

**Concrete, non-obvious choices made:**
- **`HeartRateZone` is a pure value type** (`Features/WorkoutTracker/HeartRateZone.swift`, `enum: Int`,
  `Sendable`/`Equatable`) — the only SwiftUI surface is `var color: Color` (itself a value type), so the
  bpm→zone mapping is **unit-testable in `SnappetTests` with no device** (mirrors keeping `HighlightEngine`
  platform-free, but this lives in the app since it returns a SwiftUI `Color`; the engine stays untouched,
  grep-confirmed no platform import). `forBpm(_:maxHR:)` is the single mapping point; the view does no zone
  math.
- **Default max HR = 190, a fixed constant (not `220 − age`)** — and *why*: the suite has **no user age /
  HR profile yet**, so a personalized max isn't computable. 190 is a reasonable adult ceiling that gives
  the overlay meaningful **relative** zone color without pretending to be a training prescription. The
  zones are the common 5-zone %-of-max model (recovery <60% / easy 60–70 / aerobic 70–80 / threshold
  80–90 / max ≥90), lower-bound inclusive. `maxHR` is a parameter, so when a profile lands (a later
  prompt) the call site passes a real max with **zero** change to the zone math.
- **A `.none` zone** (rawValue 0) for nil / no-data, distinct from "a real but very low bpm": `forBpm`
  returns `.none` for `nil`, non-positive bpm, **and** non-positive `maxHR` (a degenerate max can't yield a
  meaningful zone → no-data, not a crash). `.none` renders the inert secondary-gray pill, never a fake
  "Z1", so a missing watch / band reads as missing.
- **The overlay composes the two timers via existing pieces, not a re-implementation**: `overallTimerHeader`
  (A2, the self-updating `Text(timerInterval:)` pinned via `.safeAreaInset(.top)`) is unchanged; the new
  `liveMetricsOverlay` (the HR pill) is placed at the top of **both** the exercise `ScrollView` and the
  rest screen (so HR stays visible while resting, alongside the rest countdown circle). No new timer loop,
  no Live-Activity regression — the existing `.onChange` pushes are untouched.
- **`LiveHRPill` is a thin file-private view** handed an already-computed bpm + `HeartRateZone` + source
  name + the no-source text — **no business logic in the view** (conventions.md "views are thin"). With a
  sample: ❤️ (zone-tinted, `.pulse`) + bpm (zone color) + `pillLabel` ("Z3 · Aerobic") chip + `displayName`.
  Without one: the source-aware status (reusing A1/A3's `liveStatusText` / `MetricsSourceState`, e.g. "Open
  the workout on your watch" / "Connecting…" / "No watch metrics on this device"). The pill reads live data
  **only** through `app.liveWorkout` (the coordinator) — never `watch` / `ble` directly.
- **Accessibility**: the overlay carries `accessibilityIdentifier("liveMetricsOverlay")` (an
  `accessibilityElement(children: .ignore)` with a composed label/value) so the walkthrough can assert it.
  No new `@Model` → `SnappetSchema.models` unchanged.

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**, 0 warnings from
these changes. `SnappetWatch` (watchOS 26.5 sim) → **BUILD SUCCEEDED** (A1/A2/A3 unbroken). `SnappetTests`
→ **56/56 pass** (48 prior + 8 new `HeartRateZone`: nil/no-data, non-positive bpm + non-positive maxHR,
default-190 boundary table, custom-maxHR boundary shift, labels / `pillLabel`, distinct rawValues).
`HighlightEngine` → **18/18**, source unchanged (no platform import). `WorkoutWalkthroughTests` → **green**,
including the new `liveMetricsOverlay` assertion (it resolves as an `Other` element in the player).
**Device-pending (NOT verified)**: the overlay's **live visual** — the zone colors filling in, the ❤️ pulse,
and a real bpm rendering — needs a device with an HR source (Apple Watch or a BLE band). The sim has no
watch/HR, so the walkthrough asserts only the **no-source** state; a clean sim build + the no-source render
+ the pure zone tests prove the **shape**, not a live-HR rendering (same honesty bar as A1/A2/A3).

---

## [2026-06-01] A3 — MetricsSource abstraction + generic BLE heart-rate band (WorkoutTracker)

**Decision**: Implemented prompt A3 (`pdd/prompts/features/live-workout-studio/A3-…md`,
branch `feat/live-workout-metrics-source`). The live-metrics layer is now behind a pluggable
**`MetricsSource`** protocol so live HR can come from **either** the Apple Watch (A1) **or** a generic
**BLE heart-rate band** (chest straps / Polar / Garmin / any device exposing the standard Heart Rate
Service), with band identification + a picker. This realizes the A1 doc-comment promise (the surface was
shaped to become a protocol with a BLE conformer without call-site churn) and the RESEARCH.md §3.3
decision (non-Apple bands connect on-device via the BLE Heart Rate Profile — never a cloud API).

**Concrete, non-obvious choices made:**
- **`MetricsSource` protocol** (`Services/MetricsSource.swift`, `@MainActor`, `AnyObject`) mirrors the
  `HighlightSelector` pluggability (decisions.md 2026-05-30): `latestHR`, `energy`, `samples` (the engine
  `HRSample` buffer), a source-agnostic `state: MetricsSourceState`
  (`.unavailable/.idle/.connecting/.connected/.streaming`), `isReachable`, `displayName`,
  `start(for:sport:category:)`, `stop()`. The app talks only to this — HR transport is invisible to the
  player / Live Activity / overlay. `HighlightEngine` stays platform-free (grep-confirmed: no
  HealthKit/CoreBluetooth/WatchConnectivity import in the package); live HR is plain `HRSample`s at the
  `Services` boundary, exactly like the post-hoc path.
- **`isWatchReachable → isReachable` + `connectionState → MetricsSourceState` migration**: A1's
  `LiveWorkoutService` became `AppleWatchMetricsSource` with **byte-for-byte identical** WCSession /
  buffering / offset behavior (the A1 offset + mapping + round-trip tests pass unchanged, only the type
  name updated). The watch-specific `isWatchReachable` was renamed to the protocol's `isReachable` (the
  one call-site change the A1 review flagged); the watch's `ConnectionState` is **kept internal** (the
  resume/replace lifecycle in `WorkoutHomeView` is genuinely watch-specific) and **mapped** onto
  `MetricsSourceState` via a computed `state` (`.workoutRunning` → `.streaming` once a sample arrives,
  else `.connected`; `.active` → `.connecting` when reachable; `.unsupported` → `.unavailable`).
- **BLE parsing isolated into a pure static func** `BLEHeartRateMetricsSource.parseHeartRate(_:)` so it is
  unit-testable with no device/band: byte 0 = flags, **bit 0** selects UInt8 (1 byte) vs little-endian
  UInt16 (2 bytes) BPM; optional sensor-contact (bits 1–2) / energy-expended (bit 3) / RR (bit 4) fields
  are **ignored** (only BPM needed); an empty or too-short buffer (e.g. flags say UInt16 but one value
  byte) returns `nil` so a malformed packet can't poison the buffer. **`energy = 0`** — the Heart Rate
  Profile has no calorie field. Unlike the watch (which relays its own monotonic `t`), a BLE measurement
  has no timestamp, so its `sessionOffset` uses **wall-clock elapsed** since `session.startedAt`, clamped
  ≥ 0. The central scans `0x180D`, exposes a deduped `[BLEDevice]` (by `CBPeripheral.identifier`, a plain
  value type so the picker/tests don't import CoreBluetooth), connects a chosen one, discovers `0x180D` →
  `0x2A37`, and subscribes for ~1 Hz notifications.
- **Swift-6 CoreBluetooth concurrency**: `CBCentralManagerDelegate`/`CBPeripheralDelegate` callbacks are
  `nonisolated` (they arrive on CB's queue) and hop to `@MainActor` via `Task { @MainActor in … }` before
  mutating observable state — mirroring the `WCSessionDelegate` pattern. The static `CBUUID` constants and
  `parseHeartRate`/`sessionOffset`/`resolve` are marked `nonisolated` so the off-actor callbacks (and the
  pure tests) can reach them; the non-Sendable `CBPeripheral`/`CBCentralManager` are carried into the
  MainActor hop via `nonisolated(unsafe) let` (the documented escape hatch — they're confined to CB's
  queue and CB tolerates `connect` from any queue). Bluetooth permission is **deferred**: the
  `CBCentralManager` is created lazily on `prepare()` (when the picker opens), not at app launch.
- **`LiveMetricsCoordinator` keeps the `AppModel.liveWorkout` property NAME** (so A2/A4 call sites don't
  churn) and is itself a `MetricsSource`: it holds both concrete sources, tracks a user `selectedSource`
  + the discovered-BLE list, and **forwards** the whole protocol surface to the active source. `stop()`
  stops **both** sources so a mid-session source switch never strands a transport. Selection is a pure,
  unit-tested rule `resolve(selected:watchUsable:hasBLEDevice:)`: an explicit pick wins; else prefer the
  watch when usable (paired + app installed); else BLE if a band was chosen; else default to the watch
  (its `.unavailable` drives the UI's "no source" message — A1 behavior preserved). A small
  `connectionState` shim forwards to the watch source so the watch-specific resume/replace guard in
  `WorkoutHomeView` is unchanged.
- **Picker UI** (`HeartRateSourcePicker`) is presented as a **sheet** from `WorkoutSettingsView`'s new
  "Live metrics" section — a sheet may carry its own `NavigationStack`, so the no-nested-stack rule for
  the module is honored. It lists Apple Watch + scanned bands (rows have `accessibilityIdentifier`s:
  `hrSourceAppleWatch`, `hrSourceBLEDevice`, plus `openHeartRateSource`); scanning starts on appear (the
  one-time Bluetooth prompt) and stops on disappear. The player's status text became source-aware (BLE
  states vs the watch wording).
- **No new `@Model`** → `SnappetSchema.models` unchanged. `NSBluetoothAlwaysUsageDescription` added to the
  app Info.plist.

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**, 0 warnings from
these changes. `SnappetWatch` (watchOS 26.5 sim) → **BUILD SUCCEEDED** (A1 unbroken). `SnappetTests` →
**46/46 pass** (the 28 prior + 18 new: HR-measurement parser UInt8/UInt16 with/without sensor-contact &
energy fields + malformed/short → nil, BLE wall-clock offset, BLE ingest/energy/state, and the
source-selection rule + coordinator forwarding). `HighlightEngine` → **18/18**, source unchanged.
`WorkoutWalkthroughTests` → **green** (the `MetricsSourceState` change didn't alter the walkthrough's
asserted text; the overall-timer assertion still passes).
**Device-pending (NOT verified)**: a **real BLE band connect + live HR stream** — the `0x180D` scan,
`0x2A37` subscription, parse-to-`HRSample`, and the picker's connect flow — only run on a device with a
physical heart-rate band. A sim build proves the shape + the pure parser, **not** a live stream (the same
honesty bar as A1's WCSession relay). Battery/latency of a sustained BLE notify stream is also a device check.

**Post-review hardening (2026-06-01, same branch)**: review fixes applied before merge: (1) the resume
guard in `WorkoutHomeView` used the watch-specific `connectionState != .workoutRunning`, which is **always
true for a BLE session** (BLE never sets `.workoutRunning`) → every resume restarted metrics and **cleared
the BLE HR buffer**; added a source-agnostic `LiveMetricsCoordinator.isSessionActive` (set in `start`,
cleared in `stop`) and the guard now reads `!isSessionActive`; (2) `BLEHeartRateMetricsSource.connect`
now disconnects the previously-connected band before connecting a new one (else two peripherals stream
into `ingest` at once) and early-returns on a double-tap of the already-connected band (no `.streaming`→
`.connecting` downgrade); (3) `stop()` resets state from **any** active state incl. `.connecting` (a
workout ended mid-connect no longer strands "Connecting…") and clears the peripheral ref; (4) `startScan()`
clears the stale `discovered` list and no longer double-invokes the scan. The "duplicate device on rapid
discover" flag was **refuted** (the `didDiscover` Tasks hop to the serialized `@MainActor`, so the
`contains` check isn't racy). Added 2 tests (flags-only UInt16 buffer → nil; `isSessionActive` start/stop);
SnappetTests 46→48. **Known limitation (documented, not fixed)**: switching the HR source *mid-session*
doesn't auto-start the newly-selected source, and watch-usability isn't `@Observable` (a watch pairing
mid-workout won't re-resolve the active source) — both are unusual mid-session interactions, deferred.
Re-verified: app + watch BUILD SUCCEEDED, SnappetTests 48/48, HighlightEngine 18/18 (engine import-clean),
WorkoutWalkthroughTests green.

---

## [2026-06-01] A2 — overall workout timer + background Live Activity (WorkoutTracker)

**Decision**: Implemented prompt A2 (`pdd/prompts/features/live-workout-studio/A2-…md`,
branch `feat/live-workout-overall-timer`). A running WorkoutTracker session now has (1) an **overall
workout timer** in the player and (2) a **Live Activity** (Lock Screen + Dynamic Island) showing the
overall timer + live HR + current exercise/set — solving the user's "routine can't run in background" +
"no overall timer" asks (RESEARCH.md §3.2) and making live HR visible without the app foregrounded.

**Concrete, non-obvious choices made:**
- **Overall timer = wall-clock `Text(timerInterval:)`, no background CPU.** The player header renders
  `Text(timerInterval: session.startedAt...distantFuture, countsDown: false)` so SwiftUI/the OS ticks it
  off the wall clock — correct across backgrounding *by construction*, the same end-`Date` philosophy the
  rest timer already uses. It runs alongside the per-set rest circle, labelled "Total" vs the rest timer.
  It carries `accessibilityIdentifier("overallWorkoutTimer")` + an `.accessibilityValue` from the pure
  `WorkoutLiveSnapshot.elapsedString` so the walkthrough can assert it deterministically. No per-second
  state, no timer loop for the overall clock — only the *live HR* needs the watch session.
- **New Widget Extension target `SnappetWidgets`** in `project.yml` (`type: app-extension`,
  `NSExtensionPointIdentifier = com.apple.widgetkit-extension`, iOS 18 deployment, `SKIP_INSTALL=YES`,
  bundle id `com.snappet.app.widgets`), **embedded** in the phone app like the watch target, and added to
  the `Snappet` scheme's build targets. Added `NSSupportsLiveActivities = YES` to the app Info.plist.
- **One shared `ActivityAttributes` contract** (`Shared/WorkoutActivityAttributes.swift`, compiled into
  *both* the app and the widget extension via the `Shared/` path) — same can't-drift pattern as
  `LiveWorkoutMessage`. Static `routineName`; `ContentState { startedAt: Date; hrBpm: Int?;
  exerciseName: String; setProgress: String }`. The Live Activity renders the overall timer with
  `Text(timerInterval: state.startedAt…)` (OS-ticked, no pushed per-second updates). `ContentState` is
  `Codable, Hashable, **Sendable**` — the `Sendable` is load-bearing so `Activity<…>` is Sendable.
- **`LiveActivityController` service** (`Services/`, `@MainActor @Observable`, guarded
  `#if canImport(ActivityKit)`): `start(routineName:startedAt:…)`, `update(_:)`/`update(hrBpm:…)`, `end()`.
  Every entry point **no-ops** where ActivityKit can't be imported, the OS is < iOS 16.1, or
  `ActivityAuthorizationInfo().areActivitiesEnabled == false`; `start` ends any prior activity first so a
  resume never strands an orphan. Holds the activity as `Any?` + a typed `@available(iOS 16.1)` computed
  accessor so the type isn't referenced below its availability floor.
- **Swift-6 send of the activity into a detached async update**: `Activity` is documented thread-safe &
  `Sendable`, but the local picks up a main-actor tag from the `@MainActor` getter, so `Task { await
  activity.update(...) }` tripped region isolation ("sending main-actor-isolated value to a nonisolated
  method"). Resolved with `nonisolated(unsafe) let act = activity` immediately before the `Task` — the
  documented escape hatch for a value that's genuinely safe off-actor. (Marking `ContentState: Sendable`
  was necessary but not sufficient on its own.)
- **Lifecycle co-located with the existing session lifecycle** in `WorkoutHomeView`: `start` the activity
  in `startLiveMetrics` (so every start/replace path covers it) + on `resume` (the activity lives on the
  phone independently of the watch, so it's (re)started even on a warm resume after a cold relaunch);
  `end()` in `finishWorkout` alongside `liveWorkout.stop()`. The player pushes `update`s via `.onChange`
  on phase / exerciseIndex / setIndex / `liveWorkout.latestHR`, mapping a pure `WorkoutLiveSnapshot`
  (platform-free, in `Features/WorkoutTracker/`) → `ContentState`. The snapshot is the single source of
  truth both the in-player timer and the activity read, and is what the unit tests exercise.
- **No new `@Model`** → `SnappetSchema.models` unchanged. `HighlightEngine` untouched (no platform import;
  `grep` confirms none added).

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate` defines app + watch + **SnappetWidgets**
targets. `Snappet` iOS scheme builds for the iPhone 17 Pro sim (with the embedded widget extension +
watch) → **BUILD SUCCEEDED**, 0 warnings from these changes (the widget `.appex` builds and embeds).
`SnappetWatch` builds for the watchOS 26.5 sim → **BUILD SUCCEEDED** (A1 unbroken). `SnappetTests` →
**24/24 pass** (the 15 existing + 9 new: elapsed-time formatting, snapshot field carry-through, and the
`ContentState` field-mapping + Codable round-trip). `HighlightEngine` → **18/18**, source unchanged.
`WorkoutWalkthroughTests` → **green**, including the new `overallWorkoutTimer` assertion.
**Device-pending (NOT verified)**: the actual Live Activity **rendering** — the Lock Screen banner and
the Dynamic Island compact/minimal/expanded regions — and the live HR appearing there, only truly run on
a device (Live Activities need a real Lock Screen / Dynamic Island; the sim build proves the *shape*, not
the on-device activity). Update-budget behavior under a real workout is also a device check.

**Post-review hardening (2026-06-01, same branch)**: review fixes applied before merge: (1) **HR update
storm** — the player fired an ActivityKit `update` on every ~1 Hz HR sample (would exhaust the update
budget and lag the Lock Screen); added a pure, unit-tested `WorkoutLiveSnapshot.shouldPush` throttle —
structural changes (exercise/set text) push immediately, HR-only changes are rate-limited to ≥2 s — and
`LiveActivityController.update(_:)` now consults it via stored `lastSnapshot`/`lastPushedAt`; (2) **warm
resume no longer end+recreates** a Live Activity that's already showing (new `isRunning` guard);
(3) `startLiveActivity` seeds a real `"Set 1 of N"` so the Lock Screen isn't blank if backgrounded before
the player appears. The "set-number off-by-one during rest" flag was **refuted** (SwiftUI applies all
`@State` mutations before `.onChange` fires, so the snapshot reads the settled `phase`). Added 4 throttle
unit tests (SnappetTests 24→28). Re-verified: app + watch BUILD SUCCEEDED, SnappetTests 28/28,
HighlightEngine 18/18, WorkoutWalkthroughTests green.

---

## [2026-06-01] A1 — watchOS companion + live HR relay implemented (WorkoutTracker gains a live path)

**Decision**: Implemented prompt A1 (`pdd/prompts/features/live-workout-studio/A1-…md`,
branch `feat/live-workout-watchos-companion`). WorkoutTracker now has a **live metrics source**:
a new **watchOS companion target** (`ios/App/SnappetWatch/`) runs an `HKWorkoutSession` +
`HKLiveWorkoutBuilder` and relays live HR/energy to the phone over `WCSession`; the phone starts the
matching `HKWorkoutActivityType` on the watch from the routine. This **supersedes the v1
post-hoc-only / no-watchOS deferral for WorkoutTracker only** — the flagship Reels app's
`HealthKitService` (post-hoc) is unchanged and untouched.

**Concrete, non-obvious choices made:**
- **WCSession message shape** — one shared `LiveWorkoutMessage` enum (in `ios/App/Shared/`, compiled
  into *both* the phone and watch targets via `project.yml` so the wire can't drift). Three messages,
  discriminated by a `kind` string key, encoded as plist dicts: `start(activityType: UInt)` (the
  `HKWorkoutActivityType.rawValue`), `stop`, and `metrics(hrBpm, energyKcal, t)`. Sent via
  `sendMessage` when reachable, falling back to `transferUserInfo` so a start/stop/sample isn't
  dropped while the counterpart is briefly unreachable.
- **Activity mapping table** (`WorkoutActivityMapping`, the inverse of `HealthKitService.map`):
  `SportTag` wins first — `.climbing → .climbing`, `.calisthenics → .functionalStrengthTraining`,
  `.general` falls through to the routine's **dominant `ExerciseCategory`**: `strength/powerlifting →
  .traditionalStrengthTraining`, `cardio → .running`, `plyometrics → .jumpRope`, `stretching →
  .flexibility`, `olympic/strongman → .functionalStrengthTraining`. Final fallback (no sport, no
  category) is `.traditionalStrengthTraining` (a gym routine's sensible default; the spec's `.other`
  is reachable only via an unmapped type). Dominant-category tie-break is deterministic by rawValue.
- **HR buffer attaches to `WorkoutSession`** via `LiveWorkoutService.sessionOffset(...)`: incoming
  watch samples carry `t` since the *watch* session start; the phone re-bases each onto the
  `WorkoutSession.startedAt` timeline (engine convention: `HRSample.t` = seconds since session start),
  preferring the watch's monotonic clock but flooring to wall-clock-elapsed if it's wildly ahead, and
  clamping ≥ 0. Buffer lives on the service (not persisted yet) for B2 to flush. Lifecycle is owned by
  `WorkoutHomeView` (`start(for:)` on session create/replace, `stop()` in `finishWorkout`), matching
  where the session lifecycle already lives — not the player.
- **Pluggability for A3**: `LiveWorkoutService`'s public surface (`connectionState`, `latestHR`,
  `energy`, `isWatchReachable`, `start(for:)`, `stop()`, `samples`) is shaped to become a
  `MetricsSource` protocol with a `BLEHeartRateSource` conformer with **no call-site change**,
  mirroring the `HighlightSelector` pluggability pattern. `HighlightEngine` is untouched — live HR
  becomes plain `HRSample` value types at the `Services` boundary.
- **Watch target config**: `WKBackgroundModes = [workout-processing]` (keeps HR flowing wrist-down /
  phone-pocketed), HealthKit + background-delivery entitlements, `WKCompanionAppBundleIdentifier =
  com.snappet.app`, bundle id `com.snappet.app.watchkitapp`, embedded in the phone app. Added a
  `SnappetTests` app unit-test target (separate from the platform-free `HighlightEngineTests`) for the
  pure pieces.
- **Build gotcha recorded**: building the iOS scheme with `-sdk iphonesimulator` forces that SDK onto
  the embedded **watch** target and breaks it ("HKLiveWorkoutBuilder only available in iOS 26"). Build
  the `Snappet` scheme with **`-destination` only** (no `-sdk`) so each target picks its own SDK. The
  `WorkoutWatchManager` must subclass `NSObject` (HK delegates require it).

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate` produces both an iOS app and a
watchOS app target. `SnappetWatch` builds for the watchOS 26.5 simulator → **BUILD SUCCEEDED**, 0
warnings. The `Snappet` iOS scheme (with the embedded watch target) builds for the iPhone 17 Pro sim →
**BUILD SUCCEEDED**, 0 warnings from these changes. `SnappetTests` → **15/15 pass**
(`WorkoutActivityMapping` + the HR-buffer offset math + message round-trip). `HighlightEngine` →
**18/18 pass**, source unchanged.
**Device-pending (NOT verified — the PLAN's "after A1" decision gate)**: the actual live relay — watch
starts the mapped `HKWorkoutSession`, HR streams to the phone within ~3 s, keeps updating with the
phone backgrounded, and battery cost — only runs on a **paired physical Apple Watch + iPhone**. A
simulator build proves the shape, not the stream.

**Post-review hardening (2026-06-01, same branch)**: a multi-angle review surfaced six fixes, applied
before merge: (1) watch `start()` sets a synchronous `starting` flag so a 2nd start during the async
auth await can't spawn a duplicate `HKWorkoutSession`; (2) `replaceActiveAndStart` now `stop()`s the old
watch session first (else the watch's `!isRunning` guard silently drops the new start); (3) all resume
paths (dashboard banner, "Resume current workout", re-tapping the same routine) route through a `resume()`
that restarts live metrics when the service isn't already running — fixing no-HR after a cold relaunch;
(4) the phone only promotes to `.workoutRunning` when a paired watch with the app installed exists
(`isPaired && isWatchAppInstalled`), so the overlay doesn't strand at "Waiting for heart rate…" with no
watch; (5) `LiveWorkoutMessage` metrics decode now requires every field (no `?? 0`) so a malformed
message drops instead of poisoning the buffer with phantom 0-bpm samples; (6) `.cardio → .mixedCardio`
(generic cardio isn't necessarily running) + removed dead `hrUnit`/`kcalUnit`. The "inverted tie-break"
flag was **refuted** (the comparator is deterministic, which is its only contract). `WorkoutWalkthroughTests`
gained `-uiTestFreshStore` (it was the lone UI test without it — a leftover active session was triggering
the start-conflict dialog). Verified: iOS + watchOS BUILD SUCCEEDED, `SnappetTests` 15/15, `HighlightEngine`
18/18, `WorkoutWalkthroughTests` + `SuiteSmokeTests` green (walkthrough green on two consecutive runs).

---

## [2026-06-01] Live Workout Capture + Video Studio initiative — reopens the watchOS/BLE/in-app-capture deferrals (for WorkoutTracker only)

**Decision**: Scoped a new initiative (research + plan, branch `plan/live-workout-video-studio`, GitHub
issue #15) that turns **WorkoutTracker** from a foreground-only set logger into a live, instrumented,
media-rich workout with an on-device video studio. Direction chosen with the user (2026-06-01):
(1) **Apple Watch companion first** — a new watchOS target running `HKWorkoutSession`/`HKLiveWorkoutBuilder`
with a `WCSession` relay is the only supported way to get live HR + background execution + "start the
right workout on the watch"; (2) **unify** — finishing a WorkoutTracker session feeds the existing
**`HighlightEngine`/`ReelPlanner`** (HR + tagged clips + manual selection) to generate highlights, with
**no engine change**; (3) **full CapCut-style editor** on `AVMutableVideoComposition` +
`AVVideoCompositionCoreAnimationTool`. Two parallel tracks (A: live capture A1–A4; B: studio B1–B5) in
`pdd/prompts/features/live-workout-studio/PLAN.md`; feasibility in that folder's `RESEARCH.md`.
**Why**: the selector/engine were kept platform-free and pluggable *specifically* so a live path could be
added without a rewrite — this is that day. Live HR becomes plain `HRSample`s at the `Services` boundary,
so `HighlightEngine` stays platform-free; all new platform I/O is a `Services/` type; a `MetricsSource`
protocol (Apple Watch → BLE → post-hoc HealthKit) mirrors the `HighlightSelector` pluggability.
**Supersedes (scoped to WorkoutTracker, NOT the flagship Reels app)**: the v1 calls *"reads COMPLETED
workouts, not a live watchOS session"* (2026-05-30) and *"out of scope for v1: watchOS live capture,
generic BLE bands, in-app capture"* (`PLAN-ios-to-shippable.md`). This initiative sits **on top of** a
shipped v1 and does not block it.
**Rules out (for now)**: **Fitbit live / Google Fit on iOS** — no real-time API, cloud-only, violates the
on-device-only constraint (`RESEARCH.md` §3.3); a non-Apple band is only ever a *post-hoc HealthKit*
source if its app writes to Health, or a *live BLE* source (`0x180D`) via CoreBluetooth in Phase 2.
Health Connect belongs to the Android target. **Status**: research + plan only — no implementation code
yet; A1 (watchOS companion) is authored and ready to run.

---

## [2026-05-31] Pomodoro settings persist via @AppStorage in the view, applied to the engine

**Decision**: Focus/break lengths are stored as `@AppStorage("pomodoro.focusMinutes"/".breakMinutes")`
in `PomodoroRootView` (and bound straight into the settings sheet); the view pushes them into the
`@Observable PomodoroTimer` via a new `applyDurations(focusMinutes:breakMinutes:)` on appear and on
change. The 7-day focus chart (`PomodoroFocusChart` + `PomodoroStats.last7Days`) renders on both the
root and atop History, fed by a single `@Query` over the last 7 days. A `UINotificationFeedbackGenerator`
fires in `PomodoroTimer.completePhase` (UIKit guarded by `#if canImport(UIKit)` to keep the type buildable
off-device). **Why**: `@Observable` classes can't host the `@AppStorage` property wrapper, so persistence
lives in the view (the one SwiftUI place it works) and the timer stays a plain engine that's told its
durations. One shared 7-day query avoids a second round-trip. **Rules out**: persisting the timer object
itself; a new `@Model` for history (it reads existing `PomodoroSession` rows); a nested `NavigationStack`
(History is reached via `navigationDestination(for: PomodoroRoute.self)` on the suite's stack).

---

Product-level decisions (separate repo, etc.) live in the web repo's
`decisions.md`; this file is native-implementation-specific.

---

## [2026-05-31] Button-driven, UI-testable navigation via a shared SuiteRouter

**Decision**: Replaced the modules' value-based `NavigationLink(value:)` list rows with plain `Button`s
that push onto a shared `NavigationPath` owned by a new `@Observable SuiteRouter` (injected via
`.environment` at the App Library, which now uses `NavigationStack(path:)` and pushes modules by a
`ModuleRoute` value). Every interactive row got an `accessibilityIdentifier`. Added a `SnappetUITests`
target with a workout walkthrough + an all-modules smoke test.
**Why**: XCUITest cannot activate SwiftUI `List` `NavigationLink` rows in this app — they expose as
`Cell → StaticText` with no button trait, so no tap (cell / text / identifier / coordinate) navigates,
which made every detail screen un-automatable. `Button`s are real, hittable controls; a spike proved the
end-to-end chain (card → row → detail → player → finish) is now drivable and screenshot-verified.
**Also**: session detail pushes a lightweight `SessionRoute(id:)`, never the `WorkoutSession` model — the
model type is the player `fullScreenCover(item:)`, and pushing it onto the path while that cover exists
wedges the push.
**Rules out**: relying on value-based NavigationLink rows for testable navigation; modules owning their
own `NavigationStack` (they still ride the App Library's, now path-based).
**Known limitation**: the **History → session-detail** row is the one row left as a value-based
`NavigationLink` — a `Button` there provably never fired its action on tap (a narrow SwiftUI/List quirk,
confirmed by logging vs a working control). It works for users but isn't XCUITest-tappable; kept rather
than shipping a dead Button.
**Verified**: `xcodebuild` iPhone 17 Pro sim BUILD SUCCEEDED; `SnappetUITests` both tests green
(`WorkoutWalkthroughTests`, `SuiteSmokeTests`). Shipped as a stacked PR on top of #6/#7.

## [2026-05-31] Workout tracker UX: fix start/finish transitions without a module-owned NavigationStack (#5)

**Decision**: A deep UX review (issue #5) found the workout player + start-conflict dialog were presented from `WorkoutHomeView` while a pushed `RoutineDetailView` sat on top — making presentation fragile and dropping the user back on the routine's prescription page after a workout. Rather than give the module its own `NavigationStack`/`NavigationPath` (banned — modules ride the App Library's stack), the routine detail now **pops itself (`@Environment(\.dismiss)`) before calling `start()`**, so the cover/dialog present from the home (top of stack) and finishing lands on the home; `finishWorkout` switches to the **Dashboard** on a saved finish. The Routines list's previously-dead `start` closure is wired to a swipe + context-menu "Start". `RoutineDetailView` hides the suite tab bar (`.toolbar(.hidden, for: .tabBar)`) so its bottom Start bar doesn't stack on it. Separately (branch `fix/workout-player-session`), the live player never persists a **zero-set** session (auto-discard), and the rest timer is driven off a target **end `Date`** so backgrounding doesn't make it drift.
**Why**: keeps the no-nested-NavigationStack contract intact while fixing the actual transition bugs; `dismiss()`-then-start is the idiomatic way for a pushed child to hand presentation back to its host.
**Rules out**: a module-owned navigation stack/path; saving empty workouts; a wall-clock-naive rest timer.
**Deferred** (issue #5 "Low"): icon-only segmented section labels, disambiguating the two "Workout*" app names, and flattening the triple-stacked routine-editor sheets.
**Shipped on**: branches `fix/workout-nav-and-transitions` + `fix/workout-player-session`.
**Verified**: `xcodebuild` for the iPhone 17 Pro sim → **BUILD SUCCEEDED** (both branches merged); no new warnings from these changes. The transition *feel* (pop-then-present, tab-bar hide, rest-timer foreground correction) still needs a sim/device run.

## [2026-05-31] Pivot to the Snappet daily-app SUITE — shared store + module registry + dashboard (P9)

**Decision**: Expanded from a single workout app to the **daily-app suite** thesis (#60 §D): a `TabView`
shell (Home dashboard + App Library), an on-device **SwiftData** shared store (**Snappet Core**), and a
pluggable **module registry**. Built 6 mini-apps alongside the existing Workout module — Pomodoro,
Habits, Journal (productivity); Tip, Split Expenses, Budget (finance) — via parallel agents.
**Architecture / contract** (so the suite stays pluggable):
- `SnappetCore` (`Core/SnappetCore.swift`) wraps the shared `ModelContext` and exposes
  `log(module:action:summary:metric:)`. Every mini-app logs usage there; the **Home dashboard**
  (`@Query` over `UsageRecord` + Swift Charts) aggregates *historical sub-app usage* across the suite.
  The App Library logs an `open` event centrally, so every module gets baseline tracking for free.
- A mini-app = a self-contained `Features/<App>/` folder vending `AppModule` (`Core/AppModule.swift`)
  with `id/title/subtitle/systemImage/tint/category/destination`. `ModuleRegistry.all` lists them;
  `SnappetSchema.models` lists every `@Model` (the one central place new persistence types are added).
- Modules are **pushed into the App Library's `NavigationStack`** → they must NOT nest their own.
- Permissions are **per-module**, not global: the suite opens instantly; the Workout module primes
  Health/Photos on first entry (the old global onboarding gate was removed).
**Persistence**: SwiftData. `@Model` types: `UsageRecord`, `PomodoroSession`, `Habit`+`HabitCompletion`,
`JournalEntry`, `ExpenseGroup`+`ExpenseRecord`, `BudgetCategory`+`BudgetTransaction`. Mini-apps key
relations by `UUID` foreign keys (not `@Relationship`) for clean per-parent `#Predicate` queries.
**Verified**: full `xcodebuild` for the simulator → **BUILD SUCCEEDED** (foundation + all 7 modules),
app installs + launches, Home dashboard renders. Device run + each app's real-data behavior still pending.

## [2026-05-31] Photos rendered as Ken-Burns clips instead of being dropped (P8)

**Decision**: `ReelExporter` previously filtered to `kind == .video` and silently dropped every photo
highlight (a photo-only workout exported nothing). Added `PhotoClipRenderer` (`AVAssetWriter` +
pixel-buffer adaptor) that renders each photo into a short H.264 **Ken-Burns** clip (slow 1.0→1.1 zoom
+ gentle pan), and `makeComposition` now iterates `plan.segments` **in order**, inserting video ranges
and rendered photo clips alike (photos are silent). Fixes preview + export together (both use
`makeComposition`).
**Why**: the engine/planner already select photo highlights and reserve `photoStill` seconds — only the
exporter ignored them. Rendering-to-clip keeps the composition's track-insertion model uniform (no
`AVVideoCompositionCoreAnimationTool` special-casing).
**Choices/limitations**: photo clips render at a fixed **1080×1920 portrait** canvas; mixed-orientation
normalization across video + photo segments (a unifying `AVVideoComposition`/`renderSize`) is **not**
done — pre-existing for video-only reels too, deferred. A failed photo render is skipped, never fails
the reel.
**Verified**: app type-checks (Swift 6, 0/0); full `xcodebuild` for the simulator → SUCCEEDED with
`PhotoClipRenderer.swift` compiled; app installs + launches. The actual Ken-Burns *visual* needs a
device/sim run with real photos.

## [2026-05-31] App now BUILDS + RUNS on the iOS simulator (not just type-checks); fixed Info.plist bundle keys

**Decision / milestone**: With Xcode 26.5 + iOS 26.3/26.4 simulator runtimes now present, ran a full
`xcodebuild` (compile **and link**) for `iphonesimulator` → **BUILD SUCCEEDED**, then `simctl install`
+ `launch` on an iPhone 17 (iOS 26.4) sim → the **value-first onboarding screen renders** and the app
stays alive (no crash). This supersedes the earlier "type-check only" verification ceiling.
**Bug fixed (build couldn't catch it; install did)**: `Info.plist` was missing `CFBundleIdentifier`,
`CFBundleExecutable`, `CFBundlePackageType`, etc. Because `GENERATE_INFOPLIST_FILE: NO`, Xcode injects
nothing, so the built `.app` had no bundle ID and `simctl install` failed ("Missing bundle ID"). Added
the core bundle keys (as `$(PRODUCT_BUNDLE_IDENTIFIER)` etc.) + orientations + `LSRequiresIPhoneOS`.
**Build invocation that works here** (the generic destination wants iOS 26.5 which isn't installed):
`xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=<booted-sim-udid>' CODE_SIGNING_ALLOWED=NO build`.
**Still device-only**: HealthKit has no Apple Watch *workouts* in the simulator and Photos has no
real media, so the end-to-end reel flow (real workout → auto-found media → reel) still needs a device
(P1 / `RUNBOOK-device.md`). The `Snappet.xcodeproj` is generated by XcodeGen and gitignored.

## [2026-05-31] Value-first onboarding + JIT permissions; `.limited` Photos → manual picker (P2)

**Decision**: First launch shows an `OnboardingView` that explains the value before requesting
anything; Health + Photos are requested only on the explicit "Connect" tap (`AppModel.completeOnboarding`).
Onboarding is gated on a persisted `snappet.hasOnboarded` flag (HealthKit read-auth status isn't
queryable). `.limited` Photo access (or an empty auto-discovery) routes to a `PHPicker` manual picker
(`MediaPicker`) → `PhotoLibraryService.media(forIdentifiers:)`.
**Why**: #60 §C (value-first, JIT). Also fixed a latent bug — `requestAccess()` was never called, so
Photos auth was never requested and the reel flow would always throw `.denied`.
**Rules out**: silent permission prompts on appear; assuming full-library scan under `.limited`.
**Verified**: app type-checks vs iOS 18; permission UX itself needs a device.

## [2026-05-31] In-app reel preview reuses the composition — no export round-trip (P3)

**Decision**: `ReelExporter.makeComposition(for:) async throws -> sending AVMutableComposition` is
shared by preview and export. `ReelViewModel` wraps it in an `AVPlayer` for an inline `VideoPlayer`;
edits (pin/remove/reorder/restore) invalidate the preview so the next build reflects them.
**Why**: an `AVMutableComposition` *is* an `AVAsset`, so the exact cut is previewable without exporting.
`sending` lets the freshly-built composition cross from the nonisolated exporter to the `@MainActor` VM
under Swift 6 isolation.
**Rules out**: exporting just to preview. Photo-only reels can't preview yet (degrade gracefully).

## [2026-05-31] Ship prep: privacy manifest declares NO data collection (on-device) (P7)

**Decision**: Ship `PrivacyInfo.xcprivacy` with `NSPrivacyTracking=false` and empty
`NSPrivacyCollectedDataTypes` — the app has no backend and transmits nothing; Health/Photos are read,
processed, and written back entirely on-device, so there is no *collected* (off-device) data to
declare. Declared the two required-reason APIs actually used: file timestamps (C617.1 — app's own temp
files via `FeedbackStore`/`ReelExporter`) and UserDefaults (CA92.1 — the onboarding flag). App icon
scaffolded as a single 1024×1024 asset-catalog slot (`ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`);
the actual `AppIcon.png` art + TestFlight upload are deferred (no signing/art in this environment).
Display name pinned in Info.plist + `INFOPLIST_KEY_CFBundleDisplayName`.
**Rules out**: declaring data collection we don't do; shipping without a privacy manifest.

## [2026-05-31] P1 device build is the user's step — runbook authored, not executed

**Decision**: Added `pdd/prompts/features/01-ios-device-build-and-run.md` + `ios/App/RUNBOOK-device.md`.
P1 (first device run + first `highlight-feedback.jsonl`) is **not completable headless** — it needs the
user's Mac + paired Apple Watch with real workouts + a physical iPhone (HealthKit/Photos are device-only).
**Rules out**: claiming on-device runtime is verified. It is the one remaining unproven layer; the
runbook is the path to proving it.

## [2026-05-30] Pin/order are app composition state, NOT fields on the engine `Highlight` (P4)

**Decision**: Finishing the feedback loop (prompt `04-engine-finish-feedback-loop.md`) added **pin /
reorder / restore** to the reel editor. Pin and manual order are passed *into*
`ReelPlanner.plan(highlights:media:pinnedIds:order:)` as composition inputs — they are **not** stored
on the `Highlight` struct. The PLAN's earlier wording ("add `pinned` to `Highlight`") is superseded by
this cleaner split.
**Why**: `Highlight` is the algorithm's *output*; the engine never pins or reorders. Keeping edit
state out of the output type preserves "engine produces, app composes," keeps `Highlight` immutable,
and leaves every existing call site/test unchanged (the new planner args default to empty/nil). Pinned
highlights are **budget-exempt** (always included, even over `targetDuration`) because a pin is an
explicit user choice; the canonical `Highlight.pinned` field maps from the app's `pinnedIds` when the
on-device store is eventually built.
**Training data**: pin emits `.pinned` (strong positive), reorder emits `.reordered` — previously
modeled but never fired. The loop now captures them. Verified: engine pin/order logic is unit-tested
(18 tests pass); the UI wiring type-checks vs iOS 18 but is **not** device-run yet.
**Deferred (tracked for P4b/Phase 2)**: `added` (adding a moment the engine missed) — needs a
media/time picker UI; and **pins-survive-regenerate** — regenerate re-runs the engine with fresh ids,
so pins are per-generation for now.
**Rules out**: mutating engine output to carry UI state; treating a type-check as a device run.

## [2026-05-30] PDD initialized in this repo

**Decision**: Add a local `pdd/` layer (context + prompts + evals) to `snappet-mobile`, mirroring the
web repo's structure. The web repo stays the *product brain* (research #60, cross-platform PLAN,
canonical Snappet Core schema); this layer holds the **iOS-implementation** context and the prompt
chain that drives the code here.
**Why**: the codebase had outrun its written context (a working MVP, a finished spike) with no local
PDD scaffolding. Future prompts need iOS-specific conventions and a reality-based project snapshot
without round-tripping to the web repo every time.
**Rules out**: duplicating/forking the canonical schema or research here — we *reference* and mirror
only the parts already implemented; the source of truth stays in the web repo.

## [2026-05-30] v1 reads COMPLETED workouts from HealthKit (post-hoc), not a live watchOS session

**Decision**: The MVP reads already-synced `HKWorkout` + its HR series after the fact, rather than
running a live `HKWorkoutSession`/`HKLiveWorkoutBuilder` on a watchOS companion.
**Why**: the post-workout series is the *authoritative* HR the research recommends for highlight
detection (#60 §3), and it makes v1 runnable **today** against the user's existing Apple Watch
workouts — no watch app to build/install. Live in-session capture is a later phase (0d / Phase 2).
**Rules out**: live in-session HR UI and below-iOS-26 live relay *for v1*. Don't add a watchOS target
to ship the MVP.

## [2026-05-30] Algorithm lives in a platform-free SPM package (`HighlightEngine`)

**Decision**: All selection/scoring/planning logic is a pure-Swift package with zero platform
dependencies; the app talks to it only through plain value types.
**Why**: testability (`swift test`, no device), portability (reuse on watchOS, later Android via port
or shared spec), and a single swap point for the algorithm. The spike concluded the real winner is
probably a *fusion*, so the selector must be pluggable from day one.
**Rules out**: importing HealthKit/AVFoundation/UIKit into the engine; hardwiring HR-only selection.

## [2026-05-30] Selector is a protocol; HR-only is just today's default

**Decision**: `HighlightSelector` is a protocol (`score(at:…)` + a shared `select` pipeline doing
candidate-enumeration / NMS / padding / high-low split). Implementations: `HRHighlightSelector`
(default), `SceneHighlightSelector` (stub, returns 0 until a real vision pipeline exists),
`FusionSelector` (weighted blend, `hrLeaning` = 0.7 HR / 0.3 scene).
**Why**: the Phase-0a spike predicts a fusion beats HR-alone on real data (`RESULTS.md`). Shipping the
fusion path as real-but-inert means the day a vision selector exists, the upgrade is one line in
`AppModel.engine` — no UI/pipeline change.
**Rules out**: baking HR assumptions into the pipeline; a fusion that can't reduce to HR-only (a test
guards that it does when the scene signal is 0).

## [2026-05-30] Ship a best-guess engine now to harvest training data (the feedback loop)

**Decision**: Every reel logs what the engine proposed vs what the user kept/removed/regenerated/
exported, as JSONL on device (`FeedbackStore` → `highlight-feedback.jsonl`), attributed by selector
name + `HighlightConfig.fingerprint`.
**Why**: the spike is NEEDS-REAL-DATA; replaying real feedback offline is how we tune `HighlightConfig`,
learn the HR-vs-content weighting, and turn the synthetic verdict into a data-driven GO. Using the app
produces the dataset that optimizes the app.
**Rules out**: tuning the config from intuition; sending feedback off device (stays local; export only
with consent).
**Open**: the edit UI only fires `shown/kept/removed/regenerated/exported`. The stronger signals
(`pinned`, `added`, `reordered`) are modeled but not yet wired — closing that gap is a Phase-1 finish task.

## [2026-05-30] Auto-find media by capture-time window, with a ±90 s padding guess

**Decision**: `PhotoLibraryService` fetches `PHAsset`s whose `creationDate` falls within the workout
interval ± 90 s, mapping each to a workout-relative offset.
**Why**: "minimize manual work" is the core magic (#60 §A) — the app finds your clips, you don't pick
them. The 90 s grace pads for clock drift between the camera and the HR source.
**Rules out**: a manual-first picker as the default path (it's the *fallback* for `.limited` access).
**Open / unvalidated**: the 90 s number and the whole-clip-vs-clip-internal mapping are a guess until
the **Phase-0b time-sync spike** (`42-native-00b…`) measures real drift. Treat as provisional.

## [2026-05-30] Reel export is on-device AVFoundation; photos are skipped in v0.1

**Decision**: `ReelExporter` turns the platform-free `ReelPlan` into an `AVMutableComposition` and
exports `.mp4` via the modern async `AVAssetExportSession.export(to:as:)`. Video segments only;
photo highlights are dropped from the stitch.
**Why**: fully on-device (privacy, no backend); videos are the core of a reel. The async export API
avoids a continuation/data-race under Swift 6.
**Rules out**: any server-side rendering.
**Open**: photo highlights need a Ken-Burns still render (`photoStill` seconds) — deferred from v0.1.

## [2026-05-30] "Type-checks" ≠ "runs" — be precise about verification

**Decision**: We state exactly what's proven: `HighlightEngine` builds + 14 tests pass; the whole app
**type-checks** against the iOS 18 SDK (Swift 6, 0 warnings). A full `xcodebuild` link/bundle and a
device run are **not** done in this environment (no simulator runtime; HealthKit/Photos need a device).
**Why**: a type-check caught the real `Sendable`/`AVAssetExportSession` bugs, but it does not prove
runtime behavior. Overclaiming "verified" would mislead.
**Rules out**: reporting device-only features as working off a type-check. Next real verification =
`xcodegen generate && open` on a Mac with a device/simulator runtime.

## [2026-05-31] Workout tracker is a separate suite app, not the "Workout" id

**Decision**: The web suite's `workout` app (gym/strength tracker) ships as a new
`Features/WorkoutTracker/` module with id `workout-log`, title "Workout" — alongside, not replacing,
the flagship "Workout Reels" (id `workout`). Catalog (873 exercises, Free Exercise DB) is **bundled**
as a resource and loaded offline; remote exercise photos are **dropped** in favour of category SF
Symbols. Routine/session exercise lists are stored as Codable composites on the `@Model` (loaded and
edited whole) rather than SwiftData relationships. A **top segmented control** drives the 5 sections.
**Why**: the two apps are genuinely different products (HR reels vs. set logging); reusing the id
would collide. Bundling keeps the app on-device-only (no catalog fetch); photos are large + remote
and add little on a phone. Composite storage matches the web app's single-object shape and keeps the
top-level schema simple. A bottom tab bar would collide with the suite's own Home/Apps tab bar.
**Rules out**: a network-fetched catalog; per-set SwiftData relationship rows; a nested bottom TabView.
**Verified**: `xcodebuild` BUILD SUCCEEDED (iPhone 17 Pro sim); app installs + launches into the
module; dashboard renders with the 15 starters seeded; Browse decodes all 873 exercises. This module
has **no device-only dependencies** (no HealthKit/Photos), so the sim run exercises it for real —
unlike Workout Reels. Engine tests unchanged (18/18).

## [2026-05-31] Journal tags via additive SwiftData migration

**Decision**: Add `var tags: [String] = []` to the existing `JournalEntry` `@Model` rather than a
new tag entity or relationship. Tags are normalized at the boundary (`JournalEntry.normalizeTags`:
trim, lowercase, drop empties, de-dupe preserving order). `SnappetSchema.models` is **unchanged**
(the type is already registered — only a stored property is added). Search filters live in a
`filteredEntries` computed property on `JournalRootView` (title/body/any-tag, case-insensitive) via
`.searchable`; the editor commits chips on comma/return and shows removable chips.
**Why**: an additive property with a default triggers SwiftData's **lightweight migration**, so
pre-existing entries (no tags) load without wiping the store — no versioned `SchemaMigrationPlan`
needed. A `[String]` on the model is simpler than a tag entity for free-form, per-entry labels and
keeps `#Predicate`/in-memory filtering trivial. The editor stays a pushed destination (not a nested
`NavigationStack`).
**Rules out**: a destructive migration; a separate Tag `@Model`/relationship; editing existing
`JournalEntry` fields or `SnappetSchema.models`.
**Verified**: `xcodegen generate` + `xcodebuild build-for-testing` (iPhone 17 Pro sim, Swift 6) →
`** TEST BUILD SUCCEEDED **`, 0 Journal warnings. `JournalUITests` compiles. The tag+search flow is
asserted in UI tests but not yet executed on the sim in this pass (build-for-testing only).

## [2026-05-31] Budget `MonthScope` generalised to an arbitrary selected month

**Decision**: `MonthScope` changed from a stateless `enum` of `static` helpers pinned to `.now`
(current calendar month) into a small `Equatable`/`Sendable` value type anchored on a `Date`'s month:
`MonthScope(anchor:)` with instance `contains(_:)`, `start`/`end`, `previous()`/`next()`, `isCurrent`,
and a `label`. The current month is just `MonthScope()`. `BudgetRootView` holds the selected month in
`@State` and a prev/next header steps it, so the summary tiles, per-category progress, and the
spend-by-category donut all reflect the chosen month (backdated transactions appear when you step
back). "Next" is disabled once `isCurrent`. Per-category transactions are a **pushed** screen
(`BudgetCategoryTransactionsView`) where a row opens `AddTransactionView` in edit mode (optional
`transaction:`); the 6-month bar chart lives in `BudgetTrendsView` with aggregation in a pure
`SpendTrend.monthlyTotals` helper. No new `@Model` (reuses `BudgetCategory`/`BudgetTransaction`);
category delete still cascades its transactions by `categoryID`.
**Why**: the data already spans months (transactions carry a backdated `date`) — only the UI was
pinned to "now". A value type makes month stepping a one-liner and keeps the scope testable.
**Rules out**: the old `MonthScope.contains(_:now:)` static call sites (all migrated).
**Verified**: `xcodebuild build-for-testing` (iPhone 17 Pro sim) — TEST BUILD SUCCEEDED; new
`BudgetUITests` compiles into the UI-test bundle. (Live run deferred to the merge pass.)

## [2026-05-31] Split Expenses: manual settlements as a flagged ExpenseRecord

**Decision**: A manual settlement ("X paid Y back") is stored as a normal `ExpenseRecord` with a new
additive flag `var isSettlement: Bool = false` (lightweight migration via the default), `payer = X`,
`participants = [Y]` (the lone recipient), and `amount`. It is **not** split: the balance math in
`SettleUp.balances` treats `isSettlement` records as a direct transfer — `+amount` to the payer's net,
`-amount` to the recipient's net — so recording a settlement equal to a suggested transfer drives that
pair's balances to zero and the greedy plan converges. Editing reuses the existing sheets:
`NewExpenseSheet`/`NewGroupSheet` take an optional model and update it in place; new
`RecordSettlementSheet` inserts the settlement. **Why**: a flagged record keeps one flat model and one
fetch/predicate path, needs no schema/`SnappetSchema.models` change, and feeds the same balance pass —
no second store, no parallel ledger. **Rules out**: a separate `Settlement` @Model; mutating the
greedy algorithm (kept as-is). Dropping a participant who appears on a record warns before saving but
is allowed (past entries keep their names). **Verified**: `xcodebuild build-for-testing` TEST BUILD
SUCCEEDED (iPhone 17 Pro sim, 0 warnings); `ExpenseUITests` compiles. Live run deferred to the merge pass.

## 2026-05-31 — Tip gains persistence (first `@Model`) + editable presets & round-up

**Decision**: Tip — previously `@AppStorage`-only — gets its first persisted model,
`TipCalculation` (`bill`, `tipPct`, `people`, `tipAmount`, `total`, `date`) in
`Features/Tip/TipModels.swift`, registered as one appended line in `SnappetSchema.models`. Each
committed calculation (bill-field commit) both logs a `UsageRecord` (unchanged) and inserts a
`TipCalculation`; `TipHistoryView` lists them newest-first with swipe-delete + clear-all, pushed onto
the shared `SuiteRouter` path (no nested `NavigationStack`). The four preset percentages move from a
hard-coded array to four `@AppStorage` keys (`tip.preset.0…3`), edited via a sheet of steppers. A
`tip.roundUp` toggle rounds the grand total up to the nearest whole currency unit and back-computes
the effective tip so the per-person split stays consistent. **Why**: Tip was the only mini-app
without history; storing a flat snapshot per calc matches the suite's other flat `@Model`s and keeps
per-app `#Predicate` queries trivial. Four discrete `@AppStorage` keys avoid comma-decoding and bind
each stepper directly. **Rules out**: comma-encoded preset string; SwiftData relationships;
recomputing per-person from raw (pre-round-up) total. **Verified**: `xcodebuild build-for-testing`
TEST BUILD SUCCEEDED (iPhone 17 Pro sim); `TipUITests` compiles (history + preset-edit flow).
