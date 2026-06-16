# Prompt: Android — Kilter authoring & browsing delight

**File**: pdd/prompts/features/67-android-kilter-delight.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Jetpack Compose) — code lands in this repo.
**Chain**: 2026-06-09 dual-platform product review → Android Continuous-polish batch
**Source**: GitHub issue [#93](https://github.com/harshal2802/Snappet/issues/93)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Four high-delight, low-risk gaps in Kilter: hand-authored climbs got no grade feedback; browsing
climb-to-climb meant backing out to the list each time; the guided "what should I climb today" entry
point was missing; and the log buttons confused newcomers (Flash/Attempt shared the Bolt icon,
Project's star duplicated the Saved star, and the four statuses were never explained). All four are
pure on-device logic/UI — no hardware.

## Context the implementer needs

Base: `android/app/src/main/java/com/snappet/mobile/feature/kilter/`.
- `KilterClimbGenerator.predictGrade` is already a pure linear model over `meta.json` (no ONNX);
  `KilterCreatedClimb.predictedGrade` column exists; manual save passed `predictedGrade = null`.
- iOS references: `KilterRecommender.swift` + `KilterPlanView.swift` (the recommender to port);
  `KilterClimbDetailView.swift` (the siblings array + swipe).

## Approach

1. **Live grade estimate (manual editor):** add pure `KilterClimbGenerator.holdTokens` +
   `estimateManualGrade` (mirrors iOS). Load the generator meta meta-only via
   `KilterGeneratorAssets.installedMeta()` (no download, no ONNX); show a "≈ V5 at 40°" chip that
   updates per hold tap, gated on assets installed (else a one-line hint). Persist the estimate into
   `predictedGrade` on manual save.
2. **Sibling swipe:** plumb the browsed list's uuids from `KilterRoot` into the detail screen; host
   the existing detail body in a `HorizontalPager` with an "n / total" pill. Empty siblings (Create /
   Surprise me) → no pager.
3. **Plan a session:** port `KilterRecommender` as a pure, unit-tested core (working grade → warm-up /
   send / project spread over a candidate window) + a simple `KilterPlanScreen`; add a "Plan a session"
   More-menu entry.
4. **Distinct icons + tooltips:** Attempt → Replay, Project → Flag (no shared glyph; Project's flag no
   longer clashes with the Saved star); each log button gets a long-press RichTooltip explaining the
   status, with a one-line "What do these mean?" affordance.

## Output

New `KilterRecommender.kt`, `KilterPlanScreen.kt`; edits to `KilterClimbGenerator.kt`,
`KilterGeneratorAssets.kt`, `CreateClimbScreen.kt`, `KilterDetailScreen.kt`, `KilterRoot.kt`. New tests
`KilterRecommenderTest.kt`, `KilterManualGradeTest.kt`.

## Acceptance criteria

- [x] Manual editor shows a grade estimate that updates per hold tap; saved climbs carry it into
  detail/browse.
- [x] Swiping left/right in detail moves through the browsed list.
- [x] Plan-a-session produces a warm-up/send/project set from history (unit-tested core).
- [x] No two log actions share an icon; statuses explained in-app.
- [x] `assembleDebug` + unit suite green (`KilterRecommenderTest`, `KilterManualGradeTest`).

## Constraints

On-device only; no hardware. The recommender + grade estimate are pure so they're unit-tested without
a device. The grade model is the linear estimator from `meta.json` — no ONNX session needed.

## Test plan

1. `:app:testDebugUnitTest` (recommender + manual-grade) + `:app:assembleDebug`.
2. **Device-pending (deferred):** swipe-through, the live estimate chip, and Plan-a-session end-to-end
   need a real catalog (#42 — the app ships none) + the installed generator meta on the emulator.
