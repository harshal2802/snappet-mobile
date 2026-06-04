# Decisions: Snappet Mobile (iOS)

Reverse-chronological. Each entry: the decision, why, and what it rules out. These are the
non-obvious choices already baked into the v0.1 code — written down so future prompts don't re-litigate
or accidentally reverse them.

## [2026-06-04] Split Expenses — receipt parser fixes + total/discount validation

**Decision**: From a deep review of the receipt PR, fix two parser bugs and add an advisory
**validation** pass that reconciles the captured items against the receipt's printed totals.

- **Bug 1 — tax mis-detection.** `ReceiptParser` set `tax = value` on *every* line containing "TAX",
  so the **last** one won — on the real Costco receipt that's `FSA TAX = 1.64`, not `TOTAL TAX 14.01`.
  Fix: tax now comes from the authoritative `TOTAL TAX` line (a bare `TAX` line is a fallback), and
  per-rate `%` component lines and `FSA` lines are ignored; the grand-total scan also excludes `FSA`.
- **Bug 2 — leading-minus discounts dropped.** `money()` only handled a trailing minus (`4.00-`); a
  `-4.00` token failed the digit check and vanished. It now strips a leading **or** trailing `-`.
- **Parser now also reads** `subtotal` and `itemCount` ("Items Sold: 51", handled before the money
  guard since it's a bare integer) so validation has more to check against.
- **`ReceiptValidation`** (pure, both platforms, unit-tested): builds a `Report` of independent checks
  — items − discount + tax = total (the headline; `FAIL` on mismatch with the off-by amount),
  subtotal match, tax-vs-detected, item-count, unassigned remainder, negative share. Surfaced as a
  `ReceiptValidationBanner` (Balanced / Needs review / Doesn't add up) in `NewReceiptSheet` that
  expands to the checklist; it **never blocks saving**. The detected totals are held in sheet state
  from the last scan/paste — **not persisted** (no schema change this cut), so validation runs at
  capture time where it matters; persisting a stored mismatch flag is a follow-up.

**Why**: the split is only as trustworthy as the OCR, so the app should *show its work* and flag a
bad read instead of silently producing a wrong per-person total. Keeping validation pure makes the
reconciliation logic testable without a device. Scoped per the request to **bug-fixes + validation
first** (Warehouse/Grocery profile only); typed receipts (restaurant/gas/pharmacy auto-detect) remain
a planned follow-up — see `docs/wireframes/receipt-types-validation.svg`. **Rules out**: blocking save
on a mismatch (advisory only); a new persisted column this cut; trusting the last TAX line.
**Verified**: pure logic unit-tested off-device on both platforms (`ReceiptParserTests`/`Test`,
`ReceiptValidationTests`/`Test`). UI banners stay device-unverified per the repo's build rule.

## [2026-06-04] Split Expenses — Android receipt parity + on-device camera OCR (both platforms)

**Decision**: Mirror the iOS itemized-receipt feature to Android and add **on-device camera OCR** to
both platforms so a receipt can be captured by photo, not only pasted.

- **Android mirror (Kotlin/Compose, Room).** `ExpenseRecord` gains additive, defaulted columns
  `itemsRaw` / `taxAmount` / `discountAmount`; the DB version bumps 2→3 and rides the existing
  `fallbackToDestructiveMigration` (on-device-only data, no hand-written migration). Items persist as
  a control-character-delimited `itemsRaw` string (RS/US/GS) — the same "raw string, no TypeConverter"
  approach already used for `participantsRaw`. `ReceiptSplit.kt` and `ReceiptParser.kt` are 1:1 ports
  of the Swift logic (same largest-remainder reconciliation, same parser heuristics) and get JVM unit
  tests under `src/test` (`ReceiptSplitTest`, `ReceiptParserTest`, `SettleUpReceiptTest`). UI:
  `NewReceiptSheet.kt` (items + per-item assignee FilterChips + tax/discount + live `ReceiptSummary`),
  `ReceiptDetail.kt` (read-only breakdown), wired into `ExpenseRoot.GroupDetail` with a "New receipt"
  menu item and receipt rows that open the detail.
- **Camera OCR.** iOS: `ReceiptDocumentScanner` (VisionKit `VNDocumentCameraViewController`) +
  `ReceiptScanner` (Vision `VNRecognizeTextRequest`, **synchronous** so no `CGImage` Sendable-crossing,
  mirroring `MediaPicker`'s direct-callback coordinator); gated on `isSupported` (hidden on the
  simulator) and presented in a `fullScreenCover` whose binding drives dismissal. Android: `ReceiptScan.kt`
  captures via `ActivityResultContracts.TakePicture()` through a `FileProvider` temp file (so **no
  CAMERA permission** is needed) and recognizes with **ML Kit** `text-recognition` (one new dependency).
  On both platforms the recognized text flows straight into the already-tested `ReceiptParser` — the OCR
  layer stays a thin, untested platform edge; all the brittle "what's an item / tax / discount" logic is
  pure and unit-tested.

**Why**: keeping the algorithm identical and pure on both platforms means the hard part is tested once
per language and the camera/Vision/ML-Kit code is a trivial pixels→text adapter. Using ACTION_IMAGE_CAPTURE
+ FileProvider on Android avoids a runtime camera-permission flow; using a synchronous Vision call on iOS
sidesteps Swift 6 `Sendable` friction. **Rules out**: a Room TypeConverter / JSON dependency for items
(control-char string matches the repo); a hand-written Room migration (destructive fallback is the repo's
norm for on-device data); CameraX / a bundled cropping UI on Android; bridging ML Kit's `Task` with an
extra coroutines-play-services dep (used `suspendCancellableCoroutine` instead). **Verified**: pure
logic unit-tested off-device on both platforms (iOS XCTest, Android JVM `src/test`). All SwiftUI/Compose
surfaces and the camera/Vision/ML-Kit paths stay **device-unverified** per the repo's macOS+Xcode /
Android-SDK build rule (authored on Linux/cloud) — they need a `xcodebuild test` and a Gradle
`testDebugUnitTest` + on-device run to confirm.

## [2026-06-04] Split Expenses — itemized receipts with per-item assignment + proportional tax/discount

**Decision**: Add an itemized **receipt** path to Split Expenses so a real shopping receipt (e.g. a
51-line Costco run) can be entered once and split *per item* among different people — not just one
even split per expense (user report: "put this kind of receipt and help me split stuff for multiple
people … show total, tax, discounts and per-person split"). Implemented without a new `@Model`:
`ExpenseRecord` gains three additive, defaulted fields — `items: [ReceiptItem]`, `taxAmount`,
`discountAmount` — so the SwiftData migration stays lightweight and one record type still drives all
of even-split / settlement / receipt. A record is a receipt iff `items` is non-empty.

- **`ReceiptItem`** (a `Codable` value type persisted as a SwiftData composite attribute) carries a
  name, price, and the `assignees` who share that line equally.
- **`ReceiptSplit`** (pure, device-free, in the app target so it's `@testable`) computes the
  breakdown: each item is split among its assignees, tax is allocated proportional to each person's
  pre-tax subtotal, discount is credited the same way, and **every column is reconciled to whole cents
  with a largest-remainder pass** so the per-person totals sum *exactly* to the grand total. That exact
  closure is what lets `SettleUp.balances` treat a receipt as "payer credited the grand total, each
  sharer debited their slice" and still net the group to zero — no penny drift in the balances.
- **`ReceiptParser`** (also pure/tested) turns pasted or Live-Text receipt text into items + detected
  tax/discount/total: it strips leading item-codes and trailing tax-flag letters (`28.99 E`,
  `4.00-A`), routes trailing-minus rows to the discount, and skips SUBTOTAL/TAX/TOTAL/payment rows.
  This is the "put this kind of receipt" affordance — paste once, then just tap each line to choose who
  shares it (new items default to everyone).
- **UX**: `NewReceiptSheet` (entry, with a live `ReceiptSummaryView` showing subtotal/discount/tax/
  total + per-person split) and `ReceiptDetailView` (read-only breakdown + item list, Edit reopens the
  sheet). `ExpenseGroupView` gets an "Add Receipt" action; receipt rows show a doc glyph + item/tax/
  discount summary and tap through to the detail (even-split rows still tap-to-edit).

**Why**: receipts are inherently uneven (one person's beer, shared groceries) and carry tax + savings
that must follow the items, not be split flat. Keeping the math pure + penny-exact makes it unit-
testable (`ReceiptSplitTests`, `ReceiptParserTests`, `SettleUpReceiptTests`) and keeps the existing
balance/settle-up pipeline unchanged. Reusing `ExpenseRecord` (vs. a new `@Model`) keeps per-group
`#Predicate` fetches and the balance loop single-source. **Rules out**: a separate `Receipt` @Model +
relationship; storing precomputed per-person `shares` (derive from items so there's one source of
truth); splitting tax/discount evenly regardless of who bought what; on-device Vision OCR for v1 (the
paste/Live-Text text path is device-free and testable — camera OCR is a natural follow-up). **Verified**:
pure logic unit-tested off-device (`swift`-level XCTest); the SwiftUI sheets/detail stay
**device-unverified** per the repo's macOS/Xcode-only build rule (authored on Linux/cloud).

## [2026-06-03] BLE band connection — auto-detect already-connected bands + remember the last one

**Decision**: Make Bluetooth heart-rate-band connection automatic instead of a manual "open the picker,
scan, tap the band every time" flow (user report: "it does not auto-detect a Bluetooth-connected fitness
band; I had to manually do it"). Three changes, all routed through the existing `MetricsSource`/coordinator
seam so the player / Live Activity / overlay are untouched:

- **Auto-detect the already-connected band.** `BLEHeartRateMetricsSource` now calls
  `central.retrieveConnectedPeripherals(withServices: [0x180D])` on power-on / picker-open, not just
  `scanForPeripherals`. A band paired in iOS Settings (Polar/Wahoo/Garmin) is *connected but not
  advertising*, so a plain scan never saw it — this is the root cause of "wasn't auto-detected". Those
  bands now appear instantly, flagged `isSystemConnected`, and merge with scanned advertisers
  (de-duplicated by identifier).
- **Remember the last-used band.** New `BandMemory` (UserDefaults, on-device) persists the chosen
  band's `CBPeripheral.identifier` + name. On the next launch the coordinator's init calls
  `autoConnectIfRemembered()` — which *only* spins up the central when a band is already remembered (so
  the Bluetooth permission was already granted and we never prompt at launch for a first-time user) — and
  reconnects it silently; the radio scan stops on connect to save battery. The source-selection default
  (`resolve`) now treats a *remembered* band as a known band, so a returning band-only user lands on BLE
  with zero taps.
- **Honest, actionable picker UI.** The picker shows a "Saved · reconnects automatically" tag, lists
  system-connected bands, supports swipe-to-Forget, and — when Bluetooth is off / unauthorized
  (`BluetoothAvailability`) — shows a message + a Settings jump instead of an endless "Scanning…" spinner.

**Why**: the manual re-pick was the single biggest friction in the live-workout flow; the fix is pure
CoreBluetooth ergonomics (retrieve-connected + a remembered identifier) with no new transport, no cloud,
and no new HealthKit path.

**Rules out**: a vendor cloud API (Fitbit/Google still ruled out, 2026-06-01); creating the central at
launch for *all* users (would prompt for Bluetooth before any value is shown — gated on a remembered band
instead); a SwiftData store for the band (a single identifier is a UserDefaults-sized fact).

**Verified**: extended the pure XCTest suite (`BLEBandAutoDetectTests`) — merge/dedup, the remembered-row
synthesis, the auto-connect rule (remembered → single system-connected → nil), and a `BandMemory`
persist/forget round-trip over an isolated suite. **Now also verified on device (2026-06-03, iPhone 13
Pro Max + a Google Fitbit Air, which — unlike most Fitbits — exposes the standard `0x180D`/`0x2A37` HR
profile):** auto-detect with no manual scan, auto-connect + real live HR stream, cold-launch "Saved ·
reconnects automatically" zero-tap reconnect, and the Bluetooth-off empty state all confirmed.

**Follow-up fix (2026-06-03) — "Forget" must stick for a band iOS keeps connected on its own.** Device
testing surfaced a real bug: a band that stays connected to iOS at the system level (a Fitbit, kept alive
by its own app) was immediately re-grabbed by the "single system-connected band → just use it" rule right
after the user swiped **Forget**, and re-remembered on connect — so Forget never stuck. Fix: `BandMemory`
persists a **suppressed** band id; `forget` sets it (clearing remembered), `bandToAutoConnect` and the
remembered-band auto-path **exclude** it, and an explicit tap (`connect`) clears it (re-opt-in). Covered by
new `BLEBandAutoDetectTests` cases (suppressed lone band → nil; a different system band still auto-connects;
suppression survives relaunch; allow clears it) and re-verified on device.

## [2026-06-02] Kilter Board mini-app — bundled read-only catalog, not a runtime sync

**Decision**: Added a **Kilter Board** mini-app (iOS + Android) for browsing the Kilter climb catalog,
rendering a climb's holds, logging sends/projects, reviewing history, and — gated, Phase 2 — lighting
the physical board over BLE. Traces to [#32](https://github.com/harshal2802/snappet-mobile/issues/32).

**Concrete choices made:**
- **The catalog is bundled static reference data, never synced.** The Kilter database is fetched +
  trimmed at *dev time* by `tools/kilter/build_bundled_db.py` (wrapping `boardlib`) into a small
  `kilter.sqlite3` shipped as an app asset (`ios/App/Snappet/Resources/`, `android/.../assets/`), opened
  **read-only**. This keeps Snappet's on-device-only rule (#1) intact: no runtime network/sync/accounts.
  Refresh = re-run the tool, drop in the new asset, ship an app update. **Rules out** an in-app live sync.
- **Catalog stays out of SwiftData/Room.** It's read with raw SQLite (`import SQLite3` on iOS; a
  read-only `SQLiteDatabase` copied out of `assets/` on Android), so the persistence stores own *only*
  user data. User data = three models/entities (`KilterLogEntry`, `KilterSession`, `KilterFavorite`)
  added to `SnappetSchema.models` / `SnappetDatabase` (Room version bumped 1→2; destructive-migration).
- **Bundled subset, not the full ~100k climbs.** Default trim: the 800 most-climbed listed problems on
  Kilter Original + Homewall + all board geometry (~4.9 MB). Committed in *both* platform asset dirs
  (≈9.8 MB total). Open question #11.1 (full-vs-trim, possibly Git LFS) deferred to a product call;
  #11.2 (redistribution license) **must** be resolved before shipping.
- **BLE illumination is implemented but device-unverified.** The Aurora/Kilter wire format
  (`KilterProtocol`, framed ≤20-byte packets) and GATT UUIDs come from community reverse-engineering and
  are **not** confirmed on hardware — gated behind an explicit Connect tap, inert in Phase 1, and not to
  be reported as working until validated on a real board (device-only rule #6). Sessions auto-open on
  connect to group logged ascents in History.

## [2026-06-01] Live-workout studio next pass — rich watch UI, pause/resume, background/minimize, transitions, notification status

**Decision**: One coherent change set across the live-workout surfaces (the features are tightly
coupled through the `Shared/` wire types, so a single change rather than parallel branches):

- **Bidirectional pause/resume.** `LiveWorkoutMessage` gains `.pause`/`.resume` (either device can
  initiate; the receiver applies it *without echoing* to avoid ping-pong). `MetricsSource` gains
  `pause()`/`resume()` (default no-op so a stream-only BLE band needn't implement them); the
  Apple-Watch source pauses the on-wrist `HKWorkoutSession`, the coordinator tracks `isPaused`
  (reading the watch source for the watch path, a local flag for BLE). The watch manager treats a
  `.paused` `HKWorkoutSession` state as still-running (only ended/stopped clears the face).
- **Rich watch UI.** `WatchWorkoutView` becomes a two-page vertical-paging face: a zone-colored HR +
  elapsed + energy + avg-HR **Metrics** page and a Pause/Resume + End **Controls** page.
- **Background / navigate-back.** The player gets a **Minimize** control (`onMinimize`) that drops the
  full-screen cover **without** ending the session; the session stays `isActive`, the watch keeps
  recording, and a new `LiveWorkoutBanner` pinned to the WorkoutTracker home shows live metrics +
  zooms back into the player. No SwiftData schema change (reuses `isActive`).
- **Notification status.** The Live Activity (Lock Screen + Dynamic Island) is the persistent
  notification-area status; it now renders a **Paused** badge (freezing the timer) + zone-colored HR.
  A new `WorkoutNotifications` service **schedules** a "rest complete" local notification when rest
  *starts* (a foreground `Task.sleep` is suspended in the background), cancelled on skip/pause/finish.
- **Transitions.** A central `Motion`/`AnyTransition` vocabulary (`Features/Shell/Transitions.swift`):
  iOS 18 `.zoom` for App Library card→module and banner→player, a section-swap for the workout
  segmented control, a cross-fade-and-slide for the player's exercise↔rest↔done phases, and a
  bottom slide for the banner.
- **`HeartRateZone` moved to `Shared/`** so the phone overlay, watch face, and Live Activity render
  the same bpm→zone color/label from one source of truth (no logic change).

**Why**: pause + background-continue + a way back in are the table-stakes gaps for a real workout
session; routing all of it through the existing `Shared/` wire types + the `MetricsSource`/coordinator
seam keeps the watch/phone/widget from drifting and adds no new HealthKit path.

**Rules out**: a SwiftData pause-interval ledger (the displayed timer freezes via a captured value;
"total" stays wall-clock and is documented); per-feature parallel branches (they'd conflict on the
shared wire/UI files); a bespoke push-notification stack (local `UNUserNotifications` only, on-device).

**Verified**: extended the pure XCTest suites — `LiveWorkoutTests` (pause/resume message round-trip,
source + coordinator pause state), `LiveActivityTests` (paused snapshot push + `ContentState`),
`WorkoutNotificationsTests` (rest-complete copy). **Build/sim run is device-pending**: this change was
authored in a Linux environment with no Xcode toolchain, so it has **not** been compiled or run on a
simulator — `xcodebuild test` on the iOS 18 sim + a paired-watch device pass is owed at the merge gate.

## [2026-06-01] Knowledge graph extended for the Live Workout Studio initiative — per-node screenshots + embedded walkthrough video

**Decision**: Updated the interactive knowledge graph (`docs/knowledge-graph/`, branch
`feat/graph-studio-update`) to cover the just-merged **Live Workout Capture + Video Studio** initiative
(A1–B5), and added two new presentation affordances to the detail panel.

**Concrete choices made:**
- **`data.js` nodes (16 added, 1 retired, several updated)**. Added the pluggable live-metrics layer
  (`metricssource`, `livemetricscoordinator`, `applewatchsource`, `blesource`) and the studio services
  (`sessionmediaservice`, `videostudio`, `medialibraryservice`); the shared Live Activity contract node
  `workoutactivityattributes`; the new `@Model`s `model-sessionmedia` + `model-clipedit`; the new sheets
  `wt-hr-source-picker`, `wt-clip-editor`, `wt-highlight`; the OS-framework nodes `ext-corebluetooth` +
  `ext-watchconnectivity`; and an **overview node `live-workout-studio`** (type `section`) that carries the
  walkthrough video and `contains`/`feeds` the key new nodes so it's discoverable. **Retired** the stale
  `liveworkoutservice` node (the file `LiveWorkoutService.swift` was renamed in A3 to
  `LiveMetricsCoordinator.swift` + `AppleWatchMetricsSource.swift`) — its edges re-pointed to
  `livemetricscoordinator`. **Updated** `sharesheet` (B5 generalized it → `Features/Shell/ShareSheet.swift`),
  `wt-player`/`wt-session-detail`/`wt-settings` descs (A4 overlay / B2 summary / A3 picker entry), and
  `model-workout` (B2 `hrSeries`). Wired the full live + studio edge flows with the existing edge types
  (`uses`/`streams`/`persists`/`feeds`/`present`/`contains`). The link-id integrity check passes (every edge
  source/target is a defined node id; no orphans, no duplicate node ids) — 109 nodes total.
- **Per-node screenshots**. Added an optional `shot` field; `renderDetail(n)` injects an `<img class="shot">`
  under the head (safe when absent), styled in `styles.css` (full panel width, rounded, bordered, `max-height`
  + `object-fit: contain` so tall phone shots fit). Curated 17 shots: the 9 existing suite screens
  (`01-home`…`09-budget`) + 8 NEW live-workout frames copied from `/tmp/studio-walkthrough-frames/` into
  `docs/screenshots/` with semantic names (`workout-dashboard`, `workout-routines`, `routine-detail`,
  `live-player`, `workout-history`, `workout-summary`, `workout-settings`, `hr-source-picker`). The
  **ClipEditor / SessionHighlight** screens are **device-only** (no simulator video) → their `shot` is left
  unset; their detail still shows desc + connections.
- **Embedded walkthrough video**. Added an optional `video` field rendered as a `<video class="shot-video"
  controls preload="metadata">` in `renderDetail`, attached to the `live-workout-studio` overview node
  (`docs/live-workout-studio-walkthrough.mp4`). Added a "▶ Walkthrough video" affordance in `index.html`'s
  header (an `<a class="btn">` to the relative path, offline-friendly). The root `README.md` gained a
  **"Walkthrough video"** subsection (HTML5 `<video>` off the GitHub **raw** URL + a relative-link fallback)
  and the 8 new live-workout screens in the Screens grid; the graph `README.md` "How it was built" note now
  cites the initiative + the `shot`/`video` additions.
- **Stays static/offline**: no build step. **Verified**: braces balanced in `data.js` (310/310); the
  `renderDetail` template-literal injection follows the existing `${cond ? \`…\` : ""}` pattern; every
  `shot`/`video` path resolves to an existing file (17 PNGs + the mp4); link-id integrity + no-duplicate-id
  checks pass. (`node --check` could not be run in this sandbox — Node execution is blocked — so syntax was
  confirmed structurally: balanced delimiters, the exact existing node/edge object shape, and a grep-based
  source/target-vs-node-id audit.) Only the renamed PNG copies are committed; the `/tmp` frames are not.

## [2026-06-01] Live Workout Studio walkthrough — chronological screenshot UI test + a test-only HR demo seed

**Decision**: Added a demo/QA asset (branch `feat/live-workout-walkthrough-video`, prompt
`pdd/prompts/features/live-workout-studio/WALKTHROUGH.md`) that walks the whole Live Workout Studio
initiative (A1–B5) in story order and captures ordered screenshots for a video walkthrough. The headline
screen — the **B2 enriched summary (HR chart + avg/max/min + time-in-zone)** — only renders when a session
has a non-empty `hrSeries`, which the simulator never produces (no live HR source). So a **test-only demo
seed** plants the data that makes it render.

**Concrete, non-obvious choices made:**
- **`StudioDemoSeed` lives behind a new launch arg `-uiTestSeedStudioDemo`** (`Features/WorkoutTracker/
  StudioDemoSeed.swift`), a **sibling of `-uiTestFreshStore`** that it **implies** — `SnappetApp.init()`
  builds the in-memory container for it (determinism) and calls `seedIfRequested(into:)` once, before any
  UI appears. The guard returns immediately without the arg → **ZERO production impact** (a normal launch
  hits neither arg). The ONLY app-target edit is that one `init()` branch; everything else is test code +
  the seed type in the feature folder. Idempotent (keyed on a fixed `routineID`).
- **The seed is DATA ONLY (no Photos)**: it inserts one **completed** `WorkoutSession` (three logged
  exercises with completed sets) carrying a **deterministic synthetic `hrSeries`** — a warm-up ramp → five
  sine-driven work/recovery oscillations → cool-down, ~120–175 bpm over ~30 min, one `HRPoint` every 3 s,
  **no randomness** so the chart/stats are pixel-identical every run. This is enough for the B2 HR section
  (chart + avg 146 / max 172 / min 120 + a Z2–Z5 time-in-zone bar) to RENDER on the sim. Tagged media /
  clip editor / highlight reel still need real video and stay device-only (the seed doesn't fake them).
- **Walkthrough navigation reuses the suite's UI-testable conventions** (segmented-control + Button rows;
  `WorkoutWalkthroughTests` pattern: `snap("NN-name")` via `XCTAttachment(screenshot:)`, `.keepAlways`).
  The **History → session-detail** row is the suite's one value-based `NavigationLink` (decisions.md
  2026-05-31) — XCUITest CAN activate it here (the prior limitation was a plain `Button` not firing, not
  the NavigationLink), so the test opens the *seeded* session through it with identifier/label/first-row
  fallbacks, asserting the B2 `hrChart` / "Heart rate" section then snaps it.
- **The A3 HR-source-picker entry is a `.buttonStyle(.plain)` row**: a plain `.tap()` on its identifier
  didn't always present the sheet, so `openHRSourcePicker()` retries via the row label then a
  normalized-coordinate tap — robust, never flakes. Confirmed the sheet (Apple Watch row + "Scanning for
  bands…") then renders.
- **The frames are throwaway** (exported to `/tmp/studio-walkthrough-frames/frame-NNN.png` via
  `xcresulttool export attachments` + the manifest's `suggestedHumanReadableName`) and are **NOT committed**
  — only the test + seed + this note + the WALKTHROUGH prompt are.

**Verified (this environment, Xcode/SDK 26.5, iPhone 17 Pro iOS 26.4 sim)**: `xcodegen generate`; the
`Snappet` scheme TEST BUILD SUCCEEDED (app + watch + widgets + both test targets).
`LiveWorkoutStudioWalkthroughTests` → **PASS** (1/1), capturing 12 ordered frames — suite home, app library,
workout dashboard, routines, routine detail (Start bar), the player (A2 overall-timer header + A4
no-source overlay), after-finish dashboard, History (the just-finished session + the seeded Studio Demo),
the **B2 HR summary** (chart + 146/172/120 + zone bar), the B1 media section + disabled B4 "Generate
highlight", Settings, and the A3 HR-source picker sheet. All PNGs uniform **1206 × 2622** (single sim) →
stitchable. The existing **`WorkoutWalkthroughTests` stays green** (62 s, 1/1). `HighlightEngine` source
untouched (no platform import added).
**Rendered vs skipped**: every planned step rendered EXCEPT `07-rest-screen` — the driven starter routine
reached **Finish** without the player surfacing a rest-countdown screen in the snapshot window (rest is the
prompt's optional "if reached" step), so it's gracefully absent rather than a fake. Device-only surfaces
(a real bpm in the overlay, media thumbnails, the clip editor, an actual reel) show their honest simulator
state (no-source / empty / disabled), not staged data — the same honesty bar as A1–B5.

## [2026-06-01] B5 — share + save generated videos to Photos (the video-studio finale)

**Decision.** Implemented prompt B5 (`pdd/prompts/features/live-workout-studio/B5-share-and-save.md`,
branch `feat/live-workout-share-save`). Every generated/edited video — the **B3 edited clip** and the
**B4 highlight reel** — can now be **shared** (system share sheet) or **saved to the Photos library**, all
on-device (the user's "all the videos generated could be sharable or downloadable to local/Photos",
RESEARCH §3.6). This is reuse + wiring on top of B3/B4; **no engine change** (`git diff ios/HighlightEngine`
empty, grep-clean of platform imports).

**Concrete, non-obvious choices made:**
- **`Services/MediaLibraryService.swift`** (stateless `Sendable`): `saveVideoToPhotos(_ url:) async throws`
  requests **add-only** authorization (`PHPhotoLibrary.requestAuthorization(for: .addOnly)`) — the
  **narrowest** grant that lets the app write a new asset without read access to the whole library, and
  deliberately **distinct** from the **read-write** `PhotoLibraryService` uses for B1 discovery. The save is
  the async `PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.forAsset().addResource(with:
  .video, fileURL: url, options: nil) }` overload — **no continuation needed** (the async API already bridges
  the callback, unlike B1's `PHImageManager`/A1's WCSession callbacks). Typed `SaveError: LocalizedError`
  (`.denied` routes the user to Settings; `.failed(msg)` wraps a change-block failure). `.limited` is treated
  as savable (add-only `.limited` can still add).
- **Generalized `ShareSheet`** — moved out of `Features/Reel/ReelView.swift` (where it was top-level but
  conceptually private to the reel app) into **`Features/Shell/ShareSheet.swift`**, so the flagship reel app
  AND the WorkoutTracker studio (B3 editor + B4 reel) share **one** `UIActivityViewController` wrapper. No
  second bridge written (the spec's "don't duplicate" constraint). The flagship's call site is unchanged
  (same type name, same target).
- **Pure `ExportShareState`** (`Features/WorkoutTracker/ExportShareState.swift`): an `Equatable` value-type
  state machine (`idle → exporting → exported(URL) → saving(URL) → saved(URL)`, plus `failed(String)`) with a
  reducer, so the transitions, the **carried export URL**, and the `isBusy`/`exportedURL` accessors are
  **unit-tested in `SnappetTests` with no AVFoundation/PhotoKit/UIKit** (9 cases) — the device-only
  export/save/share I/O is not, but the state logic that drives both producers' UI is (the same "isolate the
  pure logic" discipline as `ClipEditGeometry`/`WorkoutHRStats`). The rendered file `URL` is carried through
  `.exported`/`.saving`/`.saved` so **share + save reuse the single render** (export once, then share and/or
  save that same file). `beginningSave()`/`saveSucceeded()` are guarded to no-op without a prior export.
- **Two thin wire-ins, I/O through the services:**
  - **B3 clip editor** — `ClipEditorViewModel.export()` snapshots the `@Model` into `EditPlan` on the
    `@MainActor` and calls `VideoStudio.export` (the same composition the preview already uses); `saveToPhotos()`
    calls `MediaLibraryService`. A new "Export" `ControlCard` in `ClipEditorView`: Export → Share + Save to
    Photos with progress + a `saved` checkmark. **A subsequent edit invalidates the export** — `commit()`
    resets `exportState` to `.idle` (unless busy) since the prior render no longer matches the edit.
  - **B4 highlight** — `SessionHighlightViewModel` now **keeps `lastPlan`** from `generate()` (the VM already
    built a `ReelPlan` to preview) so `export()` re-renders the **same** reel via `ReelExporter.export`
    (no reel-stitch reimplementation); `saveToPhotos()` calls `MediaLibraryService`. A new Export/Share/Save
    section in `SessionHighlightView`, gated on `canExport` (plan present + state `.ready`); re-generating
    resets the export.
- **Privacy.** `NSPhotoLibraryAddUsageDescription` is present in the app Info.plist (it predates B5, from the
  first working version) and **accurate** ("Snappet saves your finished highlight reel back to your library")
  — confirmed, not re-added. `PrivacyInfo.xcprivacy` stays accurate: saving to the user's **own** library is
  on-device, so **no** `NSPrivacyCollectedDataTypes` entry is added (Apple's "collected" = transmitted off
  device; nothing leaves). The existing manifest comment already covers "written back to the user's own
  library entirely ON-DEVICE".
- **No new `@Model`** → `SnappetSchema.models` unchanged.

**Verified (this environment, Xcode/SDK 26.5).** `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**. `SnappetWatch`
(watchOS 26.5 sim, Apple Watch Series 11) → **BUILD SUCCEEDED**. `SnappetTests` → **122/122 pass** (incl. the
9 new `ExportShareStateTests`: full idle→saved flow, URL carried through every post-export state, save
guarded without an export, `isBusy` gates, failure + re-export recovery, re-export supersedes a prior file).
`HighlightEngine` → **18/18**, source unchanged (`git diff ios/HighlightEngine` empty, grep-clean of platform
imports). `SnappetUITests/WorkoutWalkthroughTests` → **green** (the sim session has no media/video, so
"Generate highlight" stays disabled and no clip opens the editor — the share/save affordances never render in
the walkthrough, and the summary flow is unbroken).
**Device-pending (NOT verified by this build/tests).** The actual **Photos save** (the add-only auth prompt +
`performChanges` writing a `.video` asset into the user's library) and the **share-sheet round-trip** need a
**real rendered video on a device**: the sim has no Photos/video, so `VideoStudio`/`ReelExporter` resolve no
`AVAsset` and produce nothing to save — so neither producer reaches `.exported` in the sim. A clean build +
the pure state-machine tests prove the **service shape + the wiring + the state logic + Info.plist**, NOT a
verified Photos save or share (same honesty bar as A1–B4).

## [2026-06-01] B4 — engine-driven highlight generation (the WorkoutTracker ↔ HighlightEngine bridge)

**Decision.** Connect the set-logger to the flagship algorithm by feeding a finished session's data
into the **EXISTING** `HighlightEngine`, with no engine change. A new **pure** bridge —
`Features/WorkoutTracker/SessionHighlightInput.swift` (an `enum` of static mappers + a plain-value
`Clip` struct; **no SwiftData/AVFoundation/Photos**) — maps a `WorkoutSession` to an engine `Workout`:

- **HR**: `hrSeries` (`HRPoint`) → `[HRSample]`, **1:1** on the same `startedAt`-relative timeline (`t`/`bpm`).
- **Media**: each tagged `SessionMedia` → `MediaItem` (`id = localIdentifier`, `startOffset = offsetSec`
  clamped ≥ 0). A **video** → `.video` with `durationSec`; a video with no resolvable duration falls back
  to a small `defaultVideoDuration` (6 s) and, when even that is unavailable, is **skipped gracefully**
  (a windowless clip the engine can't use). A **photo** → `.photo` with duration `0` (Ken-Burns still,
  already handled by `ReelExporter`/`PhotoClipRenderer`).
- **Activity**: routine `SportTag` (stronger) → then the dominant `ExerciseCategory` → the engine's coarse
  `Activity`, defaulting to `.strength` (generic gym). Targets the engine's `Activity` (not
  `HKWorkoutActivityType`) so the engine stays platform-free — this is the **engine-Activity twin** of
  the live path's `WorkoutActivityMapping` (which maps *up* to HealthKit types).

**Generation + render (reuse, not reimplement).** `SessionHighlightViewModel` (`@MainActor @Observable`)
snapshots the `@Model`s into plain `[HRPoint]`/`[Clip]` on the `@MainActor`, runs the **existing**
`app.engine.selector.select(workout:config: .preset(for:))` → `[Highlight]`, then `app.reelPlan(…pinnedIds:)`
→ `ReelPlan`, then **reuses `ReelExporter.makeComposition`** to build an `AVPlayer` preview (the same
composition export uses — no reel-stitch reimplementation). The non-Sendable `@Model` never crosses into
the engine/exporter.

**Selected clips → `pinnedIds` (budget-exempt).** The user's selected **clip** ids become the planner's
pins (the 2026-05-30 pin decision). Because `ReelPlanner` pins by **highlight** id, the view model expands
each selected clip id into the highlight ids whose `mediaItemId` is that clip — so a hand-picked clip is
always kept, budget-exempt. The **pure bridge** (`pinnedIds(forSelected:)`) emits the selected clip ids
verbatim (the unit-tested contract); the clip→highlight expansion is app composition state in the VM.

**UI.** A **"Generate highlight"** button in `SessionDetailView`'s media section, **enabled only when the
session has a tagged video**, opens `SessionHighlightView` — a **sheet** owning its own `NavigationStack`
(modules must not nest one) with a clip-selection list (default = all videos), a **Generate** action, and
an inline `VideoPlayer` preview. B5 adds share/save.

**B3 `ClipEdit`s are NOT applied to the reel segments (deferred).** B4 generates from the **raw** tagged
clips; per-segment edit integration (applying a clip's trim/crop/overlays to its reel slot) is a B5/later
concern — it would require threading per-segment `EditPlan`s through a composition the engine-driven
`ReelExporter` doesn't currently take, and the gate "after B3" (export cost) is unmeasured. Recorded here
so it isn't mistaken for an oversight.

**No new `@Model`** (the inputs already exist: B2 `hrSeries`, B1 `SessionMedia`) → `SnappetSchema.models`
unchanged. `git diff ios/HighlightEngine` is empty — the engine is reused verbatim.

**Verified vs device-pending.** Verified: app + watch schemes build (iPhone 17 Pro / Apple Watch Series 11
sims, `-destination` only); `SnappetTests` green incl. the new `SessionHighlightInputTests` (HR 1:1, media
kind/offset/duration incl. default-when-nil + skip-when-windowless + photos, activity mapping, selection →
`pinnedIds`, and an end-to-end bridge→selector→planner pin-survival check); `HighlightEngine` 18/18 with an
**empty** `ios/HighlightEngine` diff; `WorkoutWalkthroughTests` green (the sim session has no media/HR, so
"Generate highlight" is disabled — it can't run, doesn't crash the summary). **Device-pending**: the actual
**rendered highlight reel** — the sim has no Photos/video, so `ReelExporter` has nothing real to stitch. A
clean build is **not** a verified rendered reel.

## [2026-06-01] B3 — non-destructive CapCut-style on-device clip editor (WorkoutTracker)

**Post-review fix (2026-06-01, same branch)**: review found the time-gated text overlay used a
`CABasicAnimation(opacity)` with `fillMode: .forwards`, which holds the overlay **visible after its
`endSec`** instead of hiding it. Replaced with a `CAKeyframeAnimation` over the whole clip
(`values [0,0,1,1,0,0]` at `keyTimes [0, s, s, e, e, 1]`, `beginTime = AVCoreAnimationBeginTimeAtZero`)
so a text overlay is visible **only** within `[startSec, endSec]` and disappears after. (Whole-clip text —
the common case — is unaffected: it skips the animation and stays at full opacity.) Review otherwise
confirmed the geometry is sound: the CALayer **Y-flip** is correct (`layerPoint`), the crop transform
order `preferred.concatenating(crop)` applies orientation then crop correctly, the `EditPlan` Sendable
snapshot is the right Swift-6 boundary, and the PHAsset→AVAsset continuation single-resumes
(`.highQualityFormat`). Re-verified: app + watch BUILD SUCCEEDED, SnappetTests 97/97, HighlightEngine
18/18, WorkoutWalkthroughTests green. The overlay-timing fix is device-pending visually (no video on the
sim) — the keyframe approach is the standard `AVVideoCompositionCoreAnimationTool` pattern.

**Decision**: Implemented prompt B3 (`pdd/prompts/features/live-workout-studio/B3-clip-editor.md`,
branch `feat/live-workout-clip-editor`). A tagged **video** in a session's `SessionDetailView` B1 gallery now
opens a **non-destructive, fully on-device clip editor** — the user's "individually adjust the split/crop,
text overlay and all the basic CapCut/edit features" (RESEARCH.md §3.5). Edit state is **data, not baked
pixels**; nothing renders until export, so editing is instant + reversible. Builds on the existing
`ReelExporter` AVFoundation stitch.

**Concrete, non-obvious choices made:**
- **Non-destructive `@Model ClipEdit`** (`Features/WorkoutTracker/ClipEdit.swift`), keyed to its source
  `SessionMedia` by `sessionMediaID: UUID` (a **foreign key**, NOT a `@Relationship` — the suite convention,
  matching `SessionMedia.sessionID`), with the PHAsset `localIdentifier` **denormalized** so `VideoStudio`
  resolves the source without a second fetch. Holds the edit list: `trimStart`/`trimEnd` (split = two
  `ClipEdit`s with adjacent trims + `splitOrder`); a normalized crop rect (`cropX/Y/Width/Height`) + an
  `OutputAspect` (9:16 / 1:1 / 16:9 / original); `speed` (0.25–4×); `textOverlays: [TextOverlay]` (an inline
  `Codable` composite — `string`, normalized-center `CGPoint`, `fontSize`, `colorHex`, `startSec`/`endSec` —
  like `WorkoutSession.exercises`/`hrSeries`, **not** a child `@Model`); `mutedOriginalAudio` + optional
  `musicTrackName`. **One central edit**: `ClipEdit.self` appended to the single `SnappetSchema.models` line
  (additive → SwiftData lightweight migration, same precedent as B1's `SessionMedia`).
- **All geometry/timing math isolated into `ClipEditGeometry`** (`Features/WorkoutTracker/`,
  Foundation+CoreGraphics only — value types, **no AVFoundation/SwiftUI**), so trim→`TimeWindow`
  (clamp to `[0, assetDuration]`, force `start<end`, collapse a degenerate/inverted range to a tiny min
  slice), speed→scaled output duration (`sourceDuration / clampedSpeed`), normalized crop-rect→
  `CGAffineTransform` (aspect-fill the cropped region into `renderSize`, sanitized so a degenerate rect can't
  NaN), normalized position→`CALayer` point (**y-flipped** to CALayer's bottom-left origin), output
  `renderSize` per aspect (canvas longer edge = source longer edge, rounded to **even** dims — H.264
  requires even W/H), and split→two **adjacent, non-overlapping** windows (`a.end == b.start`, both ≥
  minDuration) are **unit-tested in `SnappetTests` with no device/AVFoundation** (23 cases) — the same
  testability discipline that keeps `HighlightEngine` platform-free (grep-confirmed: the engine gained no
  platform import, `git diff` shows its source unchanged). The `renderSize` per aspect is the
  **mixed-orientation normalization** — a portrait + a landscape source both render into one canvas — which
  **closes the gap deferred since 2026-05-31** (Photo-Ken-Burns / video-only reels never unified orientation).
- **`VideoStudio` service** (`Services/VideoStudio.swift`, stateless `Sendable`): one
  `makeComposition(for: EditPlan) async throws -> sending (AVMutableComposition, AVVideoComposition?)` reused
  for **both** preview (wrap in `AVPlayer`) and export — mirroring how `ReelExporter` shares one composition
  (P3). Trim → a source `CMTimeRange`; speed → `scaleTimeRange` on the inserted video (and audio) range;
  crop/aspect/orientation → `AVMutableVideoComposition.renderSize` + a single
  `AVMutableVideoCompositionLayerInstruction.setTransform` that **concatenates the track's
  `preferredTransform` (orientation) with the crop transform**; text overlays → a `CALayer` tree
  (`CATextLayer`s, time-gated by an opacity `CABasicAnimation`) composited via
  `AVVideoCompositionCoreAnimationTool`. **Reuses `ReelExporter`'s PHAsset→`AVAsset` resolve + the
  `Box<T>: @unchecked Sendable` + async `export(to:as:)` patterns** rather than duplicating them
  (`isNetworkAccessAllowed = false` — on-device).
- **Swift-6 actor crossing**: a `ClipEdit` is a `@MainActor`-confined, non-Sendable SwiftData `@Model`, so it
  must NOT cross into `VideoStudio`'s nonisolated build path. Resolved by snapshotting it into a `Sendable`
  value `EditPlan` (a plain struct, `@MainActor init(_ ClipEdit)`) **on the caller's actor** — the same
  "engine/service takes a plain value, not the model" discipline as `ReelExporter` taking a `ReelPlan`. The
  freshly-built composition crosses back with `sending`.
- **Editor UI** (`ClipEditorView.swift`) is a **sheet** (`.sheet(item: $editingClip)` from
  `SessionDetailView`) so it owns its own `NavigationStack` — **NOT** nested in the module (which rides the
  App Library's stack). Inline `VideoPlayer` over the live composition + control cards: trim sliders +
  Split, an `OutputAspect` segmented picker + a centered zoom-crop slider, a speed slider + 0.5/1/2× presets,
  a text-overlay list (add/edit/remove via a sub-sheet editing string/size/position/color), and a mute
  toggle. **All logic in `ClipEditorViewModel`** (`@MainActor @Observable`): owns the `ClipEdit`, rebuilds
  the `AVPlayer` preview off `VideoStudio` after every edit (with a `buildToken` so a newer edit supersedes
  an in-flight build), and persists; the view is thin (conventions.md). **Split** inserts a sibling
  `ClipEdit` (second half) via an `insert` closure and keeps the first half on the current edit.
  Only **videos** open the editor (photos aren't clip-editable); the editor reuses/creates the primary
  (lowest-`splitOrder`) `ClipEdit` for that source.

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**. `SnappetWatch`
(watchOS 26.5 sim) → **BUILD SUCCEEDED**. `SnappetTests` → **97/97 pass** (74 prior + 23 new
`ClipEditGeometry`: trim clamp/order/inverted/zero-asset, speed double/half/clamp, split adjacency +
exhaustiveness + too-short→nil, renderSize per aspect + even-dims + degenerate-source, full-frame &
center crop transforms + degenerate→finite, sanitized crop rect, y-flipped layer point + clamping).
`HighlightEngine` → **18/18**, source unchanged (grep-clean). `WorkoutWalkthroughTests` → **green** (the sim
has no Photos/video, so no clip opens the editor in the walkthrough — the gallery/summary flow is unbroken).
**Device-pending (NOT verified by this build/tests)**: the actual **rendered output** — the cropped,
text-overlaid, speed-ramped video, the live `AVPlayer` preview, and the mixed-orientation `renderSize`
normalizing a real portrait+landscape pair — needs **real video assets on a device** (the simulator has no
Photos/video, so `VideoStudio` resolves no `AVAsset` and the editor shows its no-source preview state). A
clean build + the pure-math unit tests prove the **model + composition-building + the geometry + the editor
UI shape**, NOT a verified rendered export (same honesty bar as A1–B2). **Export time + memory profiling**
of a multi-clip + overlay export is a device gate (PLAN "after B3").

## [2026-06-01] B2 — enriched post-workout summary (HR chart + band stats + media gallery) (WorkoutTracker)

**Decision**: Implemented prompt B2 (`pdd/prompts/features/live-workout-studio/B2-enriched-summary.md`,
branch `feat/live-workout-summary`). A finished WorkoutTracker session's `SessionDetailView` now shows,
above the B1 tagged-media gallery, a **live HR chart** + **band stats** (avg/max/min HR + time-in-zone),
so a completed workout presents the user's "detailed fitness band data along with tagged videos"
(RESEARCH.md §3.4). Consumes A1's live HR buffer + B1's gallery.

**Concrete, non-obvious choices made:**
- **Persist the HR series as an ADDITIVE Codable composite, not a new `@Model`** (`WorkoutModels.swift`):
  added `var hrSeries: [HRPoint] = []` to `WorkoutSession`, where `HRPoint { t: Double; bpm: Double }` is a
  small `Codable`/`Hashable`/`Sendable` value type stored inline like `exercises`. A default-`[]` additive
  property triggers SwiftData's **lightweight migration** with **`SnappetSchema.models` UNCHANGED** —
  exactly the **Journal `tags: [String] = []` precedent** (decisions.md 2026-05-31). No versioned schema
  plan, no migration stage. The HR bytes are tiny (1 Hz, `t`+`bpm` doubles) so an inline composite (always
  loaded with the session, like its sets) is right — no FK-keyed child rows needed here, unlike B1's
  `SessionMedia` (which references on-device Photos assets that must NOT enter the store).
- **Flush point: `finishWorkout(_:saved:)`, on a saved finish, BEFORE `stop()`** (`WorkoutTrackerModule.swift`):
  `session.hrSeries = WorkoutHRStats.points(from: app.liveWorkout.samples)` runs before
  `app.liveWorkout.stop()` (which stops both sources). The coordinator's `samples` are engine `HRSample`s
  **already rebased onto the `WorkoutSession.startedAt` timeline** by A1, so the flush is a straight
  field-for-field map (`HRSample.t/bpm → HRPoint.t/bpm`), isolated in `WorkoutHRStats.points(from:)` so
  it's unit-tested. Empty buffer (no live source — the sim, or a phone-only workout) → empty `hrSeries` →
  the summary's HR section hides cleanly. A **discard** keeps no series (the session is deleted).
- **Pure stats helper `WorkoutHRStats`** (`Features/WorkoutTracker/WorkoutHRStats.swift`): a value type
  with `make(from: [HRPoint], maxHR:) -> WorkoutHRStats?` computing avg/max/min + per-zone dwell seconds,
  plus the `HRSample → HRPoint` map. It lives in the app (not `HighlightEngine`) because time-in-zone
  reuses the app's `HeartRateZone` (which vends a SwiftUI `Color`), but its **logic is platform-free**, so
  it's unit-tested in `SnappetTests` with no device (mirrors keeping the engine platform-free; grep-confirms
  no platform import added to the engine, and `git diff` shows the engine source unchanged). Returns `nil`
  for an **empty** series (so the view hides the whole section); a **single-sample** series yields
  avg=max=min and **zero dwell** (one point has no following interval). Time-in-zone uses **left-edge
  attribution**: each sample owns the interval until the next, so dwell sums to the series span and the
  last sample contributes nothing — a deliberate, tested convention.
- **Reuse, don't reimplement**: the chart line feeds the points through
  `HighlightEngine.HeartRateSeries.make(...)` (resample→smooth, 5 s window) for a clean line rather than a
  jagged raw plot — the engine is **called**, never modified. Time-in-zone reuses `HeartRateZone.forBpm`
  (default max HR 190, the A4 fixed constant — no user HR profile yet; `maxHR` is a parameter so a future
  profile drops in with zero zone-math change). The zone bar/legend reuse `HeartRateZone.color`/`pillLabel`.
- **Thin view** (`SessionDetailView.swift`): a `HeartRateSummarySection` (`private struct`) rendered only
  when `WorkoutHRStats.make` is non-nil, composing a `HeartRateChart` + an avg/max/min row + a `ZoneBar`
  (each a small `private struct`); no HR math in the view. The B1 `SessionMediaSection` is unchanged and
  stays below. The chart/zone bar carry `accessibilityIdentifier`s (`hrChart`, `hrZoneBar`) for future
  assertions. Per-exercise HR overlay was **skipped** (the optional nice-to-have) — not needed for the
  core chart+stats+gallery and not cheap enough to justify here.
- **No new `@Model`** → `SnappetSchema.models` unchanged.

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**. `SnappetWatch`
(watchOS 26.5 sim) → **BUILD SUCCEEDED**. `SnappetTests` → **74/74 pass** (62 prior + 12 new
`WorkoutHRStats`: avg/max/min, order-independence, time-in-zone left-edge bucketing + custom-maxHR shift,
`orderedZoneSeconds` low→high, empty→nil, single-sample→zero-dwell, the `HRSample→HRPoint` map + empty +
round-trip). `HighlightEngine` → **18/18**, source unchanged (grep-clean, `git diff` empty).
`WorkoutWalkthroughTests` → **green** (the sim finishes with an empty `hrSeries`, so the HR section hides
and the gallery/stats absence doesn't break the flow).
**Device-pending (NOT verified by this build/tests)**: the chart's actual **visual** with a **real
live-HR series** — the smoothed bpm line, the avg/max/min over real data, and the time-in-zone bar
filling — needs a device with a live HR source (Apple Watch or BLE band) finishing a session, because the
simulator has no HR source so it persists an empty `hrSeries` and the chart hides. A clean sim build +
synthetic-data unit tests prove the **math + the shape**, NOT a verified live-HR chart (the same honesty
bar as A1–A4 / B1). Also device-pending: that the additive `hrSeries` migrates an existing on-device store
without data loss (lightweight migration is exercised only by the fresh-store sim run here).

## [2026-06-01] B1 — session media tagging (photos/videos shot during a workout) (WorkoutTracker)

**Decision**: Implemented prompt B1 (`pdd/prompts/features/live-workout-studio/B1-session-media-tagging.md`,
branch `feat/live-workout-session-media`). A WorkoutTracker session can now collect the photos/videos taken
during it — auto-discovered by capture-time window and/or added by hand — stored as session-scoped tags and
shown in `SessionDetailView`. This is the video-studio data foundation B2/B3/B4 consume (RESEARCH.md §3.4,
verdict GO).

**Concrete, non-obvious choices made:**
- **`SessionMedia` shape + FK-not-relationship** (`Features/WorkoutTracker/SessionMedia.swift`): `id`,
  `sessionID: UUID` (a `WorkoutSession.id` **foreign key**, NOT a SwiftData `@Relationship`),
  `localIdentifier` (PHAsset id), `kindRaw` (photo/video as a string), `offsetSec` (capture time relative to
  `startedAt`, **clamped ≥ 0** in `init`), `durationSec: Double?` (videos), `addedManually: Bool`,
  `createdAt`. The FK-not-relationship choice matches the rest of WorkoutTracker (`Routine`/`WorkoutSession`
  key on `UUID`) so the gallery loads with a clean per-session `#Predicate<SessionMedia> { $0.sessionID ==
  sid }` — the suite's per-parent query convention. The asset **bytes never enter the store**: a row holds
  only the `localIdentifier` + offset; Photos keeps the media (on-device only).
- **One central edit**: appended `SessionMedia.self` to the single `SnappetSchema.models` line in
  `Core/SnappetCore.swift` (additive, no migration).
- **±90 s pad reused from `PhotoLibraryService`**: `SessionMediaService.padSec = 90`, the same grace padding
  the flagship Reels app uses for clock skew/drift between the recording device and the workout clock. (The
  TZ-normalization caveat flagged in `project.md` for the post-hoc path applies equally here — unconfirmed
  until measured on a device.)
- **Pure mapping isolated for testability**: `SessionMediaService` exposes static `window`/`isInWindow`/
  `offset`/`candidates(from:)` that take plain tuples — **no PhotoKit type crosses that boundary** — so the
  in-window predicate (incl. ±pad boundaries, inclusive), the clamped `creationDate → offset` math, and
  dedupe-by-`localIdentifier` are unit-tested in `SnappetTests/SessionMediaMappingTests.swift` (8 cases)
  with no device. (Mirrors keeping `HighlightEngine` platform-free; this lives in the app since it wraps
  PhotoKit, but its logic is device-free — grep-confirmed no platform import added to the engine.)
- **Auto-discovery trigger point**: `SessionDetailView`'s gallery section fires auto-discovery **once on
  first appear, silently** (only if full access is already granted — value-first, never prompts on appear),
  **plus** an explicit "Find media from this workout" button that *does* request access value-first. Manual
  add is the "Add photos/videos" PHPicker button (`addedManually = true`); remove is a long-press context
  menu. Re-running discovery is safe (deduped by `localIdentifier`).
- **`.limited`-access handling**: a `.limited` grant can't scan the library by time window, so
  `discover(...)` throws `.denied` unless **fully** `.authorized`; the UI routes `.limited` to the PHPicker
  (the suite-wide limited-access fallback). Manual picks bypass the window filter (the user chose them) but
  are still offset-aligned + deduped.
- **Thumbnails**: `PHImageManager` with `deliveryMode = .highQualityFormat` (a single final callback, so the
  `withCheckedContinuation` bridge resumes exactly once) and `isNetworkAccessAllowed = false` (on-device
  only). Missing assets (e.g. on the simulator) render a placeholder.

**Device-pending (NOT verified by this build/tests)**: live PHAsset auto-discovery surfacing real clips,
the `.limited`/`.authorized` permission prompts, and rendered thumbnails — the simulator has no Photos
library. Verified here: the `@Model` + service + UI + the pure mapping (app + watch sim build, 8 new
mapping tests + the 56 existing `SnappetTests`, `WorkoutWalkthroughTests`, `HighlightEngine` 18/18). A clean
build is **not** verified Photos discovery. Open gate (PLAN.md): on a device, does discovery surface clips
*during* an active session or only after the Camera app finalizes them? If real-time tagging fails →
in-app `AVCaptureSession` capture (B1b).

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

## 2026-06-03 — Kilter "Connect board" UX: timeout watchdog + name-based discovery (fix "stuck connecting")

**Decision**: `KilterBoardController` (iOS + Android mirror) gets three changes that together fix the
board getting wedged on "Connecting…". **(1) Discover by name, not service UUID.** Aurora-family
boards (Kilter/Tension/…) advertise a local name but generally do **not** put their primary service
UUID in the advertisement, so the old `scanForPeripherals(withServices:)` / `ScanFilter.setServiceUuid`
never produced a `didDiscover` and the scan ran forever. We now scan unfiltered and match in a pure,
unit-tested predicate `isLikelyBoard(name:advertisedServiceUUIDs:)` (name contains kilter/aurora/
tension/grasshopper/decoy/soill, or the advertised services contain our UUID). **(2) Timeout
watchdog.** CoreBluetooth's `connect(_:)` (and Android's `connectGatt`) never time out, so a missing,
asleep, or wrong-GATT board hung the UI silently. A 12 s watchdog (Swift `Task`/`Task.sleep`; Android
`Handler.postDelayed`) covers scan, connect, **and** service/characteristic discovery — on expiry it
tears down the half-open connection and moves to `.failed(message)`. **(3) Distinct states + escape
hatch.** Added `bluetoothOff` and `unauthorized` (was all folded into `unsupported`, which hid the
whole section) and a `failed(String)` message; added `cancel()` so an in-flight attempt always has a
Cancel affordance. The detail view now shows a spinner + Cancel while busy, a message + "Try again" on
failure, an "Open Settings" deep link when permission is denied, and a Bluetooth-off note —
`unsupported` (no radio / simulator) still hides the section. **Why**: the radio API gives no
completion guarantee, so the controller must own its own deadlines and the UI must always offer a way
out. Keeping discovery a pure function lets it run in `SnappetTests` (`KilterBoardMatchTests`) with no
radio. **Rules out**: filtering the scan by service UUID; a single `unsupported` catch-all; trapping
the user with no cancel. **Verified**: pure matcher unit-tested (iOS `KilterBoardMatchTests`). The
live BLE path stays **device-unverified** per the repo's device-only rule — `xcodebuild`/Gradle build
+ on-board validation deferred to a macOS/Android run (this change was authored on Linux/cloud).
