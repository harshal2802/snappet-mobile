# Prompt: Manual relink — find a missing clip by hand

**File**: pdd/prompts/features/cloud-connect/266-ios-manual-relink.md
**Created**: 2026-11-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P1b (stacked on P1, prompt 265)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Design**: `docs/ux-research/cloud-connect/index.html` (wireframes 4 and 5)

## Goal

Prompt 265 re-links a dead clip only when it can find the footage unaided, and otherwise shows
"Not on this phone" with no way forward. On the first real library it ran on, 1,684 of 1,875 clips
were missing (footage freed up by Google Photos). Give the person a summary of what is missing and
one way to bring footage back: pick it from this iPhone's library, verified against what Snappet
remembers about the clip. Nothing leaves the phone.

## Context the implementer needs

- `MediaLinkService.reconcile` already decides `.missing` per row but drops the answer.
- `MediaPicker` (PHPicker with `photoLibrary: .shared()`) returns asset identifiers.
- The feed shows a still poster until a clip is played; `ClipMediaSurface`'s placeholder is the
  only place "Not on this phone" appears.
- The simulator cannot hold Photos access under `xcodebuild test`, so no pass runs there.

## Approach

- **Pure** (`MediaLink.swift`): `MissingClip`; `MediaRelinkPlanner.assign(missing:picks:owned:)` →
  per-pick verdict (`attached` / `noMatch` / `ambiguous` / `alreadyInUse`), reusing
  `MediaLinkMatcher`; `MissingClipsNotice` (wording, grouping, dismiss rule, outcome message).
- **Service**: `reconcile` returns a `Report` (summary + missing clips + whether the library was
  visible); `attach(pickedIdentifiers:)` fingerprints the picks off-main and applies the plan.
- **State**: `MediaLinkStatus` (`@Observable`, in memory) on `AppModel` — no stored "missing" flag.
- **UI**: `ClipsMissingCard` (one row in the Clips feed, dismissible until more go missing),
  `MediaRelinkSheet` (missing clips by session + "Pick from this iPhone" + outcome line), and a
  "Find clip" button on the missing placeholder where a host can present the sheet.
- **Test hook**: `-uiTestAssumeMissingClips` reports every seeded clip as missing.

## Output

`MediaRelinkSheet.swift`, `MediaLinkStatus.swift`, additions to `MediaLink.swift`,
`MediaLinkService.swift`, `AppModel.swift`, `ClipsFeedView.swift`, `ClipMediaSurface.swift`,
`SnappetApp.swift`; `MediaRelinkTests.swift`; a `ClipsFeedUITests` case; knowledge graph;
`decisions.md`; `project.md`; `PLAN.md`.

## Acceptance criteria

- [ ] After a pass with full Photos access, the Clips feed shows "N clips aren't on this phone";
      a pass without access leaves the previous answer alone.
- [ ] The sheet lists missing clips grouped by session and day, newest first.
- [ ] A pick is attached only on a unique fingerprint match; a pick that matches nothing, ties, or
      is already another clip's footage is reported and not attached.
- [ ] Two rows sharing one dead identifier both land on the pick.
- [ ] Dismissing the notice keeps it away until more clips are missing than were dismissed.
- [ ] Swift 6, no new warnings; `decisions.md` updated.

## Constraints

- On-device only. Picks come from the Photos library (files / AirDrop copies must be saved to
  Photos first). Google's picker is P4.
- Never attach on a guess.

## Test plan

1. `MediaRelinkTests` + `MissingClipsNoticeTests` (pure); `ClipsFeedUITests` (notice → sheet → dismiss).
2. Device: with missing clips, save one back to Photos, Review → Pick from this iPhone → pick it →
   "1 clip found", the clip plays. Pick an unrelated photo → "That pick didn't match a missing clip".
