# Prompt: Festival plan & smart nudges (festival prompt 04)

**File**: pdd/prompts/features/festival/04-festival-plan-and-nudges.md
**Created**: 2026-07-17
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData + UserNotifications + FoundationModels) —
code lands in this repo only (no web-repo companion this time).
**Chain**: `pdd/prompts/features/festival/README.md` → 04 of 06 (01 MERGED #292, 02 MERGED #293,
03 open — build on the merged domain; do NOT touch the `.fpack` wire format, the matcher's
confidence semantics, or prompt 03's tag model)
**Source**: user ideation session 2026-07-16; wireframes `docs/ux-research/festival/wireframes.html`
frames 7 (lock-screen nudges) · 8 (For-You). Frames 12–13 (QR) are prompt 05, frame 14 (poster
scan) prompt 06 — do NOT build them here.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make the ★ stars *do* something. Prompts 01–02 gave stars an interval math (`FestivalPlan`) and a
schedule toggle; this prompt turns "my plan" into the phone doing the remembering: **local pre-set
reminders** fire a configurable lead before each starred set (scheduled on-device from pack times —
no push, no network, works in an airplane-mode field), **clashes** are surfaced the moment you star
two overlapping sets, and a **For-You sheet** suggests what to star next. The ranking is the pure,
fully-tested `SetRecommender` (your HR-per-artist history × the gaps in your plan × walk time ×
clash avoidance); Apple's on-device Foundation Models, WHEN available, rewrite ONLY the one-line
*why* for each suggestion (E7 contract: heuristic floor, FM refines, silent degradation). Why now:
prompt 02 shipped stars with nowhere to go, and the recommender is the keystone the whole "built
from how you dance" promise rests on.

## Context the implementer needs

- **Prompt 01's `FestivalPlan` is law and already pure-tested**: `clashes(in:)`, `reminderDates(in:
  lead:)`, and `gaps(in:)` are the inputs — this prompt is the thin scheduling/authorization edge +
  the recommender that consumes them, not new interval math.
- **Re-derive HR history from prompt 02, don't depend on the open prompt-03 branch.** Prompt 03's
  `FestivalSetStats` computes per-set HR but isn't on `main`; `FestivalAttendance` (artist + interval
  + dance-`WorkoutSession` FK, prompt 02) already says which artist you danced to and when. The thin
  `FestivalHistoryService` slices each stretch's HR out of the session's `hrSeries` and hands the
  pure `FestivalHRHistory` value `Sample`s — cross-festival, keyed by normalized artist name.
- **Reuse the E7 wrapper pattern.** `Services/WorkoutPlanIntelligence.swift` is the locked seam:
  `#if canImport(FoundationModels)` + `@available(iOS 26.0, *)` + `SystemLanguageModel.default
  .isAvailable`, a `@Generable` output, a `withTimeout` guard, and silent degradation to the
  heuristic. `FestivalPlanIntelligence` is a thin festival-specific adapter of exactly that shape —
  it rewrites only the reason string, never the ranking or the facts.
- **Reuse the notification pattern.** `Services/WorkoutNotifications.swift` is the posture: the ONLY
  festival file that imports `UserNotifications`, every entry a no-op when unavailable/unauthorized,
  the copy built by pure `nonisolated static` functions. Permission is asked from a **deliberate**
  surface (the For-You sheet), never on schedule appearance — so the existing schedule UI tests
  never hit a system dialog.
- **No new persistent model.** Stars/attendance already exist; the lead time is a plain
  `@AppStorage` preference. So NO `SnappetSchema`/`SnappetBackup` change (the backup tripwire stays
  quiet).

## Approach

All in `ios/App/Snappet/Features/Festival/`, pure logic separated from thin edges:

- **`FestivalHRHistory.swift`** (pure) — per-artist affinity from value `Sample`s: max peak, danced-
  seconds-weighted avg, session count, most-recent festival (the "at Coachella '26" clause), plus
  festival-wide priors; `sample(...)` slices `(t, bpm)` points to an attendance window.
- **`SetRecommender.swift`** (pure keystone) — ranks unstarred, clash-free, still-upcoming sets by a
  deterministic weighted sum (affinity ≫ gap-fill > same-stage-walk > a base floor), dropping any
  candidate that overlaps a star. Each `Suggestion` carries a machine-readable `Reason`
  (`.heardBefore` / `.fillsGap` / `.sameStage` / `.freshPick`) and a `templateReason` — the floor
  line the sheet always shows.
- **`FestivalPlanIntelligence.swift`** (thin FM edge) — `reasonLines(for:)` returns one `Line` per
  suggestion, index-for-index; when on-device FM is available it rewrites each template into warmer
  prose from the same facts, else returns the templates with `.template` source. Never reorders,
  never invents.
- **`FestivalNotifications.swift`** (thin edge + pure copy) — `reschedule(plan:pack:leadMinutes:)`
  (clear this pack's reminders, add one per future star), `postClashAlert`, `clear(pack:)`, and pure
  `reminderPlan` / `reminderContent` (with the cross-stage walk hint) / `clashContent` / `leadLabel`.
- **`FestivalHistoryService.swift`** (thin @MainActor edge) — fetch attendance + sessions + lineups,
  slice HR, build `FestivalHRHistory`.
- **`FestivalForYouView.swift`** (sheet, frame 8) — hero, ranked cards (＋★ add, reason line + glyph),
  a lead-time menu bound to `@AppStorage`, a privacy card. Its own `NavigationStack` (a sheet may).
- **`FestivalScheduleView`** grows a ✨ toolbar button → the sheet, reschedules reminders on the
  schedule's `.task` and on every star toggle, and fires a lock-screen clash alert when a new star
  overlaps an existing one (the ⚠︎ marks from prompt 02 remain the in-app indicator).
- **`FestivalPlanSeed.swift`** + `-uiTestSeedFestivalPlan`: the lineup + a pre-star + a past dance
  session with synthetic HR for an artist who plays again, so For-You ranks a real `.heardBefore`.

## Output

- `ios/App/Snappet/Features/Festival/` — `FestivalHRHistory`, `SetRecommender`,
  `FestivalPlanIntelligence`, `FestivalNotifications`, `FestivalHistoryService`,
  `FestivalForYouView`, `FestivalPlanSeed`; entry points wired in `FestivalScheduleView` +
  `FestivalRootView` (delete clears reminders)
- Central wiring: `SnappetApp` (the plan-seed arg) — no schema/backup change
- Tests: `SetRecommenderTests`, `FestivalHRHistoryTests`, `FestivalNotificationsTests`,
  `FestivalPlanIntelligenceTests` (the degrade path), `FestivalPlanSeedTests`
- `ios/App/SnappetUITests/FestivalUITests.swift` — the For-You walkthrough (open ✨ → an
  HR-history suggestion → ＋★ drops it → lead control)
- `docs/knowledge-graph/data.js` — For-You sheet, recommender, HR-history, notifications, FM-adapter
  nodes + edges (plan → notifications; HR history + gaps → recommender → For-You → FM reasons)
- `pdd/context/decisions.md` — same-day entry for the non-obvious calls

## Acceptance criteria

- [ ] Starring a set schedules a local reminder a configurable lead before its start (future sets
      only), with a cross-stage walk hint; unstarring / reinstalling reschedules idempotently.
- [ ] Starring a set that overlaps an existing star fires a clash alert built from
      `FestivalPlan.clashes`; the ⚠︎ marks still flag both rows.
- [ ] `SetRecommender` ranks deterministically, never suggests a starred / past / plan-clashing set,
      and an artist from your HR history leads with a `.heardBefore` reason.
- [ ] The For-You sheet shows ranked cards with template reasons; with FM available only the reason
      line changes; no entitlement ⇒ identical cards, template reasons (the degrade path is tested).
- [ ] Unit suite green; full XCUITest suite green (real UI); 0 Swift 6 warnings; `HighlightEngine`
      untouched; no `.fpack` / matcher / prompt-03 tag-model change.
- [ ] Knowledge graph + `decisions.md` updated in the same change.

## Constraints

- On-device only: no push service, no network, no server LLM, no Anthropic SDK. FM is Apple's
  on-device Foundation Models, gated + degrading to templates when unavailable.
- Do not touch the `.fpack` wire format, the matcher's confidence semantics, prompt 03's tag model,
  or `HighlightEngine`.
- No QR (prompt 05) or poster scan (prompt 06).
- Verification honesty: real notification delivery timing in the field, on-device FM output, and
  watch-HR-fed recommendations during a live set are device legs — state them owed, not verified.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — recommender ranking table, HR aggregation +
   slicing, reminder plan / walk hint / clash copy / lead math, the FM-unavailable degrade path,
   the plan seed's history → suggestion.
2. `make ios-test SIMULATOR='iPhone 17 Pro'` — full suite incl. the seeded For-You walkthrough.
3. Device (owed): star a set, background the app, confirm the reminder fires with the walk hint; on
   an Apple-Intelligence device confirm the reason lines read as prose; dance a real set and confirm
   its HR feeds the next festival's suggestions.
