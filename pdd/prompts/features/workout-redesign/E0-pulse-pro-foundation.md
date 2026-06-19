# Prompt: E0 — Pulse Pro foundation (design system + shared scaffold + IA)

**File**: pdd/prompts/features/workout-redesign/E0-pulse-pro-foundation.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `workout-redesign/PLAN.md` → E0 (wave 1, the foundation every other phase consumes)
**Design**: `docs/ux-research/workout-redesign/README.md` §3, §6; `wireframes.html` Flow 0 (foundation)
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (2026-06-19 entry)

## Goal

Lay the **Pulse Pro** foundation so E1/E2 (and later phases) render in one creative-but-non-rebrand language:
a second color axis (a performance ramp distinct from the discipline accents), a reusable **type-adaptive
recap scaffold**, score-first hero + glass-on-chrome chrome, and the pure stat seams the dashboard/detail
will consume. No behavior change to logging or the model — this is tokens + components + IA.

## Context the implementer needs

- Tokens live in `ios/App/Snappet/DesignSystem/` (`SnappetColor.swift` — the Pulse ramp + per-module accents
  incl. `workout` ember / `kilter` amber; `SnappetCard`, `SnappetMotion`, `SnappetRadius`, `SnappetSpacing`,
  `CelebrationBurst`, `Haptics`). The discipline accents already exist; there is **no** performance ramp yet.
- The type-adaptive recap already exists once, as `FreeformDoneSummaryView` (`Features/WorkoutTracker/`,
  hero strip + per-discipline `adaptiveCards`) + the pure `FreeformSummary.dominant/.stats`. E2 must reuse a
  *shared* version of this, so extract it here.
- `WorkoutDiscipline` (`Features/WorkoutTracker/WorkoutDiscipline.swift`) is the entity axis (label/symbol/
  primaryAxis). The dashboard's streak/volume math is inline in `WorkoutDashboardSection.swift:253-298` (a
  4th coexisting streak definition — unify it).
- The Gym Tracker IA is a top segmented `Picker` (`WorkoutTrackerModule.swift:104-110`, cases
  `dashboard/browse/routines/history`, ids carry XCUITest a11y `workout.sectionPicker`). The rename to
  **Library** is display-only here (keep the `browse` case id stable).

## Approach

- **Tokens:** add a performance ramp to `SnappetColor` (e.g. `perfFresh = leaf 0x3F9D55`, `perfModerate =
  amber 0xB45309`, `perfHard = tomato 0xE5483D`, dark variants) + a doc comment stating the **two-axis
  contract** (discipline accent = wayfinding; perf ramp = effort/zone/PR; `brand` coral = the single primary
  CTA). A `HeartRateZone`→perf-ramp mapping helper.
- **Hero + chrome components** (`Features/WorkoutTracker/PulsePro/` or `DesignSystem/`): a `DisciplineHero`
  (oversized rounded numeral + caption + accent halo, reduce-motion-aware), a `StatRibbon` (the rolled-up
  per-discipline chips), and a `GlassChrome` modifier (`.ultraThinMaterial` on floating bars with a solid
  `surface`+hairline fallback for pre-iOS-26).
- **Shared recap scaffold:** extract `SessionRecap` (hero slot · secondary-viz slot · breakdown slot ·
  celebration slot) from `FreeformDoneSummaryView`, re-point `FreeformDoneSummaryView` onto it with **no
  behavior change** (the isolation move — verify against its existing UITest before E2 rides it).
- **Pure stat seams:** `WorkoutDashboardStats` (streak/this-week/per-discipline counts/total time) and a stub
  `WorkoutHistoryStats` (per-muscle volume/recency placeholders E7 fills), both pure value types, replacing
  the inline dashboard math.
- **IA:** rename the `browse` segment display to **Library** (id unchanged); no nav restructure.

## Output

- `SnappetColor` perf-ramp tokens + contract doc; a `HeartRateZone`→ramp helper.
- `DisciplineHero`, `StatRibbon`, `GlassChrome` (+ a small `PulseProTokens` doc).
- `SessionRecap` scaffold; `FreeformDoneSummaryView` re-pointed onto it (no behavior change).
- `WorkoutDashboardStats` (+ tests); `WorkoutHistoryStats` skeleton (+ tests).
- Library display rename.

## Acceptance criteria

- [ ] `WorkoutDashboardStats` / `WorkoutHistoryStats` are pure value types with unit tests (streak parity
      with the old inline math; per-discipline counts).
- [ ] `FreeformDoneSummaryView` renders identically after re-pointing onto `SessionRecap` (its UITest stays green).
- [ ] The two-axis contract is documented in `SnappetColor` + `decisions.md`; coral is used for ≤1 primary CTA per surface.
- [ ] App type-checks against the iOS 18 SDK (Swift 6, 0 warnings); no platform imports added to `HighlightEngine`.
- [ ] `workout.sectionPicker` a11y id + the `browse` case id are unchanged (UI suite stays green).

## Constraints

- On-device only; no new network. Tokens + components only — no logging/model/behavior change.
- Glass must degrade to a solid `surface`+hairline fallback (pre-iOS-26 ≈ 85%).

## Test plan

1. `xcodebuild build` + `SnappetTests` (the new pure stats) green; `swift test` if the engine is touched (it isn't).
2. Run the existing `FreeformDoneSummaryView`/workout UITests — unchanged behavior.
3. Eyeball Flow 0 of `wireframes.html` against the rendered components (light + dark) for the two-axis contract.
