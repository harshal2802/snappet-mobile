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
