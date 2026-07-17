# Prompt: Festival mini-app shell + hosted lineup install (festival prompt 02)

**File**: pdd/prompts/features/festival/02-festival-shell-and-install.md
**Created**: 2026-07-16
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData) — code lands in this repo, plus a
**companion PR on the web-app repo** (the `music-festivals/` packs page).
**Chain**: `pdd/prompts/features/festival/README.md` → 02 of 06 (prompt 01 MERGED #292 — build on
its domain, do not modify the wire format or confidence semantics)
**Source**: user ideation session 2026-07-16; wireframes `docs/ux-research/festival/wireframes.html`
frames 1–5 (later frames are prompts 03–05 — do NOT build tag review / Clips payoff /
notifications / QR / recap here)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make the Festival domain **reachable**: an `AppModule` in the App Library (UV-orchid accent), the
Kilter-shaped catalog install (empty state → hosted browse → provider→validator→store), the
installed festival's **day schedule** (★ stars, clash marks, the NOW set), and the **"I'm here"
live sheet** that puts being-at-a-set on the dance-discipline `WorkoutSession` spine. Why now:
prompt 01 shipped a fully-tested pure domain with no way in; every later prompt (tagging, plan,
QR) hangs surfaces off exactly these screens and rows.

## Context the implementer needs

- **Prompt 01 is law.** `FestivalPack.decode` is the ONE decode entry point (it stamps UUIDv5
  content ids); `.fpack` = `"FPAK"` + version byte + **raw-DEFLATE** JSON via the shared
  `ZlibCodec` — *not* gzip, *not* zlib-wrapped (decisions.md 2026-07-16). Whatever the web repo
  publishes must be produced in that exact form or `decode` rejects it as `corrupted`.
- **Mini-app conventions** (`conventions.md` §Adding a mini-app): descriptor enum, two central
  edits (`ModuleRegistry.all`, `SnappetSchema.models`), SwiftData `@Model`s with UUID/string FKs +
  backup Rows in the same change (the `SnappetBackupTests` tripwire fails until you do), root view
  pushed into the App Library's stack — **never** a module NavigationStack or bottom bar (the
  Wardrobe rule). Sheets may carry their own stack.
- **Precedents to mirror**: `KilterAuroraSync.swift` + `KilterCatalogProvider.swift` (the
  provider→validator→installer funnel, `kilterDefaultCatalogHost`, manifest.json, the one-GET
  legal posture), `KilterCatalogSyncView` (the opt-in empty state: download leads, file import
  beneath, honest data card), `WorkoutHomeView` / `KilterSessionManager` (session lifecycle: flush
  HR before stop, never steal a running source, Live Activity start/end).
- **`WorkoutDiscipline.dance` already exists** (Workout-Type Parity) and
  `WorkoutActivityMapping` sends it to the watch as `.cardioDance`; a dance entity is the
  freeform `addOpenEffort` shape (`.duration` kind + `disciplineRaw`). No discipline work needed.
- The pack host is `https://harshal2802.github.io/Snappet/music-festivals/` (sibling of
  `board-data/`) — it does not exist until the companion web PR deploys, so the hosted fetch is
  verified against fixture bytes + a wire-compat fixture of the real published pack.

## Approach

All UI in `ios/App/Snappet/Features/Festival/`, pure logic separated from thin edges:

- **`FestivalModule.swift`** — id `"festival"`, Lifestyle, `music.mic`, UV-orchid accent
  (`SnappetColor.festival`, light `0xB03AC2` / dark `0xD96BE8` — confirm against the ramp).
- **`FestivalModels.swift`** — three `@Model`s (CloudKit-compatible shape): `FestivalLineup`
  (the verbatim `.fpack` bytes + denormalized display fields, keyed by the pack-author `packID`;
  replace-on-reinstall), `FestivalStar` (packID + set content-id per row), `FestivalAttendance`
  ("I'm here" stretch: setID + interval + `WorkoutSession` FK — exactly the matcher's
  `FestivalSessionHint` for prompt 03). Backup Rows for all three in `SnappetBackup`.
- **`FestivalCatalogProvider.swift`** — `festivalDefaultCatalogHost`, manifest types, pure
  `FestivalBrowse` (row-state mapping, search/year filter, meta-line), `FestivalPackProvider`
  protocol yielding **Data** (packs are tens of KB), `HostedFestivalPackProvider` +
  `FestivalFilePackProvider`, and the `FestivalLineupInstaller` funnel (fetch → decode → validate
  → row) with an observable phase.
- **`FestivalCatalogViews.swift`** — the empty state (frame 2) + the browse sheet (frame 3:
  searchable rows, year chips, GET/progress/✓, Advanced host override).
- **`FestivalSchedule.swift`** — PURE derivation for frame 4: festival-local day tabs, stage
  groups with past/NOW/upcoming rows, clash ids via `FestivalPlan.clashes`, the "I'm here"
  candidate (starred beats most-recently-started), up next, and every label (`now` is always a
  parameter — no `Date()` inside).
