# Prompt: Create a new climb — Android port (manual editor + ONNX generator + dedup + BLE preview + export)

**File**: pdd/prompts/features/33-android-create-climb.md
**Created**: 2026-06-09
**Project type**: Native Android feature (Kotlin / Jetpack Compose) — code lands in this repo.
**Chain**: Android mirror of the iOS create-a-climb arc (prompts 30→31→32, PRs #63/#64/#65).
**Source**: User request — "implement the Android as well".
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Bring the full "create a new climb" feature to Android, matching the iOS behavior: a manual hold editor,
the on-device ONNX generator, duplicate validation against the downloaded dataset + prior creations, a
**cross-platform-stable** content uuid (an iPhone and an Android phone that author the identical climb
agree on its id), live BLE preview, and frames export.

## Context the implementer needs

- The Android Kilter module mirrors iOS: `KilterCatalog.kt` (read-only SQLite + the data classes +
  `parseFrames`), `KilterBoard.kt` (Compose Canvas renderer with `holdPath`/`hexColor`), `KilterRoot.kt`
  (browse + simple enum-screen nav), `KilterDetailScreen.kt`, `KilterBoardController.kt` (BLE
  `illuminate`), Room via `SnappetDatabase` + `KilterDao`, manual DI via `AppContainer` /
  `LocalAppContainer`, prefs via `KilterSettings`.
- The uuid MUST be byte-identical to iOS `KilterClimbIdentity` (UUIDv5, same namespace, SHA-1 over the
  canonical key) — proven by the **same golden vector** in tests.
- Two new dependencies: `com.microsoft.onnxruntime:onnxruntime-android` (the generator runtime) and
  `kotlinx-serialization-json` (JVM-testable `meta.json` decode), added via the version catalog.

## Approach

Pure core (JVM-tested, no Android deps): `KilterClimbIdentity`, `KilterCreateModels` (author role / frames
/ validation / `KilterPlaceableHold`), `KilterDuplicateChecker`, and the generator
`KilterGeneratorMeta`/`KilterClimbGenerator` behind a `KilterLogitsProviding` interface. Edges:
`KilterGeneratorAssets` (HTTP download + cache), `KilterGeneratorRuntime`/`KilterOrtSession` (the only
`ai.onnxruntime` import). Persistence: a `KilterCreatedClimb` Room entity + DAO methods (DB version 3→4).
Catalog reads: `placeableHolds` / `boardBounds` / `climbFramesForDedup`. UI: `KilterEditableBoard`
(interactive Canvas), `CreateClimbScreen` (Manual / ✨ Generate), wired into `KilterRoot` (a CREATE screen
+ a Mine browse filter) and `KilterDetailScreen` (resolve created climbs + share frames).

## Output

- New Kotlin: `KilterClimbIdentity.kt`, `KilterCreateModels.kt`, `KilterDuplicateChecker.kt`,
  `KilterGeneratorMeta.kt`, `KilterClimbGenerator.kt`, `KilterGeneratorAssets.kt`,
  `KilterGeneratorRuntime.kt`, `KilterEditableBoard.kt`, `CreateClimbScreen.kt`; tests
  `KilterCreateClimbTest.kt`, `KilterGeneratorTest.kt`.
- Changed: `KilterEntities.kt` (entity + DAO), `SnappetDatabase.kt` (register + version 4),
  `KilterCatalog.kt` (3 reads), `KilterRoot.kt` (CREATE + Mine), `KilterDetailScreen.kt` (resolve +
  share), `gradle/libs.versions.toml`, `app/build.gradle.kts`, root `build.gradle.kts`.

## Acceptance criteria

- [x] `:app:compileDebugKotlin` + `:app:assembleDebug` succeed (Room v4 + ONNX + serialization, dex OK).
- [x] `:app:testDebugUnitTest` green incl. the **golden UUID vector matching iOS** + the generator decode.
- [x] Created climbs save through the dedup + deterministic-uuid path and open in the detail screen.
- [x] ONNX import is confined to `KilterGeneratorRuntime.kt`.

## Constraints

- On-device only; model + meta are user-hosted (same #42 posture as the catalog).

## Test plan

1. `./gradlew :app:testDebugUnitTest` — identity (golden vector), frames, validation, dedup, generator
   decode/grade (stub session, no ONNX/model/device).
2. `./gradlew :app:assembleDebug` — full build incl. Room migration + dex.
3. Device/emulator: Create ▸ Manual draw + Save; ✨ Generate ▸ download model ▸ generate ▸ Use; Mine
   filter; frames copy/share; BLE draft-lighting on a real board (device-only).
