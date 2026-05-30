# iOS (+ watchOS)

iOS-first target for Snappet Mobile.

- **App:** Swift / SwiftUI.
- **watchOS companion (mandatory for live HR below iOS 26):** `HKWorkoutSession` +
  `HKLiveWorkoutBuilder`, relays live HR for in-session UI.
- **Authoritative HR:** post-workout synced `HKWorkout` series drives highlight detection.
- **Media:** library import + auto-time-window discovery (full Photo Library access primed; limited /
  multi-select fallback).
- **Reel:** AVFoundation (`AVMutableComposition` + `AVAssetExportSession`), fully on-device.

See the web repo's `pdd/prompts/features/native-mobile/PLAN-snappet-mobile.md` and
[Snappet#60](https://github.com/harshal2802/Snappet/issues/60) for the full design and constraints.

Xcode project to be added in Phase 1 (after the Phase-0 spikes return a GO).
