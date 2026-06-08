# Decisions: Snappet Mobile (iOS)

Reverse-chronological. Each entry: the decision, why, and what it rules out. These are the
non-obvious choices already baked into the v0.1 code — written down so future prompts don't re-litigate
or accidentally reverse them.

## [2026-06-07] Kilter board session lifecycle — persisted store is the single source of truth

**Decision**: The active Kilter session is no longer in-memory-only. `KilterSessionManager` is **owned
by `AppModel`** (not `@State` on `KilterRootView`) so it survives navigating out of the module, and it
**recovers** the open session (`endedAt == nil`) from SwiftData on appear/relaunch via the pure
`KilterSessionRecovery` planner. Recovery enforces a **single-open-session invariant** (adopt the
newest open, auto-close duplicates) and **auto-closes sessions abandoned > 6 h** (stamped at last
activity, never "now"). `end(sessionID:in:)` closes a session by id from any surface.
(`pdd/prompts/features/11-kilter-session-lifecycle.md`.)

**Why**: `KilterRootView` is a `navigationDestination`; SwiftUI destroyed/recreated it on pop, resetting
the `@State` manager to `current == nil` while the `KilterSession` row stayed open. That stranded the
session: the bar vanished, "End" became a no-op, post-reset logs got `sessionId: nil` (orphaned /
double-counted), and board-connect / re-start forked duplicate open sessions. An audit found 23 such
failure modes, nearly all downstream of this one defect.

**Also**: the session is **decoupled from the BLE link** — a board *disconnect* no longer ends the
session (a brief drop shouldn't kill an in-progress session); the board→session bridge moved from the
transient detail view to the root (stable). History surfaces live sessions (badge + running timer) with
swipe-to-End; History/Settings "Clear" skip the active session.

**HR-on-clips during the session**: `hrSeries` used to be flushed onto the session only at `end()`, so
clip HR overlays were empty until the session ended (the clip editor reads the *persisted* series via
`SessionHRSeries.forSession`, once, on open). Added `KilterSessionManager.syncLiveHR(in:)` — flushes the
cumulative live HR buffer onto the active session **without ending it** — called on opening the session
summary, after each log, before opening a clip, and before "Find my clips". Clips recorded mid-session
now overlay heart rate without ending the session first.

**Rules out**: tracking "active" purely in memory; ending via the in-memory `current` pointer; coupling
session lifetime to the board connection. **Deferred (low/device-only)**: Live-Activity `staleDate`,
live-summary stats throttle, tagging the cross-module activity log with the session id.

## [2026-06-07] Freeform/dynamic WorkoutTracker sessions + ad-hoc climbing (polymorphic SetKind)

**Decision**: Made WorkoutTracker sessions **grow-as-you-go** and able to log **ad-hoc (non-Kilter)
climbing** — gym bouldering / outdoor — which the user confirmed they do. (dynamic-sessions D3/D4/D5;
`pdd/prompts/features/dynamic-sessions/DESIGN.md`.)

- **Polymorphic set unit (D4).** `SetKind` (`repsWeight`/`duration`/`climbAttempt`) on
  `SessionExercise.kindRaw: String?` (nil ⇒ legacy reps/weight) + **optional** fields on `SetLog`
  (`durationSec`, `climbGradeLabel`, `climbStatusRaw`, `climbAttempts`). **Migration nuance (load-bearing):**
  `SetLog`/`SessionExercise` are nested **Codable composites**, not `@Model`s — SwiftData lightweight
  migration doesn't reach inside the encoded blob, so every added field is **`Optional`** (synthesized
  `Codable` decodes a missing optional key as nil; a non-optional key would throw on old data). The climb
  outcome **reuses `KilterAscentStatus`** (one climbing vocabulary across Kilter + WorkoutTracker +
  the recommender). Pure `SetMeasure` (summary/format/validate, e.g. "8 × 60 kg" / "0:45" /
  "V4 · Flash · 3 tries") + `SetMeasureTests` (12 cases). **Rejected** a `SetMeasure`
  enum-with-associated-values (bigger hand-written-`Codable` surface, no user-visible gain).
