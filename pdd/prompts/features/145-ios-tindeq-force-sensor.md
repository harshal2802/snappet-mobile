# Prompt: Tindeq force sensor — live force, auto reps, % of max, max test

**File**: pdd/prompts/features/145-ios-tindeq-force-sensor.md
**Created**: 2026-09-30
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: hangboard-protocols — 139 → … → 144 → **145 force sensor**
**Design**: `docs/ux-research/hangboard-protocols/wireframes.html` frames 11–14, 12B–D (approved; Q7, Q8)

## Goal

Users train with a Tindeq (Progressor) that streams force. Fit it in without changing anything for
people who don't have one: measured load, automatic rep start/stop, "% of max" targets (the original
request's "Load 90 % / 60 % of 1RM / 40 %"), a measured max, and force in history.

## Approach

- Pure `TindeqProtocol` (Tindeq's published BLE API: service 7e4e1701…, data …1702 notify, control
  …1703; commands tare 100 / start 101 / stop 102 / battery 111; tag-1 packets of [float32 kg, uint32 µs]
  little-endian) and `ForceAnalysis` (hysteresis rep detector, peak / time-weighted mean / early RFD,
  target band ±3 %, asymmetry) — unit-tested on byte arrays and synthetic hangs.
- `ForceSensorSource` protocol (generic — other boards later) + `TindeqProgressorSource`
  (CoreBluetooth, the BLE-HR source's patterns; radio only woken when pairing or a hang protocol starts
  with a sensor remembered; auto-reconnect; resumes measuring after a drop) + `FakeForceSensor` for UI
  tests (the simulator has no Bluetooth). `ForceMaxStore` (per hand + two-hand; scratch suite under UI tests).
- Spec: optional `targetPercentOfMax` (presets 90/60/90/40 %) and `isMaxTest`; **Max pull test** preset.
- Runner: live force + target band (frame 12); a timed hang **waits for load** (decided once as the hang
  begins — letting go partway ends it short); a tap-done rep **ends on release**; under-target haptic;
  connect card in get-ready/rests (12B–C); drop banner + timer fallback (12D); per-rep `ForceRepRecord`s
  on the SetLog; end card peak/avg/asymmetry + **Use as my max** for the max test.
- Settings → Force sensor (frame 11). History rows: "peak 48.1 kg" / "peak L 47.9 / R 50.2 kg".

## Acceptance criteria

- [x] Packet parsing, analysis, gating, release-ends-rep, per-rep logging: unit-tested (`ForceAnalysisTests` 8,
      `RunnerViewModelTests` +5).
- [x] Fake-sensor UI test: max set in Settings, live force + "Target 45–48 kg · 90 % of your max", peak on the end card.
- [ ] **Device leg (owed, needs the user's Tindeq):** pair, tare, live stream, auto rep start/stop, drop/reconnect.
