# Prompt: Kilter — opt-in, on-device catalog (ship zero bundled climb data)

**File**: pdd/prompts/features/22-kilter-opt-in-catalog.md
**Created**: 2026-06-05
**Project type**: Native iOS + Android feature (Swift / SwiftUI · Kotlin / Compose) — code lands in this repo.
**Chain**: Kilter Board mini-app (#35) → follow-up that resolves #32 OQ#11.2.
**Source**: GitHub issue [#42](https://github.com/harshal2802/snappet-mobile/issues/42)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Remove the legal exposure of **redistributing Aurora Climbing's proprietary climb catalog** inside the
app. The bundled `kilter.sqlite3` (iOS `Resources/`, Android `assets/`) is deleted and replaced with an
**opt-in, on-device catalog fetch**: the app ships **zero** Aurora climb data, and each user brings the
catalog onto their own device (Phase 1 = importing a `.sqlite3` they built themselves). This is the
architectural fix for #32 open question 11.2 ("redistribution license must be resolved before shipping")
— it ships *without* waiting on a permission negotiation, which stays as complementary future scope.

## Context the implementer needs

- The read layer is **reused unchanged**: `KilterCatalog` (iOS `Features/Kilter/KilterCatalog.swift`,
  Android `feature/kilter/KilterCatalog.kt`) opens a SQLite file read-only and already degrades to
  `isAvailable == false` on a missing/corrupt DB. Today it opens the **bundle/asset**; the only change is
  *where the file lives* (a store path) and *who writes it* (the user, via an import).
- User data (`KilterLogEntry` / `KilterSession` / `KilterFavorite` in SnappetCore / Room) is **untouched**.
- The hard constraint this fights — `project.md:64` "On-device only. No backend, no network sync, no
  accounts." — gets one **narrow, named** carve-out (a user-initiated catalog fetch), because the catalog
  is third-party-owned and can't legally be shipped by us. Keep it named so it can't justify general
  networking elsewhere.
- Build rule: the iOS/Android apps need macOS+Xcode / the Android SDK — they can't be built on the
  Linux/cloud box. Author + unit-test-shape the change; `xcodebuild test` + Gradle are owed at the gate.

## Approach

Introduce a catalog seam so the read path is source-agnostic and the write/fetch path is a thin,
swappable network edge. Mirror it on both platforms.

```
KilterCatalog (read-only reader)   ← UNCHANGED logic; opens a PATH from the store, not the bundle
        ▲ reads file at
KilterCatalogStore                 ← owns the on-device file (App Support / filesDir) + meta sidecar
        ▲ writes                       isInstalled / metadata / install / clear
KilterCatalogProvider (protocol)   ← the only IO edge
        + KilterCatalogValidator       FileImportProvider (Files / SAF) shipped; AuroraSyncProvider stub (P2)
```

- **iOS** (`Features/Kilter/`): add `KilterCatalogStore.swift`, `KilterCatalogProvider.swift` (protocol +
  `FileImportProvider` + inert `AuroraSyncProvider` + `KilterCatalogInstaller`), `KilterCatalogValidator.swift`,
  `KilterCatalogSyncView.swift`, `KilterCatalogFixture.swift` (synthetic test catalog). Repoint
  `KilterCatalog` at the store + add `reload()`; show the sync view from `KilterRootView` when not
  installed; add status/refresh/remove to `KilterSettingsView`; install the fixture under a
  `-uiTestInstallKilterCatalog` launch arg in `SnappetApp`. Delete `Resources/kilter.sqlite3`.
- **Android** (`feature/kilter/`): mirror with `KilterCatalogStore.kt`, `KilterCatalogProvider.kt`,
  `KilterCatalogValidator.kt`, `KilterCatalogSyncScreen.kt`, `KilterCatalogFixture.kt`; repoint
  `KilterCatalog` + add `reset()`; gate `KilterRoot` on availability; add status/refresh/remove to
  `KilterSettingsScreen`; install the fixture via a `TestHooks` flag read in `MainActivity`. Delete
  `assets/kilter.sqlite3`.
- **Docs**: `tools/kilter/README.md` + `build_bundled_db.py` reframed (output is user-importable, not a
  shipped asset) + a new synthetic `build_test_fixture.py`; `decisions.md` entry + `project.md:64`
  footnote; `docs/knowledge-graph/data.js` new nodes (`kilter-catalog-store/provider/sync`) + edges.

## Output

The files named above. The validator asserts the reader's required tables
(`difficulty_grades, layouts, climbs, climb_stats, placements, holes, placement_roles, leds`), requires
≥1 listed climb, caps size, and derives a deterministic version. The sync screen surfaces Aurora's Terms
of Use + a link before any fetch. `AuroraSyncProvider` is present but performs no network calls (the sync
button is disabled) — Phase 2 drops in behind the same protocol once its open questions are answered.

## Acceptance criteria

- [ ] The built iOS app and Android APK/AAB contain **no** `kilter.sqlite3` and no Aurora climb data
      (the asset is removed from both platforms; no code/config references it).
- [ ] First open with no catalog shows the opt-in sync screen (not a crash, not an empty list).
- [ ] Importing a valid `.sqlite3` installs it; browse/detail/history/illuminate then work as before.
- [ ] Importing a malformed/foreign file is rejected with a clear error (validator).
- [ ] Settings shows catalog version/size and supports Refresh + Remove; removing returns to the opt-in
      state and keeps logged ascents + saved climbs.
- [ ] The sync screen surfaces Aurora's Terms of Use + a link before any fetch.
- [ ] No analytics/telemetry; no Snappet backend; user-data model unchanged. The only network code is the
      named, user-initiated provider (Phase 2 stub, inert).
- [ ] `decisions.md` records the removal + the narrow carve-out; `project.md:64` footnoted;
      `tools/kilter/README.md` updated; `docs/knowledge-graph/data.js` updated.
- [ ] iOS UITest + Android instrumented test cover empty-state → (fixture install) → browse → detail →
      log, using a synthetic, checked-in/in-code fixture (zero Aurora data).

## Constraints

- On-device only **except** the one named, user-initiated Kilter catalog fetch (see `decisions.md`).
  No background sync, no analytics, no backend; health + media never leave the device.
- The test fixture must be **synthetic** — schema + a handful of rows we author ourselves, never Aurora
  data.
- State verification honestly: this is authored on Linux (no Xcode/Android SDK), so it's **not** compiled
  or run — only the Python fixture is verified locally. Don't claim the UI/build is "verified".

## Test plan

1. Local (runnable here): `python3 tools/kilter/build_test_fixture.py` + replay every `KilterCatalog`
   query against the output to confirm the synthetic catalog drives browse/detail/holds/LED paths.
2. iOS (owed, Mac): `xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
   — `KilterCatalogStoreTests` (build/validate/install/clear + reader integration) + the Kilter UITests
   (empty-state + fixture-install browse/log/save).
3. Android (owed, SDK): `testDebugUnitTest` + `connectedDebugAndroidTest` (`KilterCatalogStoreTest` +
   `KilterUITest`).
4. Bundle inspection: unzip the `.app`/`.apk` and assert no `kilter.sqlite3`.
