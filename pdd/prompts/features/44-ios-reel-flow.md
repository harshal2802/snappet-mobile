# Prompt: Fix the flagship reel flow's dead ends and give the export a real payoff

**File**: pdd/prompts/features/44-ios-reel-flow.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 2 (iOS)
**Source**: GitHub issue [#72](https://github.com/harshal2802/snappet-mobile/issues/72)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The centerpiece flow punishes users at the moment of payoff. Every error is a terminal
screen: a failed export discards the entire curated edit (pins, removals, order) with no
Retry; Photos-denied offers neither Open Settings nor an alternative; Health-denied users
get "track a workout, then pull to refresh" — advice that can never work because HealthKit
read denial is invisible. And when everything succeeds, the payoff is a checkmark: no
inline player, no Save to Photos, no thumbnails — and the file sits in `tmp`, where
backing out or "Make another cut" loses it entirely. Fix all five dead ends and make the
success screen feel like the reward the flagship promises.

## Context the implementer needs

- `ReelViewModel.export()` lands every failure in `.error`, which `ReelView` renders
  action-less — but the curation state (`removed` / `pinnedIds` / `orderedIds`) is still
  in the VM after a failed export, so recovery is purely a state-machine fix.
- `PhotoLibraryService.media(in:)` throws `PhotoError.denied` → `.error`, never `.empty`;
  the `.empty` branch hardcodes "Select clips" — but **`media(forIdentifiers:)` resolves
  via `PHAsset.fetchAssets`, which returns nothing under full denial**, so "Select clips"
  must never be the denied-state remedy (issue verifier caveat).
- HealthKit read-auth status is not queryable by design — empty-list copy must
  acknowledge possible denial instead of promising sync.
- Ready-made, unwired pieces: `MediaLibraryService.saveVideoToPhotos` (add-only, built
  for `ReelExporter` output), the `SessionDetailView` Open-Settings escape hatch +
  PHImageManager thumbnail pattern, the `Haptics` helper (already fired via
  `.celebrates(on:)` on the exported landing).

## Approach

- **`ReelFlowPolicy`** (new, `Features/Reel/`, Foundation + engine only): the pure
  decision layer — empty/denied/error/export-failed `RecoverySpec`s (copy + ordered
  actions), regenerate-confirmation messages, export directory/filename, sweep selection,
  activity icons. Unit-tested in `SnappetTests` with no simulator.
- **`RecoveryUnavailableView`** (new): renders a `RecoverySpec` as a
  `ContentUnavailableView` with working buttons; handles the Settings deep-link once.
- **`ReelViewModel`**: new `.exportFailed(String)` state (Retry keeps curation; back-to-
  edit returns to `.ready`), `SaveState` + `saveToPhotos()` via `MediaLibraryService`,
  denied-aware `generate()` catch (`PhotoError.denied` → `.empty`), live `photoAccess`
  mirror, `regenerateConfirmation(exportedUnsaved:)`.
- **`ReelExporter`**: exports land in `Application Support/Reels` (backup-excluded),
  swept to the newest `ReelFlowPolicy.keepLatestExports` before each new render — out of
  `tmp`, so the artifact survives navigation.
- **`ReelView`**: policy-driven recovery branches; Regenerate / "Make another cut"
  confirm via `confirmationDialog` when the policy says something is at stake;
  `ExportedView` becomes the payoff — auto-playing looped `AVQueuePlayer` +
  `AVPlayerLooper` hero, Save to Photos + Share, success haptic via the existing
  `.celebrates(on:)`; `HighlightThumbnail` (shared `PHCachingImageManager`) on rows.
- **`WorkoutListView` / `WorkoutModule`**: activity icons on rows; empty/error overlays
  from the policy with explicit Refresh / Try again / Open Settings.

## Output

- New: `Features/Reel/ReelFlowPolicy.swift`, `Features/Reel/RecoveryUnavailableView.swift`,
  `SnappetTests/ReelFlowPolicyTests.swift`.
- Modified: `Features/Reel/ReelView.swift`, `Features/Reel/ReelViewModel.swift`,
  `Services/ReelExporter.swift`, `Features/Workout/WorkoutListView.swift`,
  `Features/Workout/WorkoutModule.swift`.
- Docs: knowledge-graph nodes (`reel-flow-policy`, `reel-exported`) + reel/workout node
  descs; `decisions.md` entry; `project.md` component list.

## Acceptance criteria

- [ ] Export failure shows Retry and preserves pins/removals/order.
- [ ] Photos-denied and Health-denied states each offer a working Open Settings action
      with truthful copy; denied never offers "Select clips".
- [ ] Success screen plays the reel inline (looped, auto-playing) and offers Save to
      Photos + Share with a success haptic.
- [ ] The exported file survives leaving the screen; regenerate no longer silently
      discards curation or an unsaved cut (confirmation dialog).
- [ ] Highlight rows show real thumbnails; workout rows show activity icons.
- [ ] Pure logic (copy/action selection, confirmation, export paths, sweep, icons) is
      unit-tested in `SnappetTests`.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine` (untouched).
- [ ] `decisions.md` updated.

## Constraints

- On-device only; no backend. `HighlightEngine` untouched.
- State verification honestly: type-check ≠ device run for Photos/AVFoundation/Settings
  deep-link behavior — the full-flow run on hardware stays device-pending.

## Test plan

1. `xcodegen generate` + full `SnappetTests` on the simulator (new `ReelFlowPolicyTests`).
2. Simulator walkthrough: workout list (icons, empty overlay actions), reel edit list
   (thumbnails), export failure → Retry, exported screen (player, Save, Share, confirm).
3. Device-pending: real export + looped playback, Photos save permission sheet, Settings
   deep-link round-trip, haptic feel.