- **Freeform player (D3/D5) is a NEW, self-contained view, not a rewrite.** `FreeformPlayerView` (a
  list-based logbook) handles routineless sessions (`routineID == nil`): add exercises (Lifting via the
  existing `ExercisePickerView` · Climbing · Timed), per-exercise add set/attempt via a kind-adaptive
  `LogSetSheet`, swipe-delete, finish. **Why separate:** the guided `WorkoutPlayerView` is device-verified
  and tightly coupled to reps×weight + a fixed index walk; a logbook is the right shape for "add as you
  go" and avoids destabilizing it. **Quick Start** (`startFreeform()`) creates the empty session; the
  player cover branches on `routineID == nil`. `SessionDetailView.detailText` now renders climb/timed
  sets via `SetMeasure` (detected from the set's own fields → no call-site churn).

**Why**: closes the "I don't know my next climb / I want to add as I go" gap for non-board climbing and
ad-hoc lifting, reusing the existing model (no new `@Model`, additive-only) and finish/HR pipeline.

**Rules out / caveats**: **No build/sim/test run** — the authoring box has no Swift toolchain, so
`xcodebuild test` + a sim pass on a Mac are owed (only the graph integrity was checked: 162 nodes / 284
edges, no orphans/dups). Followups: distance/GPS (Shape ②) isn't a `SetKind` yet; ad-hoc Climbing/Timed
exercises use a fixed default name (inline rename later). Graph: added `wt-freeform-player` +
`wt-set-measure` nodes.
- **Freeform Live Activity (fixed in review).** `FreeformPlayerView` now pushes to the **Live Activity**
  (mirroring `WorkoutPlayerView`): live HR + the current exercise + the paused state, via `onChange` on
  `liveWorkout.latestHR`/`isPaused` and after each log/add. Previously it only seeded the activity once,
  so the Lock Screen showed a stale "Workout" label, blank HR, and a timer that kept running while
  paused. Only the per-set "Set N of M" line is intentionally omitted (a freeform logbook has no fixed
  target); the `startLiveActivity` seed also no longer emits a nonsensical "Set 1 of 0" for an empty
  freeform exercise.

## [2026-06-07] Kilter-driven session recommender — pick a session from your logs

**Decision**: Shipped the high-value remainder of the dynamic-sessions design (`pdd/prompts/features/
dynamic-sessions/DESIGN.md`, refreshed) as a **pure recommender + a Plan screen in the Kilter app**.
Re-baselined first: `main`'s `18-ios-kilter-rich-session` already gave climbing sessions live HR, per-climb
timing/attempts (so a board session is *already* the "dynamic climbing" the user asked for), media + a
highlight reel, and a rich summary — so the original Part B (project Kilter into WorkoutTracker history)
was **dropped** (redundant; would fight the 2026-06-02 "keep Kilter separate" call). What remained novel
was *using* the logs to suggest a session.

- **`KilterRecommender` (pure, Foundation-only)** — `[KilterClimbLog]` history + `[KilterListItem]`
  candidates → a goal-tagged `Plan` (Warm up / Send / Project). Detects the **working grade** = hardest
  rounded-difficulty bucket with ≥ `sendThreshold` (default 2) sends (else hardest single send, else nil
  cold-start); allocates `targetCount` ~⅓ warm-up / bulk sends / one project; bands warm-ups below, sends
  at, project above the working bucket; ranks by quality→ascents→easiest→uuid (**deterministic**);
  `preferUnsent` keeps already-sent climbs out of send/project goals. **Reuses** the existing
  `KilterClimbLog` value type (from `KilterSessionStats`) and catalog `KilterListItem` — no new `@Model`,
  no schema change, no migration.
- **`KilterPlanView` + `KilterPlanRoute`** — More-menu "Plan a session": reads `KilterLogEntry`s, queries
  the catalog for a window around the working grade, runs the recommender, shows grouped picks; **Start
  session** begins a manual `KilterSession` (reusing `KilterSessionManager` → live HR / Live Activity /
  media) and taps through each pick, with a live "logged this session" check.
- **Tests**: `KilterRecommenderTests` (14 cases — working-grade detection, allocation sum, banding by
  goal, prefer-unsent, higher-quality-wins, determinism, no-dup-across-goals, cold start, empty
  candidates, **candidate-window coverage, explicit-anchor band centre, deep warm-up fallback**).
  **Graph**: added `kilter-recommender` (pure) + `kilter-plan` (screen) nodes + edges
  (integrity re-checked: 162 nodes / 284 edges, no orphans/dups).
- **Recommender ↔ view coherence (fixed in review).** The band centre and the catalog-query window
  must share one `anchor`: `recommend` takes an explicit `anchor:` and the view fetches over
  `KilterRecommender.candidateWindow(anchor:)` (`w-4.5 … w+2.5`, fully bracketing the warm-up→project
  bands). Earlier the view fetched `anchor-3 … anchor+2`, leaving the `w-4` warm-up fallback unfetchable
  and letting two independent cold-start anchors (grade-scale median vs candidate median) disagree and
  silently drop a goal.

**Why**: it's the most on-brand piece — a deterministic pure function over data the app already keeps,
turning history into action — and the catalog/session machinery to act on it already exists.

**Rules out / honest caveat**: recommender lives in **Kilter**, not WorkoutTracker (follows main's
"Kilter is the climbing home"; the pure core is UI-agnostic so it's reversible). Remaining/ deferred:
freeform **lifting** Quick-Start sessions (A.1) and a polymorphic `SetKind` for **ad-hoc** non-catalog
climbing in WorkoutTracker (A.2, gated on a product call now that Kilter covers board climbing). **No
build/sim/test run**: the authoring box has no Swift toolchain, so `xcodebuild test` on a Mac is owed to
green the recommender tests + sim-verify `KilterPlanView` (only the graph integrity was checked here).

## [2026-06-06] Kilter Board — LED map by the user's BOARD SIZE + send led_color (real-board fix)

**Decision**: Resolve each lit hold's LED address from the `leds` table **for the user's chosen
`product_size`**, not an arbitrary one, and send the role's **`led_color`** (not `screen_color`) to the
board. Found on real hardware: the board connected and lit up (the #52 GATT/framing fix worked) but lit
the **wrong/shifted holds**.

- **Root cause**: `ledPositions` used `MIN(product_size_id)` for the layout — i.e. it always assumed
  one specific board size (for Kilter Original that's size 7, "12×14 Commercial", 527 LEDs). A layout
  exists in **many** physical sizes (Original: 7×10/8×12/12×12/12×14/16×12; Homewall: per-dimension ×
  LED-kit), and the **same hole has a different `leds.position` on each size**, so any other board lights
  the wrong LEDs. A taller assumed board (12×14) shifts every address → the user's "shifted/offset"
  symptom.
- **Fix**: `KilterCatalog.sizes(forLayout:)` lists a layout's `product_sizes`; `holds(for:sizeId:)`
  maps LEDs for the selected size (falling back to the layout's smallest when unset/invalid).
  `KilterHold` gains `ledColorHex` (`placement_roles.led_color`) used by the controller, keeping
  `colorHex` (`screen_color`) for the on-screen render — they differ for `start` (LED `00FF00` vs
  screen `00DD00`).
- **UX**: a persisted **Board size** preference (`kilter.productSizeId` AppStorage / SharedPreferences),
  picked in Settings (next to Board/Angle) and in the inline **"Wrong holds?"** control on the climb
  screen (size picker first — the likely cause — then the Standard/Legacy dialect). Changing it re-maps
  every LED and re-lights the current climb instantly. Seeded to the layout's default; reset when the
  layout changes.

**Why**: the board can't report its size and the LED address space is size-specific, so the app must
know the size — there's no auto-detect. **Rules out**: a single hardcoded size; a uniform position
offset (sizes differ in hole sets, not by a constant shift); per-climb size. **Verified**: off-device
unit/instrumented tests with a 2-size fixture prove `holds(sizeId:)` selects the right size's positions
and the board uses `led_color` (`KilterCatalogStoreTests` / `KilterCatalogStoreTest`). Lighting the
**correct** holds on the wall stays **device-pending** until re-tested on the real board with the size set.

## [2026-06-06] Kilter Board — ship both Aurora payload dialects (Standard/Legacy) with a user toggle

**Decision**: Support **both** Aurora illumination "API levels" and let the user choose, rather than
hardcoding level 3. The level is the *payload* dialect, set by the board's firmware generation; it is
**not advertised or negotiated**, so the app can't auto-detect it. A mismatch still **connects** fine
(same BLE link/UUIDs) but lights the **wrong holds/colors** — so the right UX is a cheap manual switch
exactly where the problem shows up.

- **Encoder** (`KilterProtocol`, both platforms): added `APILevel { v3, v2 }`. `messages(for:level:)`
  defaults to `.v3` (so the connect-fix tests and all existing callers are unchanged). `v3` = 3-byte
  holds, R3G3B2, markers 82/81/83/84; `v2` = 2-byte holds (byte0 = position low 8 bits; byte1 =
  R2G2B2 in bits 7–2 OR the high 2 position bits in bits 1–0), markers 78/77/79/80. `bodyChunk = 12`
  serves both (multiple of 2 and 3; framed ≤ 20 bytes either way). Color packers (`colorByte` v3 /
  `colorBitsV2`) are pure + unit-tested with exact byte vectors.
- **Controller**: holds `apiLevel` + remembers `lastHolds`; `setAPILevel(_:)` switches dialect and, if
  a climb is currently lit, **re-sends it immediately** so the wall updates live. No-op when unchanged,
  so it's safe to call on every settings sync.
- **UX (smooth path)**: default **Standard** — zero friction for the ~all boards that use it. Two ways
  to switch, both persisted (`kilter.apiLevel` AppStorage / SharedPreferences): a **Settings** picker,
  and — the key affordance — a quiet **"Wrong holds lighting up?"** link in the *connected* controls on
  the climb screen that reveals a Standard/Legacy switch and re-lights instantly. The shared controller
  is the single sink; the root view (iOS) / root + detail `LaunchedEffect` (Android) push the persisted
  value down, so a change anywhere takes effect everywhere without re-navigating.

**Why**: shipping both encoders + a one-tap switch is far better UX than guessing wrong and showing a
broken wall, and there's no reliable on-wire signal to auto-pick. **Rules out**: auto-detecting the
level (not possible over BLE); a level-negotiation handshake (Aurora doesn't expose one); per-board
persistence (one preference fits a user's single wall). **Verified**: pure encoder vectors for both
levels pass off-device on iOS + Android (`KilterProtocolTests` / `KilterProtocolTest`). The live
re-light + the switch UI stay **device-pending** per the repo's hardware rule.

## [2026-06-06] Kilter Board — fix BLE connect addressing + packet framing

**Decision**: Correct the Aurora/Kilter BLE protocol on both platforms to match the canonical
community reverse-engineering (`1-max-1/fake_kilter_board`). Two bugs, both of which the prior code
flagged as "device-unverified — verify against hardware":

- **Wrong GATT addressing (the connect bug).** The controllers discovered services/characteristics on
  the board's *advertised* service `4488B571-…` and looked for a `4488B572-…` write characteristic
  that doesn't exist. `4488B571` is only **advertised**; the writable endpoint is the **Nordic UART**
  GATT service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` + characteristic `6E400002-…`. With the wrong
  UUIDs the write characteristic was never found, the connection never reached `.connected`, and the
  discovery watchdog fired with *"Connected, but the board didn't respond. Try again."* — the reported
  symptom. Fix splits the constant into `advertisedServiceUUID` (scan/recognise + `retrieve­Connected­Peripherals`)
  vs `gattServiceUUID`/`writeUUID` (discover + write). `isLikelyBoard` keeps matching the advertised
  UUID/name, so that test is unchanged.
- **Malformed packet framing.** `wrap()` emitted `[0x01, len, cksum, <payload>, 0x02]`; the spec is
  `[0x01, len, cksum, 0x02, <payload>, 0x03]` (missing the `0x02` data marker; terminator must be
  `0x03`). Corrected, and `bodyChunk` drops `15 → 12` (4 holds × 3 bytes) so the framed packet is
  `6 wrapper + 1 marker + 12 = 19 ≤ 20` bytes. The hold encoding (uint16-LE position + R3G3B2 color)
  and markers 82/81/83/84 were already correct.

**Why**: these are the only things wrong on the connect path; the rest (scan-by-name, system-connected
adopt paths, timeout watchdog) is sound. **One axis deliberately left out of scope**: Aurora "API
level 2" (older boards — 2-byte holds / R2G2B2 / markers 77–80). The write **UUIDs do not vary by
board** across the Aurora family (Kilter/Tension/Grasshopper/Decoy/So iLL all share the Nordic UART
endpoint), so no multi-UUID handling is needed; only the *payload* API level differs, and level 3 is
now the common case. **Rules out**: per-board UUID tables; API-level-2 fallback (a follow-up if an
older board surfaces); negotiating the API level (it isn't negotiated — the app picks).
**Verified**: new pure encoder tests (`KilterProtocolTests` / `KilterProtocolTest`) pin the exact
framed bytes off-device on both platforms. The live BLE write path stays **device-pending** per the
repo's hardware rule — not reported as working until lit on a real board.

## [2026-06-06] Kilter — in-app catalog download from a hosted dataset (Phase 2) (#42)

**Decision**: `KilterCatalogSyncView` gains a **Download from Kilter** button that fetches a board's
catalog as a **gzipped SQLite from a static host the user controls** (the Snappet *Board Explorer*
GitHub Pages site, `board-data/<board>.sqlite.gz`, by default), then **trims it on-device** with the
same filters the explorer's `exportDb.ts` uses, and installs it through the unchanged
`KilterCatalogInstaller` path. The user **explicitly accepted the legal trade-off** (2026-06-06) that
prompt 22 deferred. This reverses *only* the "sync stays inert" part of the [2026-06-05] entry;
everything else there (no re-bundling, user-data model untouched, file-import primary) **still holds**.

**Why a hosted dataset and NOT Aurora's API**: the first cut called Aurora's `/sync` directly (mirroring
`boardlib`'s `login` + paginated sync). That host (`kilterboardapp.com`) turns out to **reject every TLS
handshake** (verified from macOS curl/openssl/Python *and* the iPhone — an IONOS box that returns
`internal_error`); `boardlib`'s real catalog path doesn't use `/sync` at all, it extracts `db.sqlite3`
from the official APK. Scraping a 108 MB APK from apkpure on-device was the only other "live" path —
heavy, fragile, and the worst legal posture. The user already hosts the datasets on their own Pages
(under their own ToU acceptance) via the Board Explorer, so the app just downloads a file from a URL the
user controls — much closer to "bring your own file" than any Aurora-direct fetch.

**Concrete choices made:**
- **`KilterAuroraSync.swift` → `HostedCatalogClient`** owns the module's only `URLSession` (ephemeral):
  one GET for `manifest.json` (to list importable boards) and one for `<board>.sqlite.gz`. It streams
  the gzip through **zlib** (`inflateInit2_(…, 47)` — added `libz.tbd` + `#import <zlib.h>` to the
  bridging header) to a temp file, never holding the ~165 MB raw DB in memory.
- **Trim mirrors the Board Explorer `exportDb.ts`**: `ATTACH` the downloaded DB, recreate each table from
  its source DDL, copy reference/geometry tables (`FULL_TABLES`) whole, subset the climb tables to a
  `_keep` set of filtered uuids, recreate indexes, `VACUUM`. The filter (`CatalogFilter`) mirrors
  `query.ts buildConditions` (layout/grade/ascents/quality/setter/name/benchmark/listed/single-frame)
  **plus a `maxClimbs` top-N-most-climbed cap** — the explorer expects manual narrowing; a phone always
  caps (like `build_bundled_db.py --limit`). Real-data check: top-2000 → a **6.1 MB** importable catalog.
- **No accounts.** The dataset is a static file, so there are no credentials — the picker is board +
  filters only. The host URL is editable (`@AppStorage`) so the user can point elsewhere.
- **Pure half unit-tested; download is device-owed.** `KilterAuroraSyncTests` covers the real zlib
  gunzip (round-trip) and the filtered build (top-N cap, empty-match → throw, benchmark-only) by feeding
  the `KilterCatalogFixture` as a synthetic source through the real reader. The 81 MB download itself is
  verified on the physical device.

**Follow-up same day (filter parity · layout scope · multi-catalog library):**
- **Full Board-Explorer filter parity** in the download sheet — `CatalogFilter` already mirrored
  `query.ts buildConditions`; the sheet now surfaces all of it (layouts, **angle**, min/max grade, min
  ascents, min quality, setter, name, benchmark/listed/single-frame) + the top-N cap. Grade/angle/layout
  option lists are **static Kilter constants** (`KilterCatalogOptions`) since the dataset isn't loaded
  until after download; the grade scale is the real `difficulty_grades` (difficulty 10–33 → V0–V16).
- **Scope today = Kilter Original (1) + Homewall (8) only.** Other boards (from the manifest) and other
  Kilter layouts render **struck-through / disabled** in the sheet as explicit future work — the reader
  is Kilter-shaped and only these two layouts are validated.
- **The store became a multi-catalog *library*.** `KilterCatalogStore` now keeps each install under
  `catalogs/<uuid>/` with an `active-catalog` pointer file (was a single `kilter.sqlite3`); `install`
  **adds + activates** (no longer replaces), and there's `installed()` / `remove(id:)` / `setActive(id:)`
  + a one-time migration that folds any legacy single file into the library. A meta `name` (optional,
  back-compat) labels each entry. **Settings** gained a **Download from Kilter** button and a
  **Downloaded catalogs** list — tap to make active, swipe to remove — replacing the single
  refresh/remove rows. The reader still opens the *active* catalog and reloads on the change
  notification, so switching active in Settings re-points browse.

**Android port (same day):** the whole feature is ported to Kotlin/Compose at parity — `HostedCatalogClient`
(`HttpURLConnection` + `java.util.zip.GZIPInputStream`, so no zlib shim is needed unlike iOS;
`SQLiteDatabase` ATTACH for the same exportDb-style trim), the multi-catalog `KilterCatalogStore`
(`catalogs/<id>/` + `active-catalog` pointer, install adds + activates, `installed()`/`remove(id)`/
`setActive(id)`, legacy migration), a `KilterCatalogDownloadSheet` (ModalBottomSheet) with the full
filter set + Original/Homewall scope (others struck-through), and a Settings **Downloaded catalogs**
list (RadioButton active + per-row Remove) + **Download from Kilter** button. Added the **INTERNET**
permission (was BLE-only). One Android-specific gotcha: `SQLiteDatabase.execSQL` rejects
`PRAGMA journal_mode` (it returns a row) — dropped the PRAGMA optimizations. Instrumented suite green
(23, incl. multi-catalog + filtered-build). Device-owed: the live ~80 MB download → trim on a real
Android device (the pure half is covered).

**Rules out / guardrails (unchanged)**: **not** for public App Store distribution — Aurora's ToU +
App Store Guideline 5.2.2 keep this **personal / sideload** only; the carve-out stays narrow + named.
No Aurora API calls, no re-bundling a catalog into the app, no background/auto sync (user-initiated
only), no analytics, no Snappet backend, nothing uploaded; egress is one GET to the configured host. The
user-data model (`KilterLogEntry`/`KilterSession`/`KilterFavorite`) is untouched and file-import stays
primary. Android port to follow (the seam is identical).

## 2026-06-06 — Rich text overlays: wrap-to-width fit + colour/highlight/font/style (P21)

Device feedback: a large climb-name caption spilled past both edges of the video, and text had no
styling. Two changes. **(1) Wrap-to-width fit** — the `.climbName` preview chip had NO width cap (only
`.text` did), so it grew as wide as the text and overflowed into the letterbox; the export box was also
sized from EXPLICIT newlines, not wrapped lines. Now both **wrap to ~0.9 of the video width**: the
preview uses `.frame(maxWidth: rect.width*0.9)` + `fixedSize(vertical)`, and the export measures the
wrapped height via `NSAttributedString.boundingRect` and sizes the `CATextLayer` container to it — so a
multi-line caption never clips and preview == file. **(2) Rich style** — `OverlayItem` gained
`highlightHex` (background), `fontRaw` (a new pure `StudioFont` enum: system/rounded/serif/mono), `bold`,
`italic` — all **additive + defaulted** (migration-safe Codable, like the prior optional fields).
Rendered in BOTH the SwiftUI preview (TextOverlayChip.styledText) and the Core-Animation export
(StudioOverlays.styledTextLayer) via a shared mapping: `StudioFont.swiftUIDesign` ↔ `uiFont`
(UIFontDescriptor design + symbolic traits). Text + climb-name now share ONE styled path (climb-name is
text with a dark-highlight default). A paintbrush "Style" sheet (StudioTextStyleControls) edits colour /
highlight (None + swatches) / font / bold / italic; all commit `editOverlaysOnly` (overlays aren't in the
playback composition → no rebuild). **Why a font ENUM, not a font-name string**: the four presets map
cleanly to a `Font.Design` (SwiftUI) and a `UIFontDescriptor.SystemDesign` (UIKit) so preview and export
match without bundling fonts; arbitrary font names wouldn't render identically in CATextLayer. **Why the
export measures wrapped height**: a fixed line-count box clips wrapped captions; `boundingRect` is the
only way to size the chip to the actual wrapped text. **Rules out**: a climb-name chip with no width cap;
sizing the export box from `\n` count; a font-name string field; a separate ClimbName config (text +
climb-name share the styled layer). **Limitation**: climb-name's highlight has a dark fallback so it
always shows some background (the picker recolours it); fully removing it isn't exposed. **Verified**:
builds clean, full unit suite green (301) incl. the new style setters + migration-safe defaults. **Device
pending**: the styled caption rendering in **export** on real footage.

## 2026-06-05 — PiP/base resize: aspect-locked corner-drag + flicker-free live resize (P21)

Device verification of the placement fix surfaced two more resize issues, both fixed in
`StudioOverlayCanvas`. **(1) Letterbox on free resize** — after the fill→fit change, dragging a PiP
corner to an aspect ≠ its footage left the dashed box bigger than the aspect-fit video (the box stopped
hugging the video). Fix: **lock corner-resize to the source aspect** — the canvas now receives
`sourceAspects` (resolved oriented w/h per `localIdentifier`, already computed in the VM) and the base
video's aspect; `ResizableFrame.resizedFrame` derives the off-axis from `contentAspect` and
`clampedAspectSize` clamps into [0.1,1] **while preserving the ratio**, so the box always keeps the
footage aspect → the fit video fills it edge-to-edge. Pinch + grid presets still allow free aspect (for
collages). **(2) Resize flicker** — the live-resize had been driven by a `@State liveResize` SET FROM
the corner handle's own gesture callback, and the handle's on-screen position was recomputed from that
same state. So the handle moved out from under the finger → re-fired its gesture → oscillated (the
new aspect-lock branch `newW >= newH·r` toggling each frame amplified it into a visible flicker,
confirmed by frame-diffing a screen recording: the changing pixels were the box/handles, not the video).
Fix: the **canonical SwiftUI draggable pattern** — replace `@State` with a `@GestureState cornerDrag`,
anchor the gesture-hosting handles at the **committed** size (they never move during the drag, so the
gesture's translation stays stable), offset ONLY the dragged dot, and render the live-resizing outline
as a **non-interactive** overlay (hosts no gesture → can't feed back). **Why @GestureState over @State**:
@GestureState is bound to the gesture lifecycle and auto-resets, and — critically — moving it out of the
handle's layout-position path is what breaks the feedback loop. **Rules out**: driving live-resize layout
from a `@State` the gesture writes; repositioning a gesture host from its own gesture value; per-axis free
resize for a PiP (now aspect-locked on corner-drag). **Verified on device (MrRobot)**: placement sits
under the outline (preview), corner-resize hugs the video with no letterbox, and the drag is smooth (no
flicker) — confirmed by screen recording. Builds clean; full suite green.

## [2026-06-05] Kilter — stop redistributing Aurora's catalog; opt-in on-device fetch (#42)

**Decision**: The Kilter mini-app no longer **ships** Aurora Climbing's climb catalog. The bundled
`kilter.sqlite3` is **deleted** from both platforms (`ios/App/Snappet/Resources/`,
`android/app/src/main/assets/`) and the app contains **zero** Aurora climb data. Instead, the catalog
is **imported onto the user's own device**, under their own relationship with Aurora — the redistribution
exposure flagged in #32 OQ#11.2 is removed **architecturally**, not by waiting on a licensing
negotiation. Traces to [#42](https://github.com/harshal2802/snappet-mobile/issues/42); the
written-permission path (option 2) stays recorded as complementary future scope.

**Concrete choices made:**
- **A catalog-provider seam, read path unchanged.** A new `KilterCatalogStore` owns the on-device
  catalog file (`Application Support/Kilter/kilter.sqlite3` on iOS, `filesDir/kilter/…` on Android) +
  a `catalog.meta.json` sidecar (version / climb count / size). The existing `KilterCatalog` reader is
  **reused verbatim** — it just opens the store path instead of the bundle, degrades to
  `isAvailable == false` when nothing is installed, and gains a `reload()` (iOS, via a
  `didChangeNotification`) / `reset()` (Android) to re-open after an import/remove. `KilterCatalogProvider`
  is the **only** IO edge: `FileImportProvider` (iOS **Files** / Android **SAF**) is the shipped Phase-1
  path; `AuroraSyncProvider` is an **inert, documented Phase-2 stub** (conforms to the protocol, performs
  no network calls, the sync button is disabled). `KilterCatalogValidator` opens a candidate read-only,
  asserts the required tables exist, requires ≥1 listed climb, caps size, and derives a deterministic
  version — so a malformed/foreign file is rejected with a clear message instead of installing junk.
- **First-open shows an opt-in screen, not an empty list.** `KilterCatalogSyncView` (iOS) /
  `KilterCatalogSyncScreen` (Android) explain the import, **surface Aurora's Terms of Use + a link**
  before any fetch, and make clear the data stays on-device. `KilterSettingsView`/`Screen` gain catalog
  status (version • climbs • size) + **Refresh** + **Remove downloaded catalog** (removal keeps logged
  ascents + saved climbs).
- **The on-device-only rule gets one narrow, named carve-out** (`project.md:64` footnote): the Kilter
  catalog fetch is a **user-initiated** network request, because the data is third-party-owned and can't
  be redistributed by us. No background sync, no analytics, no Snappet backend; health + media still
  never leave the device. Kept narrow so it can't be cited to justify general networking elsewhere.
- **Tests use a synthetic fixture — zero Aurora data.** `tools/kilter/build_test_fixture.py` (run +
  verified locally against every reader query) and an in-code `KilterCatalogFixture` (Swift + Kotlin,
  same rows) author a tiny invented catalog (two layouts, a small hole grid, four made-up climbs). iOS
  installs it under a `-uiTestInstallKilterCatalog` launch arg; Android via a `TestHooks` flag in
  `MainActivity`. New `KilterCatalogStoreTests` / `KilterCatalogStoreTest` cover validate/install/clear +
  reader integration; the existing Kilter UI/walkthrough tests now install the fixture first (they used
  to rely on the bundled asset).

**Why**: Aurora's [Terms of Use](https://kilterboardapp.com/terms-of-use) claim their data + derivatives
as sole/exclusive property usable only with written consent; a trimmed rebundled copy is a derivative,
and this is actively-policed IP. Shipping code that *the user* points at their own catalog distributes
**code, not Aurora's database** — the only shippable-and-legal option short of a permission deal.

**Rules out**: bundling any Aurora data in the app (the asset is gone, not just unreferenced); a live /
background / always-on sync (fetch is user-initiated only); analytics or a Snappet backend; using the
carve-out to justify networking in other modules; changing the **user-data** model (`KilterLogEntry` /
`KilterSession` / `KilterFavorite` stay in SnappetCore/Room exactly as before); APK-extraction on device
(rejected — store-hostile/fragile). Phase 2 (`AuroraSyncProvider` real endpoints) stays blocked on the
endpoint/account/ToU open questions in #42 and is **not** implemented.

**Verified** (2026-06-06, macOS + Xcode 26.5 / Android SDK): both platforms compiled and run **green**.
iOS — full suite on the iPhone 17 Pro sim: **307 unit + 16 UI tests, 0 failures**, plus the
`HighlightEngine` SPM suite (21). Android — **37 unit + 18 instrumented tests, 0 failures** (Pixel 7
AVD). One first-pass fix was needed: the Kilter UI tests filtered out every synthetic climb because the
`@AppStorage` browse filters (angle/layout/grade) persist in UserDefaults and `-uiTestFreshStore` only
resets SwiftData — a leftover `kilter.angle` (the old bundled Aurora catalog had angle-0 climbs; the
fixture only has 25/30/40) yielded "No climbs match". Fix: `KilterCatalogFixture.installForUITestingIfRequested()`
now clears the Kilter filter keys so browse opens on the fixture-covered defaults. Bundle-inspection
acceptance confirmed on the built artifacts: **no `kilter.sqlite3` in the iOS `.app` or the Android
`.apk`** (the APK carries only `androidx.sqlite` library version-stamps, not data).

## [2026-06-04] Split Expenses — typed receipts (profiles + auto-detect classifier)

**Decision**: Let the user pick a **receipt type** before scanning/pasting (or leave it on **Auto**),
and have that type tune extraction. Implemented as **parse-time only** — no persisted column, no
`ReceiptSplit` change — so it stays additive and migration-free.

- **`ReceiptType`** { auto, grocery, warehouse, restaurant, gas, pharmacy, retail, generic } maps to a
  pure **`ReceiptProfile`** (extra skip-keywords, tip-line prefixes, a `fuelOnly` flag).
  `ReceiptParser.parse(text, profile:)` gains an optional profile that defaults to `.generic`, so the
  existing `parse(text)` behaviour and all current tests are unchanged.
- **Profiles**: restaurant adds SERVER/TABLE/GUEST… to the skip set and turns a `TIP`/`GRATUITY` line
  into a "Tip" line item (split among the diners); gas skips PUMP/GALLON/UNLEADED… and collapses to a
  single "Fuel" item from the detected total; pharmacy/retail add their own metadata skips;
  warehouse/grocery use the generic Costco-tuned base.
- **`ReceiptClassifier.classify(text)`** (pure) scores signature keywords per type for **Auto**; the
  picker then snaps to the detected type so the user sees the guess and can override.
- **UI**: a "Receipt type" picker in `NewReceiptSheet` (iOS `Picker`, Android dropdown). Scan/paste now
  hand raw text back to the sheet, which parses it with the resolved profile.

**Why**: a single generic parser mis-reads restaurant tips and gas pumps; a tiny per-type profile fixes
extraction without complicating the data model. Keeping type parse-time-only (vs. a persisted
`receiptType` column) honours the "bug-fixes + validation first, types as a thin follow-up" scope and
avoids a Room migration. **Rules out**: persisting the type this cut; a separate `tipAmount`/proportional
tip (tip is an equally-split line item for now — proportional tip is a follow-up); per-type split rules.
**Verified**: `ReceiptClassifierTests`/`Test` cover classification + the restaurant/gas/generic parse
branches off-device on both platforms. UI pickers stay device-unverified per the repo's build rule.

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

## [2026-06-04] Dynamic sessions + Kilter-driven climbing — direction set (design only, no code)

**Decision**: Captured a design review (`pdd/prompts/features/dynamic-sessions/DESIGN.md`) for two
user-requested capabilities, **design-only** for now (iOS code needs a Mac+Xcode to compile/verify per
the on-device rules below; this records the model + decomposition a Mac session implements):

- **Dynamic / freeform sessions.** Today every session is routine-locked — the only entry is
  `startWorkout(from: Routine)` → `makeSession(from:)` and `WorkoutPlayerView` walks a **frozen**
  `session.exercises` array (mutates set slots, never appends). But the *model is ~80 % ready*:
  `WorkoutSession.routineID` is already `UUID?` and `exercises`/`sets` are plain Codable arrays, so a
  routineless **Quick Start** + **add-exercise/add-set live** needs **zero schema change** — it's a
  player + entry-point job. Ship freeform **lifting first** (self-contained, no migration).
- **Polymorphic set unit (`SetKind`).** Dynamic gym climbing is **Shape ③ (graded attempts), not
  reps×weight**, so a "set" must be able to be a climb attempt. Chose: tag the *exercise* with
  `kindRaw: String?` (nil ⇒ legacy reps/weight) + **optional** `SetLog` fields (`durationSec`,
  `distanceM`, `climbGradeLabel`, `climbStatusRaw`, `climbAttempts`). **Critical migration nuance:**
  `SetLog`/`SessionExercise` are nested **Codable composites**, not `@Model`s — SwiftData lightweight
  migration does NOT cover fields inside an encoded blob, so a new **non-optional** key would make old
  blobs throw on decode. Hence every added field is `Optional`. **Rejected** a `SetMeasure`
  enum-with-associated-values (cleaner, but a bigger hand-written-Codable blob-migration surface).
- **Kilter → WorkoutTracker bridge.** The key enabling fact: `Routine`/`WorkoutSession` and
  `KilterLogEntry`/`KilterSession` are **all in the same `SnappetSchema.models` store**, so this is an
  in-process `@Query`, **not** a sync/network path (on-device rule #1 intact). Two features: **(B.1a)** a
  read-only adapter surfacing board sessions in the unified workout history (no new `@Model`, Kilter
  stays owner) — *why:* board climbs currently have no HR/reel pipeline; and **(B.2)** a pure
  `KilterRecommender` that turns the existing grade pyramid into a suggested climbing session
  (working-grade sends + project attempts + warm-ups), feeding the `.climbAttempt` exercises.

**Why**: closes the two real gaps the user hit — sessions can't grow at runtime, and the Kilter mini-app
is an island — while reusing the existing on-device store and the pure-logic-at-a-thin-edge pattern
(`SetKind` formatter/validator + `KilterRecommender` are unit-testable on the cloud box).

**Rules out / notes**: this **partly reverses** `decisions.md` 2026-06-02 ("keep Kilter separate") —
recorded as an explicit open fork (one-way read recommended, not a two-way merge). Defers: a unified
`WorkoutSession` projection of board climbs with HR/reels (B.1b, until B.1a proves out), full GPS/splits
cardio (Shape ②), and the enum-with-payloads measure. **Status: design only** — nothing built; knowledge
graph untouched until implementation (no node exists yet).

## [2026-06-04] Photos-level clip ops + HR overlay on set clips + a deep video-feature review

**Decision**: Two user-requested capabilities on the per-clip editor + a review pass.
- **Photos-library operations (every destructive one confirmed).** `MediaLibraryService` gains
  **`overwriteVideoAsset`** (replace the original in Photos with the edited render via
  `PHContentEditingOutput` — reversible in Photos; **remove-then-copy** onto `renderedContentURL`,
  since copying onto Photos' reserved path throws "file exists") and **`deleteAssets`**
  (`PHAssetChangeRequest.deleteAssets`); both read-write auth, PhotoKit non-Sendables boxed. The clip
  editor offers **Save a copy** (new asset) + **Overwrite original** (confirm). Session-detail Remove →
  a confirmation: **Remove from session only** vs **Delete from Photos too** (deletes the asset FIRST,
  then drops the tag only on success). Hosted on the stable `List`.
- **HR chart overlay on per-set clips.** `ClipEdit.hrOverlay` (optional) + `EditPlan` carries the HR
  samples **sliced/rebased to the clip's capture window** (`[offsetSec, +duration]` from the session's
  `hrSeries`). `VideoStudio` attaches the HR Core Animation layer on **export** (reuses
  `StudioOverlays.hrChartLayer`); the clip editor previews it as a live SwiftUI `StudioHRChartView`
  (drag/pinch). A **`forPlayback`** flag was added to `VideoStudio` (mirroring `StudioComposer`) so the
  preview composition omits the Core Animation tool — this also **fixed a latent crash**: text overlays
  attached the offline-only tool to the AVPlayerItem preview, which would have raised the same
  NSException the studio hit.
- **Deep review (two agents) → fixes**: guarded the clip-editor preview `setVideoComposition`
  (NSException); strictly-increasing HR-dot `keyTimes` (duplicate timestamps dropped the export
  animation); honored PiP opacity (removed an `==0?1` bug); the studio time observer only advances the
  playhead while playing (don't fight a scrub); delete-from-Photos ordered asset-first. **Known minor
  (not blind-fixed without device visual):** exported `CATextLayer` text sits slightly higher than the
  preview chip (top-origin glyphs). **Verified:** unit suite 206 (2 skipped), studio UI walkthrough
  green on the iPhone 17 sim. Photos overwrite/delete + HR-on-clip export are device-only (owed a device
  visual pass).

## [2026-06-04] Session detail → per-set tiles (media+HR unified) + HR-overlay pinch + Find-media polish

**Decision**: Follow-up UX from device feedback.
- **HR chart overlay is pinch-resizable** in the studio preview (`StudioHRChartView` `MagnifyGesture` →
  `setHRScale`, 0.3…1), matching the PiP resize; the HR tool's size slider still works.
- **Session detail unified to one tile per set.** `SessionDetailView` no longer renders set logs and
  the tagged-media gallery in separate places. `SessionMediaSection` now owns the per-exercise sections:
  each set is a `SetTileRow` (reps/weight + the **heart rate at the set's completion**, nearest
  `hrSeries` sample, zone-coloured) and its tagged photos/videos render as **rows beneath it** (multiple
  media → multiple rows). A **General** section holds unassigned media. The big B2 HR chart stays above.
- **Media removal is discoverable** (#3 — it was context-menu-only): each media row has **swipe-to-remove**
  (trailing) + **swipe-to-move** (leading) plus the existing long-press menu.
- **Find-media workflow** (#4) reviewed — the discovery logic was already sound (padded
  `[start−90s, end+90s]` window, dedupe, offset-align in `SessionMediaService`). Added a **Settings
  escape hatch** when Photos access is `denied`/`restricted`/`limited` (auto-discovery needs full
  access; limited can only PHPick), a found-count / explained-empty message that names the searched
  **time window**, and clearer limited-access copy.

**Rules out / notes**: per-set HR is the **nearest sample at set completion** (not an interval average) —
simple + meaningful. Walkthrough-critical ids preserved (`openStudio`/`generateHighlight`/`mediaThumb` +
a "Set N" label + a "General" header). `SessionMediaThumb` gained a `side` param (compact 54 pt in
rows). Verified: studio UI walkthrough green on the iPhone 17 sim; unit suite 206 (2 skipped), 0
failures. Device visual pass owed (thumbnails/discovery are device-only).

## [2026-06-04] Studio timeline zoom + PiP video overlay + HR-chart overlay

**Decision**: Three follow-on studio features (separate commits).
- **Zoomable timeline** — `StudioTimelineView.pps` is now a computed `zoomPps · pinchScale`, clamped
  12…200 pt/s, driven by a `MagnifyGesture` (simultaneous with the scrub drag) + `−/+` buttons
  (`timelineZoomOut/In`). Everything (offset, strip widths, ruler) reads `pps`, so the whole timeline
  zooms together.

- **PiP video-over-video** — `OverlayItem.Kind.video` (content = a session clip's `localIdentifier`).
  The composer adds a **second video track** per PiP, aspect-filled into a frame
  (`ClipEditGeometry.pipRect` + `fillTransform`, Y flipped to the composition's bottom-left origin),
  oriented, and **time-gated** via opacity (0 outside `[startSec, endSec]`). PiP forces the
  **instruction path** (renders in preview AND export, unlike the export-only text/sticker tool) — so
  with a PiP present, per-clip filters are dropped (degradation; transitions+PiP also deferred). The
  WYSIWYG canvas renders a draggable + **pinchable** frame outline (the real PiP shows through from the
  player); position/scale/delete of a `.video` overlay **rebuild** (it's in the composition), unlike
  text/sticker. Add via the **PiP** action-bar button → pick a session clip.

- **Heart-rate chart overlay** (moving-playhead line) — the session's `hrSeries` (fetched by the
  project's `sessionID` FK in the VM) maps across the **whole video**; a dot tracks the video's 0…1
  progress. `HROverlayConfig` (optional on `StudioProject` → migration-safe) carries position/scale/
  colour/showBPM/zoneColored. **Pure `HRChartGeometry`** (normalized points, time→bpm sampling) feeds
  BOTH renderers, so they match: **preview** = a live SwiftUI chart (`StudioHRChartView` — line + dot +
  live BPM, draggable), **export** = Core Animation in `StudioOverlays.hrLayer` (the polyline + a dot
  animated along it via a `CAKeyframeAnimation` keyed to the timeline, bottom-left origin). HR overlay
  config is threaded through `makeComposition`/`export`/`makeAnimationTool` (`hrSamples` + `hrConfig`);
  it's not in the playback composition, so edits don't rebuild the player. Customization via the **HR**
  action-bar tool (enable · colour · size · live-BPM · zone-colour); position by dragging the chart.

**Rules out / caveats**: the **live BPM number is preview-only** (Core Animation can't keyframe a
`CATextLayer`'s string) — export shows the line + moving dot (+ zone/colour). PiP+filter and PiP+
transition still degrade (one custom `AVVideoCompositing` is the eventual unifier). **Device-pending
visual**: PiP placement (Y-flip), the HR dot sync, and the export Core Animation chart need the user's
device pass (the sim renders the SwiftUI preview chart but not the AV export). Unit suite **206
(2 skipped), 0 failures**; studio UI walkthrough green on the iPhone 17 sim.

## [2026-06-04] Studio editor → edits/CapCut layout (multi-phase redesign)

**Decision**: Rebuild the multi-clip editor UI to the edits/CapCut layout the user referenced, in
phases (separate commits, sim-UI-tested each). **Phase 1 (done)**: a custom **top bar** (X · editable
title · export-quality menu · Export), a preview with a **controls-free `AVPlayerLayer`**
(`StudioPlayerLayerView`, `.resizeAspect` so its displayed rect matches `ClipEditGeometry.displayRect`
for overlay alignment) + a **custom transport** (play/pause + live `MM:SS / MM:SS` timecode driven by a
periodic `AVPlayer` time observer in the VM, Swift-6-safe via `MainActor.assumeIsolated`), and a
**contextual bottom action bar** (Split · Speed · Filter · Transition · Text · Canvas · Delete) whose
value-pickers open a focused **bottom sheet** (`StudioToolSheet`). Split is now **playhead-driven**
(`splitAtPlayhead` cuts the clip under `currentTime`). Export quality is a pure
`StudioExportQuality` (preset-name string, no AVFoundation import) passed to `composer.export`, which
falls back to HighestQuality if the preset is unsupported.

**Why**: the prior vertical stack (preview / cards / controls list) couldn't reach edits-parity by
accretion; the transport + action-bar + tool-sheet shell is the foundation the timeline/adjust/audio
phases build on. NavigationStack chrome dropped for a custom dark top bar.

**Phase 2 (done)** — `StudioTimelineView`: a **scrubbable** timeline (clip strips laid by output
duration, a **fixed centre playhead**, a time ruler) where dragging seeks the preview + moves the
playhead, and during playback the strip auto-advances (it's offset by `vm.currentTime`). Tap a strip to
select; the selected video clip gets **drag-trim handles** (leading→`trimStart`, trailing→`trimEnd`),
committed **once on drag-end** (live handle feedback is view-local → one undo entry + one rebuild).
Clip strips are coloured placeholders — **thumbnail strips are a device-only follow-up**. The strip
layout uses `StudioGeometry.timeline` placement (so a transition overlap shows clips overlapping; rare).

**Rules out / notes**: the time observer is removed+reattached on each `rebuildPreview` (no leak); the
end-of-play notification resets the playhead. At `t=0` the first clip strip starts at the centre
playhead (so its centre is off-screen) — the studio UI walkthrough therefore asserts the action bar
(reliable) and treats per-clip timeline selection as best-effort; a dedicated `StudioEditorUITests`
covers selection/trim.

**Phase 3 (done)** — **Adjust (colour)** + export quality. `ClipAdjust` (brightness/contrast/
saturation) is an **optional** on `TimelineClip` (nil = neutral → migration-safe Codable add); the
composer's CIFilter path applies it via `StudioFilters.applyAdjust` (`CIColorControls`) after any
filter, and is now entered when a clip has a filter **or** a non-neutral adjust. Unlike overlays,
adjust+filter **do** render in the live preview (CIFilter compositions are AVPlayerItem-legal). The
Adjust tool sheet's sliders commit **on release** (`onEditingChanged`) → one rebuild per drag. Export
quality (`StudioExportQuality`) was wired in Phase 1.

**Phase 4 (done)** — **audio + overlay keyframes**. Per-clip **volume/mute** (`TimelineClip.volume`,
optional → migration-safe) applied via an `AVAudioMix` the composer now returns alongside the
composition + videoComposition (a triple; `rebuildPreview` sets `item.audioMix`, `export` sets
`session.audioMix`). **Add music**: a `.fileImporter` (`.audio`) copies the pick into Documents →
`AudioTrack(.music)`; the composer inserts it on its own audio track at `startSec` and volume-mixes it
(missing file skipped → export-safe). **Overlay opacity keyframes**: an opacity slider + a marker
button (`addOverlayKeyframeAtPlayhead`) capture opacity at the playhead into `OverlayItem.opacityKeyframes`
(the export `StudioOverlays` already animates them). Contextual **overlay controls bar** (opacity ·
keyframe · delete) replaces the clip action bar when an overlay is selected.

**Rules out / follow-ups**: per-clip volume + **transition** path (transition audio is a plain stitch,
no mix); music **fades**/trim UI; keyframed overlay **position/scale**; thumbnail timeline strips.
**Honest caveat**: the audio mix (volume + music) and the music **file import** are device-only — the
sim has no real clip audio and the import needs Files; the on-device export-success + the *sound* are
owed by the user's device pass (per the repo rule). Verified Phases 1–4 on the iPhone 17 sim: studio UI
walkthrough green; unit suite 199 (2 skipped), 0 failures.

## [2026-06-04] Studio WYSIWYG overlay positioning — draggable SwiftUI layer over the preview (edits/CapCut pattern)

**Decision**: Make text/sticker overlays **positionable by dragging them on the preview canvas**
(user ask: "how to make sure / correct the location of the text overlay", with an edits/CapCut
reference). Crucially, overlays are **NOT** rendered into the live preview video — the Core Animation
overlay tool is export-only (the crash entry below) — so the editing surface is a **SwiftUI layer on
top of the player** (`StudioOverlayCanvas`), exactly the edits/CapCut model where the chip is live UI
and the pixels are burned in only at export.

**Why it's correct (WYSIWYG by construction)**: `OverlayItem.position` is normalized `0…1`, top-left.
**Export** maps it via `ClipEditGeometry.layerPoint` (→ CALayer, y-flipped); the **preview chip** maps
the *same* normalized value into the **displayed video rect** (`ClipEditGeometry.displayRect` — the
aspect-fit area inside the player, NOT the whole player frame) via the new `previewPoint` /
`normalizedPoint` (inverse, clamped). Both read one normalized value ⇒ what you drag is what exports, at
any resolution. Chip sizes mirror `StudioOverlays` (font = canvasH·0.05·scale, sticker = canvasH·0.12·
scale). Because it's pure SwiftUI, **overlay positioning works on the simulator** (no device/Photos).

**Shape**: pure `ClipEditGeometry.displayRect/previewPoint/normalizedPoint` + pure
`StudioProjectEditor.setOverlayPosition` (clamped) — both unit-tested (6 new cases). VM gains
`overlays`/`selectedOverlay`/`selectOverlay`/`setOverlayPosition`/`deleteOverlay` and an
**`editOverlaysOnly`** path that commits+persists but **skips the player rebuild** (overlays aren't in
the playback composition, so dragging mustn't restart playback). `addText` now selects the new overlay.
Drag commits once (on end) via a `@GestureState` offset; selected chip shows a dashed ring + a Delete
affordance.

**Rules out / follow-ups**: overlay **resize/rotate** handles, **time-window** editing UI (still
`[0,3]s` default), keyframed **position animation**, and exact `.original`-aspect fidelity (the editing
rect falls back to 9:16 for `.original` since the VM doesn't track source size yet). Unit suite **195
(2 skipped on sim), 0 failures**; device build + install green. **Visual confirm owed** (drag accuracy +
the overlay landing in the exported file) — per the repo rule, tests prove the math/shape, not the look.

## [2026-06-04] Studio multi-clip editor crashed on open — Core Animation tool is export-only (device-found)

**Symptom**: opening the multi-clip Studio **aborted the app** on the device (SIGABRT). Pulled the crash
report off MrRobot (`idevicecrashreport`; the `.ips` doesn't carry the NSException *reason*, but the
backtrace did): `objc_exception_throw` → `-[AVPlayerItem setVideoComposition:]` →
`StudioEditorViewModel.rebuildPreview()`. The on-device reason (captured by guarding the call, below):
> *AVVideoCompositions using `AVVideoCompositionCoreAnimationTool` cannot be used with AVPlayerItem.
> `AVVideoCompositionCoreAnimationTool` is for offline rendering only.*

**Root cause**: `StudioComposer.makeComposition` attached the overlay `animationTool` to the **one**
videoComposition reused for **both** export and the live `AVPlayer` **preview**. The tool is legal for
export (`AVAssetExportSession`) but `AVPlayerItem` **rejects** it — and it rejects by raising an
**Objective-C `NSException`, which a Swift `do/catch` cannot catch**, so the `rebuildPreview` try/catch
didn't save it → process abort. The S0–S4 spike never caught this because it only ever drove the
**export** path (`AVAssetExportSession`), never `AVPlayerItem` — preview on a real device was never
exercised (the editor was sim-only + the cover-presentation fix).

**Fix** (two parts):
- **`forPlayback` flag** through `StudioComposer.makeComposition` / `assemble` / `assembleSingleTrack` /
  `assembleWithTransitions`: when **true** the videoComposition **omits** the Core Animation tool.
  `rebuildPreview` requests `forPlayback: true`; **export keeps `false`** (overlays still burn into the
  file). Net: filters/transitions/transforms now preview live; **overlays don't show in the live
  preview** (they do in export) — live overlay preview is a SwiftUI-overlay-layer follow-up (the
  edits/CapCut WYSIWYG pattern), NOT `AVSynchronizedLayer` inside the composition.
- **`Services/ObjCException`** (tiny ObjC `@try/@catch` + `Snappet-Bridging-Header.h`, wired via
  `SWIFT_OBJC_BRIDGING_HEADER` on the app target): lets Swift catch AVFoundation `NSException`s.
  `rebuildPreview` wraps `item.videoComposition = vc` in it — so an AVFoundation throw can **never**
  abort the studio again; it degrades to an on-canvas message + an `os.Logger` line. **Keep this** — AV
  raises ObjC exceptions in many places.

**Rules out / notes**: don't reuse one videoComposition for both `AVPlayerItem` and export when it uses
an `animationTool`. Verified on MrRobot: new `testPlaybackCompositionOmitsCoreAnimationToolAndExportKeepsIt`
(playback omits the tool + `AVPlayerItem` accepts it; export keeps it) + the 7-path export spike both
green; full unit suite **189 (2 skipped on sim), 0 failures**. **Honest caveat (unchanged)**: the device
test proves no-crash + a valid composition, NOT that the preview *looks* right — that's the user's visual
pass.

## [2026-06-04] Studio effects batch — sticker/keyframed overlays, slide/zoom, filter+overlay; filter+transition deferred

**Decision**: Filled out the studio effects (all device-export-verified via the spike, 7 paths):
- **Sticker overlays** (tinted SF-Symbol CALayer) + **keyframed overlay opacity** (drives the visibility
  animation from `opacityKeyframes` when present) — `StudioOverlays`.
- **Slide / zoom transitions** — on the two-track path, ramp **track B's transform** over the overlap
  (slide = full-width translate; zoom = scale about the canvas centre) instead of (or with) the dissolve
  opacity ramp. B is always on top, so it animates in when incoming / out when outgoing.
- **Filter + overlay** — attach the overlay animation tool to the CIFilter-handler path too.

**Deliberately CUT (quality call): filter + transition combined.** It needs a custom
`AVVideoCompositing` (the CIFilter handler composites tracks itself, so it can't cross-dissolve two
tracks). I built one but it hit Swift 6 `AVVideoCompositing` Sendability friction AND can't be visually
verified by a headless device test — shipping a blind, concurrency-fighting compositor is the wrong
trade. **Removed it; the case degrades gracefully** (the dispatch falls through to the filter path →
filters render, the transition is dropped). The unified compositor is the documented follow-up.

**Rules out / follow-ups**: filter+transition (custom compositor), animated overlay **position** (only
opacity keyframes today), Ken-Burns photos, audio cross-fade. **Honest caveat (unchanged)**: the spike
proves each path produces valid, renderable video — NOT that slides/zooms/stickers/keyframes *look*
right; that needs a visual pass (editor preview / exported file). Full unit suite 188 green (1 skipped).

## [2026-06-04] S4 studio text overlays — Core Animation overlay tool (device-verified export)

**Decision**: Added **time-gated text overlays**. `StudioOverlays` builds a Core Animation layer tree
(a `CATextLayer` per `OverlayItem` — positioned via `ClipEditGeometry.layerPoint`, scaled/rotated/
coloured, opacity-keyframed to appear only within `[startSec, endSec]`) composited via
`AVVideoCompositionCoreAnimationTool` — the proven `VideoStudio.attachOverlays` pattern, generalized to
`OverlayItem`. `StudioComposer` attaches it on the **instruction-based paths** (no-filter single-track /
two-track transition); the editor's "Add text overlay" action now renders end-to-end.

**Rules out / follow-ups**: **sticker** overlays (need image layers), **keyframed/animated** opacity &
position, and **overlay-with-filter** (the CIFilter handler composites tracks itself, so the animation
tool isn't wired on that path) — all deferred. The composer's three feature paths are unchanged; overlays
ride the two instruction paths.

**Verified on the iPhone 13 Pro Max** (the spike asserts it): a 16 s / 4-clip export **with a text
overlay** succeeds in ~4.9 s (the Core Animation tool costs more than a CIFilter, still well under
realtime). **Honest caveat**: export-success proves the composition is valid + renders — NOT that the
text's position/size/timing *look* right; that needs the editor preview / exported file. Full unit suite
188 green (1 skipped on the sim).

## [2026-06-04] Present sheets/covers with `item:`, not `isPresented:` + separate state (device gotcha)

**Decision**: The Studio cover opened as a **black empty screen on the device** (but worked on the
simulator). Cause: `.fullScreenCover(isPresented: $openingStudio)` whose content read a **separate**
`@State studioProject` — if SwiftUI evaluates the cover content before that assignment propagates,
`if let project = studioProject` is nil → an empty (black) cover. Simulator timing hid it; the device
exposed it. **Fix + rule**: when a presentation's content depends on a value, present **item-based**
(`.fullScreenCover(item: $studioProject) { project in … }` / `.sheet(item:)`), so the cover presents only
once the item is non-nil and the closure receives it — never an empty cover. Don't pair `isPresented:` with
a separate "the thing to show" `@State`. (Found by on-device testing; confirmed fixed on the device.)

## [2026-06-04] S3 studio transitions — dissolve via a two-track opacity ramp (device-verified export)

**Decision**: Added **dissolve transitions** between clips. Architecture: when any transition is set
(and no clip has a filter — the CIFilter handler composites tracks itself, so it can't combine), clips
**alternate between two video tracks** (A = even, B = odd) placed with the `StudioGeometry.timeline`
overlaps; **track B is composited on top and its opacity is ramped** over each overlap — fading B IN when
it's the incoming clip, OUT when it's outgoing — so the always-opaque track A underneath is revealed /
covered to cross-dissolve. Chosen because a single-track composition can't show two clips at once, and
this **track-B-ramp-only** scheme avoids per-segment instruction juggling and a custom compositor. Gaps on
each track are padded with `insertEmptyTimeRange`. The S1 editor's transition picker already drives it.

**Rules out / follow-ups**: slide/zoom transitions (transform ramps), combining a transition WITH a filter
(needs the unified Core Image compositor), and audio cross-fade during the overlap — all deferred.

**Verified on the iPhone 13 Pro Max** (the spike asserts it): a 16 s / 4-clip / 3-dissolve export succeeds
in ~2.8 s. **Honest caveat**: export-success proves the two-track composition is valid and renders — it
does NOT verify the crossfade *looks* right (no automated visual check); that needs the editor preview /
exported file. Full unit suite 188 green (1 skipped on the sim). The composer now has three feature paths
(single-track transform · CIFilter handler · two-track dissolve), split into `assembleSingleTrack` /
`assembleWithTransitions` for clean `sending` ownership.

## [2026-06-04] S2 studio filters — Core Image colour filters, device-verified

**Decision**: Built the first S2 effect — per-clip **colour filters** (mono / noir / fade / vivid / warm /
cool) — on the device-proven export path (S0). Architecture:
- **`StudioFilters`** (pure Core Image, unit-tested on the sim): `StudioFilter` + intensity → a configured
  `CIFilter`, with `apply()` + `aspectFill()` helpers. Warm/cool use a simple `CIColorMatrix` channel
  shift (avoids `CITemperatureAndTint`'s dual-neutral subtlety); vivid uses `CIColorControls`; mono/noir/
  fade are `CIPhotoEffect*`.
- **`StudioComposer`** routes any clip-with-a-filter through `AVMutableVideoComposition(asset:
  applyingCIFiltersWithHandler:)` — AVFoundation hands each frame to the handler as a `CIImage`, we
  aspect-fill to the canvas and apply the active clip's filter (looked up by the request's composition
  time). No-filter clips keep the layer-instruction transform/crop path. **Chose the CIFilter-handler API
  over a custom `AVVideoCompositing`** — far less coordinate/pixel-buffer risk for the same result.
- The S1 editor's filter picker now renders end-to-end (preview + export) with no UI change.

**Why it matters / rules out**: this is the template for the rest of S2+ (transitions, keyframed overlays
ride the same compositor). **Known follow-up**: the filter path currently aspect-fills (it supersedes the
per-clip *crop* transform) — combining precise crop WITH a filter is deferred.

**Verified on the iPhone 13 Pro Max** (the S0/S2 spike, now asserting it): a 16 s / 4-clip **filtered
(vivid)** export succeeds in ~3.0 s vs ~2.6 s transform-only — Core Image per-frame adds ~15 %, still
~0.2x realtime. Full unit suite **188 green** (4 new `StudioFiltersTests` incl. a warm-vs-cool channel
check; 1 skipped on the sim).

## [2026-06-04] S0 studio-export spike — **GO** (videoComposition export fixed; root cause = empty audio track)

**Decision / finding**: Ran the S0 device-profiling spike (`StudioComposerProfilingTests`, on the iPhone
13 Pro Max via free-Personal-Team signing) to gate the S2+ compositor. Verdict **CONDITIONAL GO**, full
write-up in [`live-workout-studio/RESULTS-S0.md`](../prompts/features/live-workout-studio/RESULTS-S0.md):
- **Capacity is ample** — a 16 s / 4-clip / 1080×1920 multi-clip **stitch** (passthrough) remuxes in
  **~0.1 s** on-device. Export time/memory is a non-issue at this scale (the design's worry is moot).
- **The export *mechanism* is the blocker** — applying our hand-built `AVMutableVideoComposition` (the
  transform/crop / future-effects path) fails `AVFoundationError -11838` ("operation not supported",
  underlying `OSStatus -16976`) on-device for **every** transcode preset (HighestQuality / HEVC /
  1920x1080). Passthrough-without-videoComposition is the only path that exports.
- The spike also **caught + fixed a real composition bug**: `StudioComposer.assemble` emitted one layer
  instruction per clip on the same single track (malformed) → now one layer instruction with per-clip
  `setTransform(at:)`. Also refactored `makeComposition` to expose an AVAsset-based `assemble(resolved:)`
  seam (decoupled from Photos) so the export is testable on-device without a Photos library.

**Why it matters**: the same `AVMutableVideoComposition()` + manual-instruction pattern ships in
`VideoStudio` (the B3 clip editor), which was **never device-tested** — so clip-editor *export* is almost
certainly broken on real hardware too. This is exactly the device-gated risk S0 exists to surface before
sinking effort into S2+.

**Rules out / next**: do **not** start S2 (filters/transitions/keyframes) until the videoComposition
export works on-device — they all ride the failing transcode path. Next task: fix the export (try
`AVMutableVideoComposition(propertiesOf:)` as the base; else a custom `AVVideoCompositing` +
`AVAssetReader`/`Writer` pipeline), apply the same fix to `VideoStudio`, and flip the S0 spike from
`skip` to a timing assertion.

**RESOLVED same day — verdict is GO.** The -11838 root cause was **an empty audio track**, not the
`AVMutableVideoComposition` per se: `StudioComposer.assemble` added an audio track up front, and a source
with **no audio** (the synthetic test clip, and any audio-less real video) left it 0-duration, which the
on-device videoComposition export rejects (passthrough tolerates it). Ruled the rest out one device run
each (preset, pixel format, color tags, bare-vs-propertiesOf init, 1-vs-4 clips). **Fix**: create the
audio track **lazily** (only when a clip has audio); also kept the one-layer-instruction-per-track fix and
switched to `videoComposition(withPropertiesOf:)`. **Transform export now works on-device at ~0.2x
realtime** (a 4 s clip ~0.76 s). **Correction**: `VideoStudio` (clip editor) **already** adds audio
lazily, so it was never broken — only `StudioComposer`. **Verified**: the S0 spike now PASSES on-device
(asserts both the stitch and the transform/videoComposition export); full unit suite 184 green (1 skipped,
on the sim). **S2+ (filters/transitions/keyframes) is unblocked** — no export-mechanism blocker remains.

## [2026-06-03] Full studio S1 shipped — multi-clip StudioProject + editor (sim-verified)

**Decision**: Built Track S **S1** (the full CapCut-style studio's foundation) as verifiable layers,
deliberately keeping the pixel pipeline honest:
- **Pure, unit-tested core** (no device): `StudioProject` `@Model` (multi-clip timeline — TimelineClips
  with trim/speed/crop/filter/Ken-Burns keyframes, transitions, overlays, audio tracks, canvas
  aspect/background); `StudioGeometry` (timeline placement with transition overlaps, clip durations,
  keyframe interpolation); `StudioProjectEditor` (snapshot edit ops) + a generic `UndoStack`. **31 unit
  tests** (16 geometry + 15 editor/undo) — the two that initially failed caught a real reorder bug
  (reindex was re-sorting by the stale `order`).
- **Device-only render** (`StudioComposer`, build-verified only): generalizes `VideoStudio` to a
  multi-clip composition (sequential trim+speed clips, per-clip orientation+crop on a shared canvas),
  reused for preview + export.
- **Editor UI** (`StudioEditorView` + VM): timeline (select/reorder/split/delete), per-clip
  speed/filter/transition, aspect, text, undo/redo, Export → Share; opened from `SessionDetailView` over
  the session's `StudioProject` (seeded from its video clips). Preview/export show a device-only
  placeholder on the sim.

**Why**: a multi-clip editor can't grow out of the single-clip `ClipEdit` by accretion — it needs a
timeline document + a generalized composer. Making the edit model a value snapshot kept undo/redo and
every edit op **pure and testable without a device**.

**Verified**: iPhone 17 sim — the studio walkthrough opens the editor, renders the two seeded clips in
the timeline, splits one, and undoes it (11c/11d frames); full unit + UI suites green. The UI test caught
a real presentation bug (a `.fullScreenCover` on a Group-of-Sections inside a List never presents — moved
it onto the launching Button).

**Deferred (S2+, device-only, gated by the S0 profiling spike — NOT built)**: the custom
`AVVideoCompositing` that actually *renders* filters/LUTs, transitions, keyframed overlay effects,
captions, and masks; Ken-Burns photos; the audio mix. The `StudioProject` model already carries all of
this intent — only the compositor pass is pending. **Rules out** writing that compositor blind: it can't
be sim-verified, and device verification is itself blocked on Xcode signing setup (no Apple ID / profiles
yet — `feat/live-workout-per-set-media` builds for the sim but a device install needs the team account
added in Xcode).

## [2026-06-03] Per-set media + full CapCut studio — direction set (design only, no code yet)

**Decision**: Extend the live-workout-studio initiative with two user-requested capabilities, captured
as a design review in [`pdd/prompts/features/live-workout-studio/DESIGN-full-studio.md`](../prompts/features/live-workout-studio/DESIGN-full-studio.md)
(decomposed into a Track M + Track S prompt chain). Three forks were resolved by the user (2026-06-03):

- **"Side" = each set**, with reassignment + a non-set **General** bucket. Media gets *set-scoped* on top
  of session-scoped: additive `assignedExerciseID` / `assignedSetIndex` / `assignmentSourceRaw` on
  `SessionMedia` (lightweight migration; existing rows fall into General). A set is referenced by
  `(SessionExercise.id, setIndex)` — **not** a new `SetLog.id` — because `SetLog` is a positional Codable
  value and a `Codable` default-UUID id mints fresh ids on each decode of old data until re-saved (a
  silent-break migration hazard). Auto-assignment is a **pure, unit-tested** function
  (`SessionMediaAssignment`, the `SessionHighlightInput`/`ClipEditGeometry` edge pattern): a clip is
  assigned to the set whose `(prevCompletion, thisCompletion]` interval contains its offset; a rest-period
  clip belongs to the set just completed. A `manual`/`general` provenance flag makes user choices sticky
  against re-runs.
- **Full CapCut parity** for the editor. The current single-`ClipEdit` editor **cannot** reach parity by
  accretion; it's superseded by a `StudioProject` timeline document (multi-clip main track + overlay/audio
  tracks + transitions + keyframes), a custom `StudioCompositor: AVVideoCompositing` (Core Image/Metal) for
  filters/LUTs/transitions/masks, and an incremental-recomposition preview for smoothness. `B3`'s
  single-clip behavior survives as the one-clip-project case. **GO, fully on-device** (AVFoundation + Core
  Image + Vision + Speech), no backend — the only real risk is multi-clip+effects export/preview perf,
  gated by an **S0 device profiling spike** before committing compositor depth.
- **Capture = library auto-discover + PHPicker** (no in-app `AVCaptureSession` camera this round) — so the
  set is *inferred* from capture time, which is exactly why M1 is a pure assignment algorithm with
  manual-override.

**Why**: closes the two real gaps the user hit — media is session-scoped (no per-set link) and the editor
is single-clip — while reusing the proven non-destructive / pure-math-at-the-edge pipeline and keeping
`HighlightEngine` untouched.

**Rules out**: per-rep/per-exercise granularity (chose per-set); a `SetLog.id` FK this round; in-app camera
capture this round; growing `ClipEdit` into a multi-clip model (a new `StudioProject` instead); any
cloud/off-device render (unchanged hard constraint).

**Implemented same day (Track M — per-set media)**: shipped `SessionMediaAssignment` (pure, Foundation-only)
+ additive `SessionMedia` assignment fields; rebuilt `SessionDetailView`'s gallery into per-set groups +
a General bucket with a per-clip **Move to…** reassignment menu (sticky `manual`/`general`, reconciled on
appear / after discovery); extended `StudioDemoSeed` with spaced per-set completions + 4 synthetic clips
(3 sets + General) for the walkthrough. **Verified on the iPhone 17 sim**: full unit suite green incl. the
new `SessionMediaAssignmentTests` (7 cases), **all 16 UI cases across 12 classes green** (incl. the studio
walkthrough, which now captures the grouped gallery + the reassignment menu), `HighlightEngine` unchanged.
A screenshot walkthrough video was produced (`docs/walkthroughs/per-set-media-studio-walkthrough.mp4`).

**Still design-only / unproven (Track S — full CapCut studio)**: the `StudioProject` timeline, custom
`StudioCompositor`, filters/transitions/keyframes/captions are **not** built — they're device-only and
gated by the S0 profiling spike (can't be honestly sim-verified, so deliberately not faked in the
walkthrough). That is the next executable step.

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

## 2026-06-05 — All development goes through the PDD layer (standing process decision)

**Decision**: Every change to Snappet Mobile — features, fixes, spikes — is driven through this
repo's **Prompt-Driven Development** layer (`pdd/`), per the user's standing instruction. Concretely:
author/commit a feature prompt from `pdd/prompts/templates/feature-prompt.md` (one prompt = one job =
one PR) **before/with** the implementation; keep `pdd/context/` (project / conventions / decisions /
schema) true to reality in the same change; and record any non-obvious choice in this file the same
day. The committed prompt is part of the codebase and ships alongside the output it produced. **Why**:
the prompt is the spec and the review surface; without it, intent and rationale drift out of the repo.
**Rules out**: landing code with no committed prompt; deferring the decisions/context update to "later".
Also mirrored as a standing instruction in `CLAUDE.md`.

## 2026-06-05 — Kilter Board UX pass: adopt system-connected board, swipe-to-browse, QR climb share

**Decision**: Three user-reported UX gaps in the Kilter mini-app, all authored under the PDD prompt
`pdd/prompts/features/kilter-board/UX-connection-swipe-qr.md`.
**(1) Connection — adopt a system-connected board.** `KilterBoardController.connect()` now runs
`beginConnect()`, which first tries `retrieveConnectedPeripherals(withServices:[serviceUUID])` and, if a
board is already connected at the **system** level (paired in Settings, or held by the official
Aurora/Kilter app), connects to it directly via a shared `connect(to:)`; only if none is found does it
fall back to the name-matched scan. Such a board has **stopped advertising**, so the scan-only path
could never re-discover it — the reported "won't connect, but it connects in the Kilter app" case, after
which our flow never reached `.connected` and so never offered illumination. **(2) Auto-light.** When a
board is connected, the detail view illuminates the on-screen holds automatically — on connect
(`.onChange(of:board.isConnected)`) and on each swipe (end of `load()`) — keeping the manual "Light up
this climb" button for a re-send. **(3) Swipe-to-browse.** `KilterClimbDetailView` takes the browsed
list's ordered uuids (`siblings`, passed from `KilterRootView` at push time — no `NavigationPath`
bloat) and tracks a `currentUUID`; a horizontal `DragGesture` + chevrons + a "n / total" pill move
through it, reloading via `.task(id:)` without growing the nav stack. **(4) QR share.** A pure
`KilterClimbLink` codec (`snappet://kilter/climb/<uuid>?angle=<n>`) backs `KilterShareView` (CoreImage
QR + `ShareLink`) and `KilterScannerView` (`AVCaptureMetadataOutput`, reached from the catalog's More
menu); a scanned link pushes the climb. **Offline by design** — both phones ship the same read-only
catalog, so a `climb_uuid` resolves locally with no account/network. **Scope (with user)**: in-app
scanner **only** this pass — no `snappet://` URL scheme / `onOpenURL` cross-app deep link yet.
**Why**: `retrieveConnectedPeripherals` is the canonical CoreBluetooth fix for "another app/Settings
holds the peripheral"; keeping the share payload a pure value type keeps the camera/CoreImage edges
thin and the codec unit-testable. **Rules out**: a scan-only connect path; carrying the sibling list
inside the route value; a networked share. **Verified**: `KilterDeepLinkTests` covers the codec
round-trip + foreign-code rejection (no device). The BLE adopt path and the camera path stay
**device-unverified** per the device-only rule — `xcodebuild` + a real board/camera run is deferred to
macOS (authored on Linux/cloud). Android mirror is a follow-up.

## 2026-06-05 — Kilter rich session: HR + per-climb timing + media reel + Live Activity (workout parity)

**Decision**: Bring the WorkoutTracker's live-session toolkit to a Kilter board session, in one PR
(prompt `pdd/prompts/features/18-ios-kilter-rich-session.md`), by **reusing** rather than rebuilding.
**(1) Decouple the metrics layer.** The sources only read `startedAt` + an `HKWorkoutActivityType` from a
`WorkoutSession`, so I lifted those into a tiny `LiveMetricsContext` and changed the `MetricsSource`
protocol's `start(for:)` → `start(_:)`. `LiveMetricsCoordinator` keeps a `start(for:sport:category:)`
**convenience overload** (building the context via `WorkoutActivityMapping`), so the two workout call
sites — and the existing test — don't churn; the only internal change is the coordinator forwarding
`active.start(context)`. `MetricsSource.swift`/`LiveMetricsCoordinator.swift` gain `import HealthKit`
(`HKWorkoutActivityType` is a plain enum) — the engine stays platform-free. **(2) Separate Live Activity
contract.** A new `KilterActivityAttributes` (board + current-climb/grade/count/angle/HR) rather than
overloading the exercise/set-shaped `WorkoutActivityAttributes`, with a dedicated
`KilterLiveActivityController` + `KilterLiveActivity` widget, so the workout activity path is untouched.
**(3) Reuse `SessionMedia`.** It's already keyed on a bare `UUID`; Kilter rows set `sessionID =
KilterSession.id` and one new optional `assignedClimbUUID` (clip→climb), with the workout-only
exercise/set fields left nil. **(4) Additive models, no new tables.** `KilterSession.hrSeries` is the same
inlined `[HRPoint]` composite the workout uses (reused, not redefined); `KilterLogEntry` gains
`startedAt`/`endedAt`/`attemptTimestamps`; all defaulted → SwiftData lightweight migration,
`SnappetSchema.models` unchanged. **(5) Pure cores.** `KilterSessionStats` (timing/rest/pyramid/sends-per-
hour over plain-value `KilterClimbLog`s), `KilterWorkoutBuilder` + `KilterMediaAssignment`
(`KilterSession`+media → `HighlightEngine.Workout(.climbing)`, clip-offset→climb window), and
`KilterLiveSnapshot.shouldPush` are all device-free and unit-tested. The reel reuses
`engine.generate(for:)` (which auto-selects the `.climbing` preset by `workout.activity`) + `ReelExporter`.
**Why**: the coupling was shallow and the toolkit already on-device; the cheapest correct path was a
seam (`LiveMetricsContext`) + reuse, not a parallel stack. **Rules out**: a Kilter-specific HR transport;
a `KilterSessionMedia` model; overloading `WorkoutActivityAttributes`; widening `WorkoutSession` into a
polymorphic session. **Verified**: `xcodebuild test` green (266 tests incl. the new
`KilterSessionStatsTests` / `KilterWorkoutBuilderTests` / `KilterLiveSnapshotTests` + a `LiveMetricsContext`
rebase test); `HighlightEngine` `swift test` unchanged (18). **Device-unverified** per the device-only
rule: the live HR stream (watch + BLE band), the Live Activity rendering, board connect auto-session-open,
and Photos auto-discovery + reel export — deferred to a real board + watch/HR band on macOS.

## 2026-06-05 — Kilter session media: per-climb galleries, full-length uncapped reels, studio parity

**Decision**: Three user-requested follow-ups on the Kilter rich session, again by **reuse, not rebuild**.
**(1) Full-length, uncapped reels — for *both* workout and Kilter (user's call).** Added
`HighlightConfig.fullClips` (default `false`, so the 18 existing engine tests are untouched) + a
`.fullLength()` copy-helper; when set, `HighlightSelector.select` still uses HR to pick *which* media to
feature (NMS + `maxHighlights`) but emits each as a **full-length** clip (`clipStart = media.startOffset`,
`clipEnd = media.endOffset`) and **collapses repeated moments within one media** to a single segment (so a
video with several peaks yields one full clip, not duplicates). `ReelPlanner.targetDuration` became
`Double?` — `nil` = no length cap. `AppModel.engine` now uses `ReelPlanner(targetDuration: nil)`, and the
single reel call site (`ReelViewModel.generate`) passes `.preset(for: activity).fullLength()`. So the user's
"no length limit" applies everywhere through two app-layer knobs; the engine defaults (and their tests) are
unchanged. **(2) Per-climb media galleries.** `KilterSessionDetailView`'s timeline now renders a horizontal
strip of each climb's clips (filtered by `SessionMedia.assignedClimbUUID`, deduped to the climb's first
timeline row) + an "Unassigned" strip, reusing the already-public `SessionMediaThumb`. A "Move to climb…"
menu reassigns a clip (`assignedClimbUUID` + `assignmentSource`), mirroring the workout reassign. Grouping is
a pure generic helper `KilterMediaGrouping` (unit-tested). **(3) Full editing parity.** The workout
components are domain-agnostic, so Kilter reuses them as-is: tapping a clip opens `ClipEditorView(media:)`
(trim/speed/crop/text/HR-overlay/mute); "Open studio" find-or-creates a `StudioProject(sessionID:
kilterSession.id, …)` and presents `StudioEditorView`; and the reel now goes through the **shared**
`ReelView` (pin/remove/reorder/preview/export) instead of a one-shot export. To make `ReelView` source-
agnostic, `ReelViewModel`'s hard `WorkoutSummary` dependency became a small `ReelSource { id, activity,
title, start, makeWorkout(model, manualMedia) }` — `makeWorkout` takes the `AppModel` as a *parameter* so a
source can be built in a `View.init` (no environment yet); `ReelView(summary:)`/`ReelViewModel(summary:)`
stay as back-compat shims (workout call sites unchanged), and Kilter passes `.kilterSession(session, media:)`.
**Why**: every editor/reel surface is keyed by `SessionMedia`/`StudioProject`/`Highlight[]` with no workout
coupling, so a source seam + reuse beats a parallel Kilter studio. **Rules out**: a Kilter-only reel config
(user chose "both"); duplicating the reel/clip/studio UI; trimming clips by default. **Verified**:
`HighlightEngine` `swift test` 21/21 (3 new: full-clip dedupe + full-length window + nil-budget keeps-all);
`xcodebuild test` 267/267 (new `KilterMediaGrouping` + `ReelSource` coverage); clean build of app + widget +
watch. **Device-unverified**: the clip-editor/studio/reel *render + export* on real footage (needs a device
with clips); the per-climb gallery wiring is type-checked + the grouping is unit-tested.

**Self-review hardening (same day, high-effort multi-agent review of the diff).** Fixed: **(a)** logging
now keeps **one `KilterLogEntry` per climb per session** — repeated logs (attempts, then a send) accumulate
onto a single row (total tries + timestamps; a send is sticky) instead of inserting duplicate rows that
double-counted the climb in the stats/timeline. **(b)** `beginClimb` re-arms when a prior send disarmed the
active climb (and `log` re-arms too), so time-on-climb isn't lost on a re-log. **(c)** `KilterSessionManager`
gained a `didStartMetrics` guard so `end()` only flushes/stops the HR source **it** started — a Kilter
session that opened while a WorkoutTracker workout was running can no longer steal that workout's HR buffer or
stop its source; and `metricsSourceRaw` is now stamped at end **from actually-captured samples** (and shown
as "via Apple Watch / Heart-rate band" in the summary) instead of a misleading default. **(d)** the Kilter
`ReelSource` honors the limited-Photos "Select clips" picks (was a dead no-op) and snapshots Sendable values
(not the `@Model`) to satisfy Swift-6 isolation. **(e)** reused `WorkoutLiveSnapshot.elapsedString` instead
of a duplicate duration formatter. Deferred (noted, not blocking): the `KilterLiveActivityController` /
`KilterActivityAttributes` / `KilterLiveActivity` trio duplicates the workout Live-Activity stack — a generic
parameterized over the attributes type would collapse it, but the split keeps the flagship path untouched.

## 2026-06-05 — Kilter clip editing: per-clip / per-climb scope (shared project), Climb panel

**Decision**: Give Kilter per-clip and per-climb editing scopes **without** a second project or a separate
single-clip editor — one session `StudioProject` + a **visibility filter** is the whole mechanism.
`StudioEditorViewModel` gained `visibleClipMediaIDs: Set<UUID>?` (default `nil` = workout's whole-project
behavior, so the studio is untouched); a pure `StudioGeometry.filterByMedia(_:to:)` restricts the *display,
timeline, preview, and export* to the clips backed by those `SessionMedia.id`s, while the **edit path is
left alone** — `StudioProjectEditor` still mutates the full `snapshot.clips` by clip id. That asymmetry is
the point: a per-clip trim writes to the shared project, so it reappears in "Edit all" and the session-wide
studio automatically (one source of truth). Preview/export read a `scopedSnapshot` (a filtered value copy of
the snapshot), so **`StudioComposer` and `StudioTimelineView` need no changes** — they render whatever the
VM hands them; transitions whose `afterClipID` points at a hidden clip are simply never matched among the
filtered neighbors (graceful; the 1-clip scope has none). Entry points unify in `KilterSessionDetailView`
through one `ClipStudioPresentation` → a single `fullScreenCover`: tap a clip → `{clip.id}` + its climb;
"Edit all · N" (only when a climb has ≥2 video clips) → that climb's clip ids + climb; bottom "Open studio"
→ `nil` scope, no climb. The new `KilterClipStudio` wraps the scoped `StudioEditorView` with a floating
"Climb ✎" button (shown only when a single climb is known) presenting `KilterClimbPanel`, which resolves the
in-session `KilterLogEntry` (the same `(sessionId, climbUUID)` fetch `existingSessionEntry` uses) + the
catalog climb, shows read-only name/grade/board, and write-through-edits angle / result+tries / a new
`note`, plus per-clip "Move clip to another climb" (`assignedClimbUUID`). **`KilterLogEntry.note: String? =
nil`** is additive/defaulted → lightweight migration (the `attemptTimestamps`/`startedAt` precedent),
`SnappetSchema.models` unchanged. **Why**: scoping as a filtered *view* over a shared model keeps edits in
one place and reuses the entire studio + the foundation's `openStudio` reconcile, instead of forking a
per-clip `ClipEdit` editor or copying clips between projects. **Rules out**: a separate single-clip project;
threading a filter through the composer/timeline (the scoped-snapshot copy makes that unnecessary); a Climb
panel coupled to studio-internal selection (the climb is known from the entry point). **Verified**:
`xcodebuild test` — new `StudioGeometryTests.filterByMedia*` (nil passes through, set keeps only matching
`sessionMediaID`, orphan clips excluded, single-clip scope) + `KilterLogEntryTests` (`note` default/round-
trip/mutate); "Edit all" grouping already covered by `KilterWorkoutBuilderTests`. `HighlightEngine` `swift
test` unchanged. **Device-unverified** per the device-only rule: the scoped preview/export render on real
footage and the Climb-panel edits' on-screen feel — deferred to a device with clips.

**Self-review hardening (same day).** Two follow-ups from reviewing the scope filter: **(a)** the studio's
clip **reorder** is made scope-correct — `moveSelected` was indexing the *scoped* visible list while
`StudioProjectEditor.moveClip` reindexes the *full* project, so a reorder in a scoped editor (with hidden
clips before the window) would have mis-ordered the shared session order. A pure
`StudioGeometry.reorderDestination(id:by:visible:full:)` maps a visible-subset move to the full-list index
(swap with the adjacent *visible* neighbor, hidden clips undisturbed; unscoped it's the plain `index+delta`),
unit-tested. The reorder UI is currently dormant, so this is a latent-bug fix, not a behavior change. **(b)**
An **unassigned** single clip can now be tagged to a climb from inside the scoped editor: `KilterClimbPanel`'s
`climbUUID` became optional (nil ⇒ an "Assign clip to a climb" action only), and `KilterClipStudio` shows the
floating button for any per-clip scope and resolves the climb **live** from the clip's `assignedClimbUUID`
(reading the `@Model` clip) — so assigning upgrades the button/panel to the full Climb panel in place,
without reopening. Previously an unassigned clip's only reassignment path was the gallery long-press menu.

## 2026-06-05 — Studio overlays & grids: climb-name overlay, overlay timeline, per-axis PiP grids; split grade filter (P21)

Four editor/browse improvements (prompt `21-ios-studio-overlays-grids.md`), built on the existing overlay
seams rather than new infrastructure. **(1) Grade filter split** — the Kilter browse bar's one "Grade" chip
(a From+To `Menu`) became **two independent chips** (`kilter.minGrade` / `kilter.maxGrade`) over the same
`gradeScale`, with `.onChange` coupling (set Min above Max ⇒ Max follows, and vice-versa). No model/query
change: state stayed `@AppStorage minGrade/maxGrade` and `KilterCatalog.list` already min/max-swaps. **(2)
Climb-name overlay** reuses **one** `OverlayItem` with a new `Kind.climbName` (not a separate config like
`HROverlayConfig`) — deliberately, so the new overlay timeline + the existing opacity keyframes/drag apply to
it for free; it renders like text but as a lower-third chip (export: `StudioOverlays.climbNameLayer` = a
`CATextLayer` on a rounded background container, time-gated by the same `applyVisibility`; preview: a
`.climbName` chip case). The caption is built by a **pure** `KilterClimbCaption.caption(name·grade·angle[·
by setter])` and the text stays freely editable ("Edit text"); a "Show setter" toggle re-derives it. Climb
metadata is resolved **without the SQLite catalog** for name/grade/angle — from the persisted
`KilterLogEntry` keyed by `(sessionId, climbUUID)` (the clip → `SessionMedia.assignedClimbUUID` lookup) — and
only the **setter** touches `KilterCatalog.shared.climb(uuid)` (nil on the simulator ⇒ caption simply omits
it). **(3) Overlay timeline** — every overlay already had `[startSec, endSec]`, so duration control is a
second lane in `StudioTimelineView` (`OverlayBar`: high-priority body-drag to move the whole window keeping
its length, edge handles to trim) sharing the clip lane's `pps`/offset, committing once on drag-end via the
pure `StudioProjectEditor.setOverlayTimeRange` (clamped, min 0.2s); selection is shared with the bottom
overlay controls. **(4) PiP grids** — PiP went from a single uniform `scale` to optional **per-axis**
`OverlayItem.normalizedWidth/Height` (a `pipSize` accessor falling back to `scale` when nil, so old
snapshots decode and render **unchanged**), enabling true split-screen cells and free corner resize. A new
`ClipEditGeometry.pipRect(center:size:canvas:)` overload (the `scale` one delegates to it) feeds both the
preview frame and `StudioComposer.insertPiPTrack`. A **pure** `StudioGridLayout` provides collage `Preset`
cells (1×2 / 2×1 / 2×2 / 1×3 / 3×1) and `snap(center:size:)` → alignment guides (rule-of-thirds / centre /
edges); `StudioOverlayCanvas` gains corner-resize handles (opposite corner fixed) + live guide drawing, and
a "Grid" tool sheet exposes the presets + a snap toggle. **Why**: extending `OverlayItem` (one new kind, two
optional fields) keeps the timeline/keyframe/undo machinery uniform across text/climb-name/PiP and avoids a
parallel config type or a forked editor; per-axis size is the minimal model change that satisfies both
"split-screen grids" and "corner resize". **Rules out**: a dedicated `ClimbNameOverlayConfig`; baking the
caption into a fixed string (it stays editable); a normalized `CGRect` field on `OverlayItem` (two optional
scalars decode more cleanly for SwiftData lightweight migration). **Verified**: new pure unit tests —
`KilterClimbCaptionTests` (setter on/off/missing, empty name/grade/zero-angle), `StudioGridLayoutTests`
(preset cells tile the canvas, `frames(count:)` caps at capacity, snap within/outside threshold + edge
snap), `ClipEditGeometryTests` (per-axis `pipRect`), `StudioProjectEditorTests`
(`setOverlayContent`/`setOverlayTimeRange`/`setOverlayFrame`/`applyPiPGrid`). **Device-unverified** per the
device-only rule: the climb-name **export** layer, PiP collage/corner-resize on real footage, and the
overlay-lane gesture feel — deferred to a device with clips + a logged Kilter session.

## 2026-06-05 — Studio overlay/PiP follow-up: live-resize, text sizing, base-video collage cell, flicker fix (P21)

Device pass on P21 surfaced four issues; fixes built on the same seams. **(1) Text/climb-name couldn't be
resized** — the export AND preview already honoured `OverlayItem.scale` for font size, but no control ever
set it for the Core-Animation kinds (handles were `.video`-only). Fix: a **Size slider** in the overlay
controls bar + **pinch-to-scale** on the canvas (`TextOverlayChip`), both → `setOverlayScale`, which is now
overlay-aware in the VM (text = `editOverlaysOnly`, no player rebuild) and whose clamp **widened `0.1…1` →
`0.2…6`** so text can grow past 1× (the old clamp was sized for a PiP frame fraction; PiP sizing moved to the
per-axis `setOverlayFrame` in P21, so widening is safe). **(2) PiP frame "didn't match the bounding box"** —
corner-resize only wrote the model on drag-END (`commitResize(ended:false)` updated only the snap guides), so
the white outline + the composited PiP stayed put while the handle moved, then jumped on release. Fix: a
shared **`ResizableFrame`** view (used by BOTH the PiP cell and the new base-video cell) tracks the gesture
**live** via `liveResize` state — the outline and all four handles recompute from the in-progress
corner/pinch each frame; the model is still written once on end. Handles dropped their local `.offset` (the
parent repositions them from the live frame, so the dragged dot sits under the finger). **(3) "Very
flickery"** — every PiP edit ran `rebuildPreview`, which tore down the whole `AVPlayer` AND re-resolved every
PHAsset→AVAsset through `PHImageManager` (slow/async) → a black flash + reload per nudge. Fix: an **actor
`AssetCache`** in `StudioComposer` memoizes resolution for the session, and `rebuildPreview` now **reuses the
player** (`replaceCurrentItem`) instead of constructing a new `AVPlayer` (no layer detach/reattach), keeps
playing across a live edit, and a **generation token** drops a stale rebuild whose async composition returns
after a newer one. **(4) Couldn't resize the original video** — the main track always aspect-filled the full
canvas. Added an optional **`StudioProject.baseFrame: StudioFrameRect?`** (normalized centre+size, nil =
legacy full-frame, migration-safe additive `@Model` property like `hrOverlay`); the composer's new
`mainClipTransform` aspect-fills the main track into that sub-rect (same flipped-Y / `pipRect` convention as a
PiP, so base + PiP cells align; the canvas `background` shows behind it) on **both** the single-track and
transition paths. On the canvas it's a draggable "Main" `ResizableFrame`; the **Grid tool** gained a "Resize
the main video" toggle (`toggleBaseFrame`, default = a centred half-cell) and the Grid button is no longer
PiP-gated. **Why a frame on the project, not a per-clip field or a `.baseVideo` overlay kind**: framing is a
canvas-level layout (all clips share it), and a new overlay kind would ripple through every overlay switch +
the export tool; one optional struct is the minimal, migration-safe change and reuses the PiP geometry.
**Rules out**: per-clip base frames; crop-WITH-base-frame (a framed main track ignores per-clip crop — a
follow-up); base video as a grid-preset cell (presets stay PiP-only). **Verified**: builds clean + full suite
green on the simulator (298 unit tests) — `setBaseFrame`/`clearBaseFrame` clamp+toggle, `StudioFrameRect.isFull`,
the widened `setOverlayScale` clamp. **Device-unverified** (device-only rule): the actual flicker-free feel,
base-frame **export** on real footage, and pinch/Size sizing of the climb-name in the rendered file.

## 2026-06-05 — PiP/base placement: top-left render space + aspect-FIT + source-aspect default (P21)

A device screenshot showed the composited PiP **offset down** from its editor outline AND **wider than
the frame**. Root-caused to two composer bugs in `insertPiPTrack` / `mainClipTransform`. **(1) Wrong Y
origin** — the PiP frame flipped Y (`1 - normalizedY`) assuming the `AVMutableVideoCompositionLayer
Instruction` render space is bottom-left (the convention the Core-Animation OVERLAY tool genuinely uses,
`layerPoint`). But the layer-INSTRUCTION space is **top-left** — proven by the device-verified
`cropTransform` (clip-editor zoom-crop), which targets the same space and does NOT flip. The flip pushed
the PiP down by `(1−2y)·H`, matching the screenshot. Fix: drop the flip, place against `ov.position`
directly (top-left), so the composited PiP lands exactly where the SwiftUI outline shows it. **(2)
Overflow** — `fillTransform` aspect-FILLS (cover), but a layer instruction can't clip its track to a
sub-rect, so the excess spills past the frame onto the rest of the canvas. Fix: a new
`ClipEditGeometry.fitTransform` (aspect-FIT / contain) keeps the whole source inside its frame; PiP and
base both use it. **(3) Square default** — a new PiP defaulted to a `0.4×0.4` (canvas-aspect) frame, so a
non-9:16 source letterboxed inside it (looks misaligned). Fix: `addPiP` sizes the frame to the source's
oriented aspect (`StudioComposer.sourceAspect`, resolved on appear into `sourceAspects`), so
`pipSize.w/pipSize.h = sourceAspect / canvasAspect` and the aspect-fit PiP fills its frame. **Why top-left,
not bottom-left**: the two render spaces (layer-instruction vs the Core-Animation overlay tree) genuinely
differ; the original code conflated them. Matching `cropTransform` (verified) is the reliable tiebreak.
**Why fit, not fill+crop**: precise per-PiP cropping needs a mask layer (custom `AVVideoCompositing`),
deferred; fit is the no-overflow, no-mask choice. **Rules out**: a bottom-left flip for PiP/base; aspect-
fill without a clip; a fixed square PiP default. **Follow-up**: when a user resizes a PiP frame to an
aspect ≠ its source, the video fits within (a small letterbox) — drawing the outline at the exact fitted
rect (needs the source aspect in the canvas) is a further polish. **Verified**: builds clean, full suite
green incl. a new `fitTransform` containment test. **Device-unverified**: that the PiP/base now sit exactly
under the outline in preview AND export.

## 2026-06-07 — Kilter board: size on the climb page, size-accurate render, color-blind hold shapes

Three board-design improvements on the climb screen, one PR (iOS + Android mirrored;
`FEAT-board-size-render-and-colorblind-shapes`). **(1) Board size beside Layout** — the physical
board-size preference (`kilter.productSizeId`, added by `FIX-board-size-led-mapping`) was only reachable
in Settings and the inline "wrong holds?" escape hatch. It's now an inline **Size chip** on the browse
filter bar (iOS `KilterRootView`, Android `KilterRoot`), shown only when the layout offers >1 size,
bound to the same cached key, **seeded to the layout default on appear and reset when the layout
changes** (the guard Settings already used, lifted into a `syncBoardSize()` / `LaunchedEffect(layoutId)`
so the chip and Settings can't disagree). **(2) The render now tracks the size.** Previously
`boardGeometry(forLayout:)` took the extent + grid from the **whole layout's** hole set and `holds()`
normalized to that same extent, so *every* size of a layout drew an identical schematic — size only
changed which LEDs lit. New `renderHoles(forLayout:sizeId:)` computes the render basis from the holes
**wired for the selected `product_size`** (the `leds` table's hole keys ∩ the layout's placements — that
set *is* the physical board's holes, so a 7×10 ≈ 225 holes reads shorter than a 12×14 ≈ 527). Both
`boardGeometry(forLayout:sizeId:)` and `holds(for:sizeId:)` normalize to that one basis, so the grid +
aspect + lit holds reshape **together**; a hold above a smaller board clamps onto its top edge. `sizeId
0` (the default, for any legacy caller) and a size with no `leds` rows fall back to the whole layout, so
older/hand-rolled catalogs degrade rather than crash. The detail screen recomputes geometry+holds when
the size changes (moved to a top-level `onChange` so it still fires with no board / on the simulator,
where the BLE-gated section is unmounted). **(3) Color-blind hold shapes.** Every lit hold was a circle,
so the route was unreadable without separating the role *hues*. A pure `KilterHoldShape.forRole` now
maps the four roles to the canonical grayscale-distinguishable set — **start = triangle, hand = circle,
finish = square, foot = diamond** — drawn (stroked unlit / filled+glow lit) by `KilterBoardView` /
`KilterBoard` via a shared `holdPath`; colors are kept (shape is a *redundant* channel), the grid dots
stay faint circles, and the detail legend draws the shapes (one `holdPath`, so board + legend can't
drift). **Why the LED hole-set, not `product_sizes.edge_*`:** the real Aurora `product_sizes` carries
explicit visible-rectangle edges that would crop pixel-perfectly, but they aren't in the synthetic
fixture (only `id/name/description`) and adding them would churn all four fixture mirrors' positional
inserts; the `leds` hole-set is authoritative, already loaded for LED mapping, present in fixture + real
catalog, and ≈ the visible rectangle. A future catalog that exposes the edges can swap the basis behind
`renderHoles`. **Why no real board photos:** the user asked to "find Kilter layout photos per
size/layout," but the board backgrounds (`product_sizes_layouts_sets.image_filename`) are copyrighted
Aurora CDN assets and the repo ships **no** Aurora data (#42) — committing them is a licensing + policy
violation — so the schematic was made size-accurate instead (decided with the user). **Why always-on
shapes (not a toggle):** shape is strictly more information with no downside for sighted users (decided
with the user). **Fixture:** the two existing sizes are both "5 x 5" and wire all 25 holes, so they
can't *prove* size-accurate geometry — added a third **5×3 "Test Mini"** size wiring only the bottom
three rows (holes 1–15) to all four mirrors (`build_test_fixture.py` + the regenerated
`kilter-fixture.sqlite3` + Swift/Kotlin `KilterCatalogFixture`); the `[1,2] → [1,2,3]` size assertions
moved with it. **Rules out:** bundling/scraping copyrighted board photos; an on-device photo-fetch path
(network — out of scope, contradicts on-device-only); a size toggle for shapes; `product_sizes.edge_*`
cropping (not in the fixture); per-platform shape mismatch (one `forRole` + one `holdPath` each side,
unit-pinned). **Verified (off-device):** new `KilterHoldShape` mapping test (start→triangle … four
distinct shapes) on both platforms; new `boardGeometry`/`holds` size test (full = 25 holes / aspect 1.0,
mini = 15 / aspect 2.0, sizeId 0 + foreign size → whole layout, a top hold clamps to y 0); the prior
LED-address + `led_color` test stays green; the regenerated binary fixture validates (4 climbs).
**Device-unverified** (visual judgments): that the size-coded schematic + role shapes actually read
better for a color-blind climber on a real screen, and that the absence of a real board photo is
acceptable.

## 2026-06-07 — Kilter: "No matching" tag (climbs.is_nomatch) + a board-size download filter

Two more Kilter additions, iOS + Android mirrored. **(1) Matching rule on the climb screen.** The climb
screen never showed whether a climb forbids **matching hands** on a hold (the Kilter "No matching"
setter rule). We **grounded this in the real downloaded data** (the user's instinct after an earlier
wrong guess): inspecting the 165 MB `kilter.sqlite3` showed a dedicated `climbs.is_nomatch` boolean —
73,864 of 344,504 climbs flagged, and **all** of them also carry "No matching"/"no match" in their
free-text `description` (the column is the precomputed version of the setter note; the `hsm` column is
unrelated — a bitmask). So `KilterClimb` now reads `is_nomatch` (added `description` too), and the detail
screen shows an amber `hand.raised.slash` **"No matching"** chip (else a quiet "Matching") — always on,
so the rule is never ambiguous, mirroring the official app's icon. A pure
`kilterDescriptionForbidsMatching` is the **fallback** for catalogs that predate the column — it matches
the setter note at a **word boundary** (`(^|[^a-z])no[ -]?match(ing)?([^a-z]|$)`) so it reproduces
`is_nomatch` for the standard phrasings without firing inside ordinary words ("piano matched", "casino
match", "no matches found"); the column is authoritative when present. Unit-tested (incl. those
false-positive cases). A review caught the original bare-`contains("no match")` substring leak. **(2) Board-size
download filter.** The user's Board Explorer gained a size filter; we mirror its `buildConditions`
exactly: a size is a box `[edge_left, edge_right, edge_bottom, edge_top]` from `product_sizes` (the real
table carries these edges, e.g. 7×10 = `[28,116,36,156]`, 12×14 = `[0,144,0,180]`), and a climb fits
when `c.edge_left >= ? AND c.edge_right <= ? AND c.edge_bottom >= ? AND c.edge_top <= ?`. `CatalogFilter`
gained `sizeId`/`sizeBox`; `KilterBoardSize` now carries its `box`; the download sheet adds a **Board
size** picker. **[SUPERSEDED the same day — see "Kilter download: board-first" below: the picker now reads
from an EMBEDDED known-Kilter board table and works on a first download; the next paragraph describes the
original, replaced approach.]** **Why the picker reads sizes from the INSTALLED catalog (and hides on a
first-ever download):** pre-download the board's sizes aren't known — the ~80 MB file isn't fetched yet and
the host manifest carries no sizes — and embedding Aurora size ids/boxes would duplicate Aurora data (#42).
Once a catalog exists, its `product_sizes.edge_*` supply the picker + the chosen box; the box is bound
straight into the trim's WHERE. **Why a dedicated column over description-parsing for `is_nomatch`:** the column is
authoritative and cheap; parsing free text is a heuristic — so prefer the column, parse only as a
fallback. **Why both newer columns are PRAGMA-guarded:** `climbs.is_nomatch` and `product_sizes.edge_*`
are absent from older/hand-rolled catalogs (and the validator doesn't require them); detect once on open
and degrade (matching-allowed default / nil box / no size filter) rather than throw. **Fixture:** added
`is_nomatch` (Bravo = no-match, with a "No matching" description) and `product_sizes.edge_*` boxes (sizes
1/2 a tall 0…24 box, size 3 a short top-12 box) across all four mirrors. **Rules out:** an in-app
"fits-your-board" tag (that was a misread of "match" — it means hand-matching, not board fit);
embedding static Kilter sizes for the download picker *(reversed the same day — see "board-first" below;
the static table is now the chosen approach)*; using `hsm` for the match rule. **Verified (off-device):**
new tests — `is_nomatch` read + size-box read (installed reader), the size-fit download filter (tall box
keeps all 4 climbs, short box keeps none → `noCatalogData`), and the pure description detector — on both
platforms; regenerated binary fixture validates. **Device-unverified** (visual judgment): the match chip
+ size-filter UX on a real screen.

## 2026-06-07 — Kilter download: board-first, end-user-friendly (layout + size are the only filters)

The in-app catalog download was a 12-field power-user form (board, layout toggles, angle, grade min/max,
ascents, quality, setter, name, benchmark, listed, single-frame, board size, cap, host) — overwhelming
for someone who just wants climbs for their board. Reshaped around the **one thing an end user knows:
which board do you have.** The download sheet (`KilterCatalogDownloadSheet`, iOS + Android) is now: **Your
board** = a single **layout** pick (Original / Homewall) + a **size** pick; **How many climbs** = a simple
cap (Most popular N / Everything); Download; host URL tucked under **Advanced**. **Layout + size are the
only download filters** — they define your physical board. Everything else (angle / grade / quality /
ascents / setter / name / benchmark) moved to **browse-time** (those controls already exist in the
catalog list + Filters sheet); `listedOnly`/`singleFrameOnly` stay on as silent mobile defaults. The
`CatalogFilter` struct is unchanged (still carries the browse-style fields) — `buildFilter` just stops
*setting* them, so they keep their no-op defaults and the explorer-parity `conditions()` is untouched.
**Why size needs a static table:** the size picker must work on a **first** download, when no catalog is
installed and the ~80 MB file isn't fetched — so the well-known Kilter board sizes (layout → sizes with
their `product_sizes.edge_*` fit boxes) are embedded as `KilterCatalogOptions.boards`, pulled from the
**real** Aurora data (re-inspected the 165 MB dataset: Original 7×10…16×12, Homewall 7×10/8×12/10×10/
10×12; Homewall ships each size under several LED-kit ids → keep one per physical box). This is board
**dimensions** — structural reference like the hardcoded layout ids — **not** climb data, so it's
consistent with #42 (we still ship no climb catalog). The chosen size's box drives the trim
(`c.edge_* ⊆ box`); picking a smaller board really does install fewer climbs. **Why a layout single-pick
(not the old multi-toggle):** a physical board is one layout; "your board" is one choice. **Why keep a
cap:** layout 1 alone has ~228k listed climbs — without a cap the installed file is huge; the cap is a
data-size control, not a climbing filter, so it's framed as "how many climbs." **Rules out:** exposing
the climbing filters at download (they're browse-time); reading sizes from the installed catalog for the
picker (doesn't exist on a first download — the prior approach, now replaced by the static table);
multi-layout downloads. **Verified:** iOS `BUILD SUCCEEDED`, Android `compileDebugKotlin` SUCCESSFUL; no
UI test references the removed controls. **Device-unverified** (visual/UX judgment): that the board-first
flow actually reads as simpler on a real screen.

## 2026-06-07 — Kilter browse: live "N climbs" count + Clear (search feedback)

The catalog browse gave no feedback on how a search/filter narrowed the catalog. Added a **live count
bar** under the filter chips (iOS `KilterRootView`, Android `KilterRoot`): "N climbs" updating with the
filter + search, plus a **Clear** action when a search / Saved / Filters-sheet extra is active (it
resets those but keeps the board/angle/grade context the user set). **Why a dedicated `count(filter)`
(not `list().count`):** the browse `list` is capped (LIMIT 500) for render cost, so its size understates
the true match count; `count` runs the same WHERE as `list` (one `climb_stats` row per climb at the
angle → `COUNT(*)`) with no limit/sort, giving the real number. Saved-mode count is just the filtered
favorites' size (already the full set). **Rules out:** counting via `list().count` (capped); a separate
count query path that could drift from `list`'s WHERE (kept them mirrored). **Verified:** new
`testCountReflectsFilterAndSearch` (iOS) / `countReflectsFilterAndSearch` (Android) over the fixture —
count = 4 at 40°, 2 at 25°, 1 for "Bravo"/grade≥22, and equals the uncapped list size; both platforms
build. **Device-unverified**: the live-update feel on a real screen.

## 2026-06-08 — Feature-rich band data, Phase 1: sensor-contact gating + redline/strain + per-climb effort

Made the fitness-band data we **already capture** richer, without new BLE characteristics, a user HR
profile, or cloud (the on-device-only stance from 2026-06-01 stands). Three bpm-only wins:

**Sensor-contact gating.** The `0x2A37` packet already carries a sensor-contact flag we were
discarding. Added `BLEHeartRateMetricsSource.parseMeasurement` (returns bpm + `contact: Bool?`) and
`contactStatus(flags:)`, keeping `parseHeartRate` as a bpm-only **shim** so the existing parser tests
and any callers stay green (additive, no churn). **The bit decode is the load-bearing subtlety:**
Bluetooth SIG flags **bit 2 (`0x04`) = contact SUPPORTED**, **bit 1 (`0x02`) = contact STATUS** — two
independent bits, *not* a 2-bit enum. We gate on support first (unsupported → `nil`/"unknown", never a
false alarm), then read status. A naive 2-bit decode mis-fires on real straps that set status without
support — and the pre-existing `0x0E` fixture (both bits set) would not have caught it (a planning
adversarial-review catch). `ingest` now **drops** a no-contact reading (off-skin bpm is garbage):
don't append, keep the last good `latestHR`, raise `isContactLost`; the live HR pills show an "adjust
strap" hint. `isContactLost: Bool?` is on `MetricsSource` with a `nil` protocol-extension default, so
only the BLE band implements it and the **watch path stays `nil`**. **Trade-off:** while contact is
lost `latestHR` is frozen, so the Live-Activity `onChange(of: latestHR)` push won't fire — acceptable,
and the orange affordance explains the staleness.

**Redline + strain.** `WorkoutHRStats` gained pure `redlineSeconds` (Z4+Z5 dwell), `redlineFraction`
(guarded to `0`, never NaN), and `edwardsTRIMP` (Σ minutes-in-zone × zone-number) — the figures that
characterize a bursty climbing session. **Anchored to the fixed `defaultMaxHR` (190) until a user HR
profile lands, so these are within-user *trend* numbers, not cross-user or clinical** (Edwards TRIMP
was validated for steady aerobic work; intermittent max-effort climbing inflates it).

**Per-climb effort + recovery.** New pure engine helper `ClimbEffort` (HighlightEngine, swift-test'd)
scores one climb's HR window: peak bpm, peak %HRR (**only** with a real `maxBpm` bound → `nil` today,
the honest bpm-only state), HR rise, time-to-peak, HRR60/30 recovery. **Verified fact:**
`KilterBoardController.climbWindows` ends each window at `endedAt` with **no** `hrLagSec` extension and
also feeds media auto-assignment — so it is left untouched; the HR window is computed separately in
`KilterSessionStats` (from each log's own timestamps) and its **end extended by `HighlightConfig.hrLagSec`**
so the post-effort spike that lands just after `endedAt` is captured. A **zero-lag negative-control
test** guards this (with lag 0 the spike is missed). Effort lives as flat optional fields on
`KilterSessionStats.TimelineItem` (keeps Equatable/Sendable auto-synthesis; not persisted, so no
SwiftData migration). The UI (Redline/Strain tiles + per-climb effort badge / recovery dot) is
additive and gated, so HR-less and watch-path sessions render exactly as before.

**Rules out (this PR):** RR-intervals / HRV, energy parsing, battery/device-info reads, and a user HR
profile — all later phases of the roadmap; vendor SDKs / cloud (Whoop/Body-Battery/Polar-PMD) remain
out (brand lock-in + cloud, contra the on-device-generic-BLE stance). **Verified off-device:**
`swift test` (ClimbEffort math incl. the lag-extension control) + the XCTest suite (contact decode &
ingest-drop, redline/TRIMP, per-climb effort). **Device-unverified** (no band/HR in the simulator):
the live "adjust strap" affordance + sample pause on a real strap toggling on/off-skin, and the live
per-climb HR spike on a board.
