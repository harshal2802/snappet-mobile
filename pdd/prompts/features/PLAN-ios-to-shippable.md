# PLAN: Snappet Mobile iOS — v0.1 → shippable v1

**Status**: drafting
**Owner**: pdd
**Created**: 2026-05-30
**Scope**: the implementation prompt chain *inside this repo* that takes the type-checked v0.1 MVP to a
v1 you can run on a device, collect data with, and submit to TestFlight / the App Store.
**Parent plan**: web repo `pdd/prompts/features/native-mobile/PLAN-snappet-mobile.md` (this is the
detail under its "Phase 1: iOS MVP" → finish + ship). **Research**: issue [#60](https://github.com/harshal2802/Snappet/issues/60).

## Where we are

v0.1 is **code-complete and type-checked but never run on a device** (see `pdd/context/project.md` →
Current state). The algorithm is proven by unit tests; the app's runtime behavior, permission flows,
and reel export are unproven. The Phase-0a efficacy verdict is **NEEDS-REAL-DATA**.

## The critical path to "shippable"

```
  [P1] Run on device ──► [P2] Onboarding + JIT permissions ──► [P3] Reel preview/playback
       (unblocks all)                                                      │
  [P4] Finish feedback loop (pins/reorder/add) ─────────────────► [P6] Offline replay tuner
  [P5] Phase-0b time-sync spike ──► validate media↔HR padding ───► (tune HighlightConfig)
                                                                            │
                          [P7] Ship prep (icon, privacy labels, TestFlight) ◄┘
```

"Shippable v1" = runs reliably on a device, asks for permissions value-first, plays the reel before
export, exports a real `.mp4`, captures usable training data, and passes App Store privacy review.

## Prompt chain

Author each prompt only when its predecessors' results are in. Spikes target throwaway/measurement
code; feature prompts target shippable code with tests where the engine is touched.

| # | Prompt file | Type | Scope | Verifiable here? |
|---|---|---|---|---|
| P1 | `01-ios-device-build-and-run.md` | feature | 🟢 **PARTIAL (2026-05-31).** Full `xcodebuild` for the simulator → BUILD SUCCEEDED; app installs/launches/renders onboarding on iPhone 17 (iOS 26.4). Fixed a real `Info.plist` bundle-id bug. **Remaining (user step):** the data-dependent run on a real device (Apple Watch workouts + Photos) per `ios/App/RUNBOOK-device.md` → first `highlight-feedback.jsonl`. | 🟢 sim build/run done; device data-flow pending |
| P2 | `02-ios-onboarding-and-permissions.md` | feature | **✅ DONE 2026-05-31.** `OnboardingView` (value-first) + JIT Health/Photos on tap; fixed latent never-requested-Photos bug; `.limited` → `MediaPicker` (PHPicker) fallback. App type-checks. | partial (type-check) |
| P3 | `03-ios-reel-preview.md` | feature | **✅ DONE 2026-05-31.** Inline `VideoPlayer` over the composition (no export); edits invalidate the preview. `ReelExporter.makeComposition` shared via `sending`. App type-checks. | partial (type-check) |
| P4 | `04-engine-finish-feedback-loop.md` | feature | **✅ DONE 2026-05-30.** pin (budget-exempt) / reorder / restore wired into `ReelView`; planner takes `pinnedIds`/`order`; `.pinned`+`.reordered` now fire. 18 engine tests pass, app type-checks. (`added` + pins-survive-regenerate deferred — see decisions.) | ✅ engine tests + type-check |
| P5 | `05-spike-media-hr-timesync.md` | spike | **✅ DONE 2026-05-31.** `experiments/media-hr-timesync/` error-budget model + 3 aligners; verdict: ±90 s pad is sound for skew+drift, real fix is TZ normalization (gross errors → missing media). Runs. | ✅ Python harness (real-data caveat) |
| P6 | `06-feedback-replay-tuner.md` | spike→tool | **✅ DONE 2026-05-31.** `experiments/feedback-replay/` ranks configs by satisfaction + estimates `effort_mix`; efficacy harness gained a **Fusion** selector + **tolerance sweep** (Fusion overtakes Scene at ±12–15 s). Runs. | ✅ Python / Swift CLI |
| P7 | `07-ios-ship-prep.md` | feature | **✅ DONE 2026-05-31.** `PrivacyInfo.xcprivacy` (no data collection, on-device), app-icon asset-catalog scaffold, display name, `project.yml` wiring. Deferred: actual icon art + TestFlight upload (need signing/art). | partial |
| P8 | `08-ios-photo-kenburns.md` | feature | **✅ DONE 2026-05-31.** `PhotoClipRenderer` renders photo highlights as Ken-Burns clips (was: photos silently dropped); `makeComposition` interleaves them. Builds on the sim; visual needs a device. | ✅ build + type-check |

> Status (2026-05-31): **everything buildable in a no-device environment is done** — P2/P3/P4 (Swift,
> type-checked), P5/P6 (Python, run). **P1 is the only remaining step and it's the user's**: run on a
> device per `ios/App/RUNBOOK-device.md` to validate runtime and start collecting real feedback. Once
> ≥8–10 real sessions exist, P6's tools apply the GO / fusion / NO-GO gate.

## Decision gates

- **After P1**: does the auto-found media + auto reel actually look right on real workouts? If the HR
  picks feel wrong, prioritize P6 (tuning) before polish.
- **After P5**: if measured drift ≫ 90 s or clip-internal mapping fails, widen padding / change the
  matching strategy *before* asking users to trust auto-discovery.
- **After P6 with ≥8–10 real sessions**: apply the spike's GO / fusion / NO-GO rule
  (`experiments/hr-highlight-efficacy/RESULTS.md`) — this is the real Phase-1-commitment gate.

## Out of scope for v1 (defer)

watchOS live-HR capture, Android, generic BLE bands, the full Snappet Core on-device store + DayLog +
cross-module consent (Phase 3), in-app capture, music/saved styles. Keep the selector pluggable so
none of these require engine rewrites later.

## Notes

- One prompt = one PR. Commit the prompt asset with the code it produced.
- Engine changes ship with passing `swift test`. Device-only changes state honestly what was verified.
- Update `decisions.md` the same day any non-obvious choice is made.
