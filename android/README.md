# Android (+ Wear OS)

Android target for Snappet Mobile — **a later phase** (after the iOS algorithm is proven).

- **App:** Kotlin.
- **Live workout HR:** Wear OS Health Services `ExerciseClient` (Wear OS 3+). `MeasureClient` is NOT
  for workout tracking.
- **Phone-side aggregation:** Health Connect (`androidx.health.connect`).
- **Reel:** Media3 `Transformer` (hardware-accelerated, on-device) — trim/crop/concatenate into a
  `Composition`.
- **Generic bands:** BLE Heart Rate Profile (GATT `0x180D`) client (Phase 5).

Framework decision (native Kotlin vs RN shared orchestration) is deferred to Phase 4 — see the web
repo's PLAN and [Snappet#60](https://github.com/harshal2802/Snappet/issues/60).

---

## Implemented — the Snappet daily-app SUITE (Android, native Kotlin/Compose)

The Android app mirrors the iOS suite feature-for-feature: a bottom-nav shell (**Home** dashboard +
**App Library**) over a shared on-device store (**Snappet Core**), with the same 8 modules. Builds,
installs, and runs on the Android 15 (API 35) emulator; every non-device module has an instrumented
Compose UI test matching its iOS XCUITest counterpart.

### Stack
- **Language/UI:** Kotlin + Jetpack Compose + Material 3 (the SwiftUI equivalent).
- **Persistence:** Room (the SwiftData equivalent) — one shared `SnappetDatabase`; trivial state in
  SharedPreferences (the `@AppStorage` equivalent). All on-device; nothing transmitted.
- **Architecture mirror:** `core/AppModule` + `core/ModuleRegistry` (← iOS `AppModule`/`ModuleRegistry`),
  `core/SnappetCore` usage logging (← iOS `SnappetCore`), `ui/ModuleScaffold` provides the standard
  top-bar + back arrow each module pushes into. Wiring a module = two central edits (registry entry +
  `@Entity` list), same as iOS.
- **Build:** AGP 8.7.3 · Gradle 8.11.1 (wrapper) · Kotlin 2.0.21 · KSP · compileSdk 35 · minSdk 26.

### Modules
| Module (id) | Status |
|---|---|
| Workout Reels (`workout`) | Flagship — **device-only** (Health Connect + Wear OS HR + Media3 + media perms). Informational/gated screen on emulator, mirroring iOS (not in the sim/emulator UI-test suite). |
| Workout Tracker (`workout-log`) | Full: catalog, starter routines, routine/exercise detail, set-by-set player, history, settings. |
| Pomodoro (`pomodoro`) | Drift-free timer, history + 7-day chart, persisted settings. |
| Habits (`habit`) | Create/edit, 7-day backfill strip, streak + 30-day rate. |
| Journal (`journal`) | Entries, tag chips, search/filter. |
| Tip (`tip`) | Bill + presets, history, editable presets, round-up. |
| Split Expenses (`expense`) | Groups, add/edit expenses, settle-up plan, manual settlements. |
| Budget (`budget`) | Categories, transactions add/edit, month switcher, spend chart, 6-month trends. |

### Build / run / test
The toolchain lives under `/opt/homebrew/share/android-commandlinetools` (SDK) and
`/opt/homebrew/opt/openjdk@17` (JDK 17). From `android/`:

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
./gradlew :app:assembleDebug                 # build the debug APK
adb install -r app/build/outputs/apk/debug/app-debug.apk && \
  adb shell am start -n com.snappet.mobile/.MainActivity   # install + launch on the emulator
./gradlew :app:connectedDebugAndroidTest     # run the full instrumented UI-test suite on a device/emulator
```

Emulator AVD used in development: `snappet_pixel7` (Pixel 7, API 35, arm64). Create one with
`avdmanager create avd -n snappet_pixel7 -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_7`.

### Testing notes
- Instrumented Compose tests live in `app/src/androidTest/`; each extends `SuiteTest`, which forces a
  fresh in-memory Room store per launch via `TestHooks.freshInMemoryStore` — the Android analogue of
  the iOS `-uiTestFreshStore` launch argument. Module entry mirrors iOS: open each app from its
  `moduleCard.<id>` in the App Library.
- The flagship `workout` Reels pipeline is device-only and intentionally excluded from emulator tests,
  exactly as the iOS HealthKit/Photos/AVFoundation flow is excluded from the simulator suite.
