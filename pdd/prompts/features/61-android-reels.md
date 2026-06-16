# Prompt: Android Workout Reels — honest screen + first pipeline slice

**File**: pdd/prompts/features/61-android-reels.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Compose). Code lands in this repo.
**Chain**: Android Wave 3 (product-review backlog) → #90
**Source**: GitHub issue [#90](https://github.com/harshal2802/Snappet/issues/90)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The flagship Workout Reels module was a static brochure on Android: jargon copy ("Resample → %HRR",
"MediaStore", "Media3 Transformer") and a permanently disabled "Connect Health Connect" button whose
copy falsely blamed the emulator. Ship Stage 0 (an honest user-language screen with a real control)
plus the first working pipeline slice — the pure HR-ranking core, ported from the iOS HighlightEngine.

## Context the implementer needs

- `feature/reel/ReelRoot.kt` was the only file in the reel package (a dead screen).
- The iOS `HighlightEngine` is a Foundation-only SPM package (platform-free, unit-tested). Its
  resample → smooth → %HRR → pick-non-overlapping-windows ranking is the portable core.
- Full pipeline (Health Connect read, MediaStore window query, Media3 assembly) is device-only.

## Approach

- Rewrite `ReelRoot.kt`: user-language steps, no API names, and an honest "Coming to Android /
  Notify me" control (a real, non-permanently-disabled button) instead of the dead disabled one.
- Add `feature/reel/ReelRanking.kt` — the pure, platform-free ranking core (no Android deps), the
  first pipeline slice, JVM-unit-tested. The device edges plug into it later.

## Output

- `feature/reel/ReelRoot.kt` (honest Stage-0 screen).
- `feature/reel/ReelRanking.kt` (pure ranking core).
- `app/src/test/.../reel/ReelRankingTest.kt`.

## Acceptance criteria

- [x] No permanently disabled controls; screen copy contains no API names.
- [x] The HR-ranking core is pure and unit-tested without a device.
- [ ] (target / device-pending) Health Connect read + MediaStore match + Media3 export.
- [x] Knowledge graph updated.

## Constraints

On-device only; nothing uploaded. The ranking core stays platform-free (mirrors HighlightEngine).

## Test plan

1. `./gradlew :app:testDebugUnitTest` — ReelRankingTest green.
2. Eyeball the screen copy for honesty + no jargon.
