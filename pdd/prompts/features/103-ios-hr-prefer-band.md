# Prompt: Prefer a heart-rate band for detailed clip HR (Phase D / Opt 4)

**File**: pdd/prompts/features/103-ios-hr-prefer-band.md
**Created**: 2026-06-23
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: HR-granularity epic (99) → Phase D.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

A BLE chest strap streams ~1 Hz HR (+ RR) — the densest realtime source the app has, ideal for clip
overlays — but `LiveMetricsCoordinator.resolve` auto-prefers the Apple Watch. Let a user who wants the
most detailed clip HR **opt in** to preferring a connected band, without surprising watch users (the
default is unchanged) and without overriding an explicit source pick.

## Context the implementer needs

- `LiveMetricsCoordinator.resolve(selected:watchUsable:hasBLEDevice:)` (LiveMetricsCoordinator.swift):
  explicit `selected` wins; else watch when usable; else BLE if a band is known; else watch. `activeKind`
  calls it; `MetricsSourceSelectionTests` cover it.
- The coordinator is `@Observable` (not a View) so it can't use `@AppStorage` — persist via `UserDefaults`.
- The HR source picker is `HeartRateSourcePicker`; explicit taps set `coordinator.selectedSource`.

## Approach

- **Pure policy hook.** Add `preferBandForDetail: Bool = false` to `resolve`: when true **and** a band is
  known (and no explicit pick), return `.ble` ahead of the watch. The default keeps every existing call
  site + test unchanged. Unit-tested.
- **Persisted preference.** Add `var preferBandForDetail: Bool` on the coordinator, backed by `UserDefaults`
  (read in init, written in `didSet`), and pass it through `activeKind`.
- **Picker affordance.** A Toggle in `HeartRateSourcePicker` bound to the preference, with an explainer
  footer (a band records ~1×/s — the most detailed for clips; the watch records less often, and Snappet
  backfills watch sessions from Health when it can — ties Phase C together).

## Output

- `ios/App/Snappet/Services/LiveMetricsCoordinator.swift` — `preferBandForDetail` (persisted) + `resolve`
  param + `activeKind` passes it.
- `ios/App/Snappet/Features/WorkoutTracker/HeartRateSourcePicker.swift` — the Toggle + explainer.
- `ios/App/SnappetTests/MetricsSourceTests.swift` — `preferBandForDetail` cases (prefers BLE when on + band
  known; still honors explicit pick; falls through to watch when no band).
- `docs/knowledge-graph/data.js` + `pdd/context/decisions.md`.

## Acceptance criteria

- [ ] With the preference ON and a band known, the auto-default resolves to `.ble`; OFF (default) keeps the
      watch-first behavior; an explicit pick always wins; no band known → watch.
- [ ] The preference persists across launches; the picker exposes it with a clear explainer.
- [ ] App type-checks (Swift 6, 0 warnings); `SnappetTests` green (existing resolve tests unchanged).

## Constraints

- Opt-in only — never silently change the default source. On-device only.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — green incl. new resolve cases.
2. Sim: toggle the preference in the picker; with a (simulated) known band the active source flips to the
   band; the toggle state persists across relaunch.