- **`FestivalRootView.swift`** / **`FestivalScheduleView.swift`** / **`FestivalLiveSheet.swift`**
  — thin renders. The schedule view owns the dance-session edge: claim = close any other open
  attendance → ride the active `WorkoutSession` if one is live (never stack a second) else start
  one (+ live HR + Live Activity, guarded like `resume`) → append a dance entity
  ("Artist · Stage") → insert the attendance row. End-the-night finishes the session ONLY when
  festival-owned (content check: routineless + all `festival-set` entities) — mirroring
  `finishWorkout` (flush HR → stop → end activity → `completedAt` → Recap log). The live sheet
  reuses `KilterHRPill` + `RecordClipButton` (clips also attach as `SessionMedia` through
  `SessionMediaService.candidate`), and offers Switch set / End the night.
- **`FestivalLineupSeed.swift`** — `-uiTestSeedFestivalLineup` (implies fresh store): a synthetic
  lineup whose **UTC offset is chosen so festival-local `now` ≈ 18:00**, so the NOW pill and live
  sheet are exercisable at any wall-clock time without fighting the 06:00 rollover validator.
- **Web repo companion PR**: `music-festivals/` (manifest.json + ≥2 real starter packs built by a
  reproducible `scripts/build-fpack.py` emitting the exact FPAK/raw-DEFLATE form + an index page);
  pin the published bytes here as `FestivalPackWireCompatTests`.

## Output

- `ios/App/Snappet/Features/Festival/` — `FestivalModule`, `FestivalModels`,
  `FestivalCatalogProvider`, `FestivalCatalogViews`, `FestivalRootView`, `FestivalSchedule`,
  `FestivalScheduleView`, `FestivalLiveSheet`, `FestivalLineupSeed`
- Central wiring: `ModuleRegistry`, `SnappetSchema`, `SnappetBackup` (+Rows), `SnappetColor`
  (festival accent), `SnappetApp` (seed arg)
- Tests: `FestivalScheduleTests`, `FestivalBrowseTests`, `FestivalInstallerTests`,
  `FestivalLineupSeedTests`, `FestivalPackWireCompatTests` (real published bytes),
  `SnappetBackupTests` seeding grows the three festival models
- `ios/App/SnappetUITests/FestivalUITests.swift` — empty state/browse + schedule/★/clash/live
  sheet walkthroughs
- `docs/knowledge-graph/data.js` — festival module/screens/sheets/service/models + edges
  (App Library, hosted-pack flow, the dance-session spine)
- `pdd/context/decisions.md` — same-day entry (accent confirmation, session-ownership rule,
  seed-offset trick, anything non-obvious)
- Web repo PR: `music-festivals/` packs + builder + page (opened, not merged)

## Acceptance criteria

- [ ] Festival tile appears in the App Library (Lifestyle) and pushes a root with NO module
      NavigationStack/bottom bar.
- [ ] Fresh install shows the opt-in empty state; browse renders the hosted manifest; a pack
      installs through decode→validate→store and a malformed/foreign file surfaces the
      validator/codec message verbatim with nothing half-installed.
- [ ] Reinstalling a festival replaces its row (same `packID`); stars survive (content ids).
- [ ] Schedule shows festival-local day tabs + stage-grouped rows; the live set glows NOW; ★
      toggles persist; starring two overlapping sets flags BOTH rows; back-to-back doesn't.
- [ ] "I'm here" starts a dance-discipline `WorkoutSession` (or annotates an already-active one —
      never a second concurrent session), records a `FestivalAttendance` stretch, and the live
      sheet shows artist/countdown/live HR/record-clip/switch/end.
- [ ] End-the-night finishes only a festival-owned session (flush HR, Live Activity ends, Recap
      logs it); a gym session festival merely annotated keeps running.
- [ ] The REAL published `.fpack` bytes decode through `FestivalPack.decode` +
      `FestivalPackValidator` (wire-compat fixture test).
- [ ] Unit suite green; full XCUITest suite green (this PR has real UI); app target builds with
      0 warnings (Swift 6). `HighlightEngine` untouched.
- [ ] `decisions.md` + knowledge graph updated in the same change.

## Constraints

- Do not touch prompt 01's wire format, confidence semantics, or `HighlightEngine`.
- No notifications, no tag review, no Clips post titling, no QR, no recap (prompts 03–05).
- Network egress = ONE user-initiated GET per manifest/pack to the configured host; nothing
  uploaded; offline forever after install.
- Verification honesty: the hosted fetch against the LIVE host + watch-HR during a real set are
  device/deploy legs — state them as owed, not verified.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — schedule/browse/installer/seed/wire-compat +
   the backup tripwire.
2. `make ios-test SIMULATOR='iPhone 17 Pro'` — full suite incl. `FestivalUITests` (empty state /
   browse chrome; seeded schedule → star/clash → I'm here → live sheet → switch → end).
3. Web repo: `python3 scripts/build-fpack.py` self-checks each pack; the published bytes are the
   iOS fixture. After the web PR deploys: on-device browse → GET Glastonbury → schedule renders
   (the owed leg).
