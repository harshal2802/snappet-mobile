# Prompt: Festival — guided getting started (first-run onboarding)

**File**: pdd/prompts/features/festival/07-festival-getting-started.md
**Created**: 2026-07-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Festival mini-app chain (`pdd/prompts/features/festival/README.md`) → prompt 07, a
post-chain addition on top of P1–P6 (all merged on `main`).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (unchanged — this prompt adds NO model)

## Goal

The whole Festival feature ships (lineups, ★ plan, reminders, tagging, reels, recap, QR + poster
scan), but a brand-new user's first sight of the module is a blank "download a lineup" empty state —
no sense of what the app *does* or why to bother. Add a **guided on-ramp**: a short value tour shown
once, then a setup checklist that stands in for the empty state and walks the user through their
first real actions. This adds **no new capability** — it reuses the existing catalog install, the ★
plan, and set reminders — it just orients. Non-blocking and skippable at every step; never seen
twice.

Design is already wireframed and **user-approved**: `docs/ux-research/festival/getting-started/`
(`wireframes.html` + `.png`). Do not redesign — those frames are the source of truth.

## Context the implementer needs

The shape, in two parts (wireframe frames 1–6):

1. **A 3-card value tour**, shown once on first open of the module — a welcome cover ("Plan it.
   Dance it. Keep it." + offline / on-device / watch-HR posture chips + one UV-orchid CTA and a plain
   Skip), then three teaching cards (*get the lineup* · *star your plan* · *capture the night*).
   Skippable everywhere; ends on one CTA into the checklist. The cards **teach**; they don't act.
2. **A guided setup checklist that REPLACES the blank empty state** — three real steps (① add a
   lineup → ② star a few sets → ③ turn on set reminders) with a progress bar; step 1 active, 2–3
   unlock as completed. Primary CTA stays "Add a lineup" (the existing empty-state action); "I'll
   explore on my own" dismisses to the plain empty state. After the first lineup installs, the
   checklist **collapses to a dismissible banner** (progress ring + next-step nudge + ✕) riding above
   the day schedule, gone for good once all three steps are done or it's dismissed.

Files this touches: `FestivalRootView` (tour + full-checklist choice), `FestivalCatalogViews`
(`FestivalEmptyStateView` it replaces), `FestivalScheduleView` (the banner above the day list),
`FestivalNotifications` (the reminders-on notion), `SnappetApp` (UI-test flag control).

## Approach

- **The keystone is a pure value type, `FestivalGettingStarted`** (new file
  `Features/Festival/FestivalGettingStarted.swift`). Inputs are plain: `tourSeen`,
  `checklistDismissed`, `lineupCount`, `starCount`, `remindersEnabled`. It computes the whole surface
  decision — `showTour`, `checklist` (`.full` / `.banner` / `.hidden`), each `Step`'s state
  (`.done` / `.activeNext` / `.locked`), `completedCount`, `progressFraction`, `nextStep`,
  `isComplete`, `isFinished`. No SwiftUI / SwiftData / persistence — the festival "pure logic at a
  thin edge" rule (prompts 01 / 03 / 04). Every combination unit-tests in `SnappetTests` with no
  simulator.
- **Thin SwiftUI renderers** over it (new file `FestivalGettingStartedViews.swift`): `FestivalTourView`
  (rendered inline as the root while `showTour` — no sheet, dodging the suite's dismiss-then-present
  races; hide the nav bar while it shows), `FestivalSetupChecklistView` (the empty-state
  replacement), `FestivalGettingStartedBanner` (above the schedule day list).
- **Persist only two flags via `@AppStorage`** — `festival.tourSeen`,
  `festival.gettingStartedDismissed` — NOT SwiftData (the prompt-04 lead-time precedent; NO
  `SnappetSchema` / `SnappetBackup` change). The other three inputs are DERIVED: `lineupCount` /
  `starCount` from unfiltered `@Query`s; `remindersEnabled` from `FestivalNotifications`'
  authorization status (prompt 04's notion of reminders-on — the For-You sheet is where it's
  requested; do not invent a parallel flag). Add a small `authorizationGranted()` reader to
  `FestivalNotifications`.
- **Deep-link to surfaces that already ship**: step 1 → the existing browse / poster-scan /
  friend's-QR add-lineup actions (a confirmationDialog on the checklist CTA reusing the root's
  closures); step 2 → the day schedule (where ★ toggles live); step 3 → the reminders control (the
  For-You lead-time sheet, which also requests auth). Reuse those entry points; do not duplicate.
- **UI-test control** in `SnappetApp`: onboarding rides `@AppStorage`, which survives the in-memory
  store swap. Default every UI-test launch PAST onboarding (so the existing festival tests still
  assert the empty state / schedule directly); the onboarding tests opt IN with a new
  `-uiTestFestivalOnboarding` arg (combinable with the lineup seed to reach the banner).

## Output

- `Features/Festival/FestivalGettingStarted.swift` — the pure state type.
- `Features/Festival/FestivalGettingStartedViews.swift` — tour + checklist + banner renderers.
- `FestivalNotifications.authorizationGranted()` — the reminders-on reader.
- `FestivalRootView` — tour / full-checklist / empty-state / lineup-list branching + the two
  `@AppStorage` flags + derived `starCount` + `remindersEnabled`.
- `FestivalScheduleView` — the collapsed banner above the day list.
- `SnappetApp` — the `-uiTestFestivalOnboarding` opt-in (else bypass onboarding under test).
- `SnappetTests/FestivalGettingStartedTests.swift` — the state machine, every combination.
- `SnappetUITests/FestivalUITests.swift` — tour → checklist → dismiss (+ tour-once), and
  lineup-seed → banner → dismiss.
- `docs/knowledge-graph/data.js` — the three onboarding surfaces + the pure type + edges.
- `pdd/context/decisions.md` — the non-obvious calls (dated 2026-07-19).

## Acceptance criteria

- [ ] First open of the module shows the 3-card tour once; Skip / Get started both end it and it
      never returns (a `@AppStorage` flag, not per-launch).
- [ ] With no lineup, the setup checklist replaces the empty state; "I'll explore on my own" falls
      through to the plain empty state; the primary CTA is still "Add a lineup".
- [ ] After the first lineup installs, the checklist collapses to a dismissible banner above the day
      schedule; ✕ retires it; it also disappears once all three steps are done.
- [ ] `FestivalGettingStarted` is pure and unit-tested across fresh install, tour-skipped,
      lineup-but-no-stars, all-done, dismissed-early, and re-install-after-complete.
- [ ] NO `SnappetSchema` / `SnappetBackup` change (two `@AppStorage` flags only).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 source warnings).
- [ ] No platform imports added to `HighlightEngine` (untouched).
- [ ] `decisions.md` + the knowledge graph updated.

## Constraints

- On-device only; no backend / network / accounts. Reuse the shipped install / ★ / reminders — add
  no capability.
- Use `SnappetColor.festival` (UV orchid) throughout; coral is not used here.
- Keep the state pure at a thin edge; the views render values, they don't decide.

## Test plan

1. `make -C <repo root> ios-test-unit SIMULATOR='iPhone 17 Pro'` — the full unit bundle incl.
   `FestivalGettingStartedTests` (every surface combination) is green.
2. The `FestivalUITests` onboarding slice: tour → checklist → dismiss (+ re-open shows no tour), and
   `-uiTestSeedFestivalLineup -uiTestFestivalOnboarding` → banner → ✕. The existing festival UI
   tests still pass (they launch past onboarding).
3. Device leg owed: completing step 3 (turning on real notification authorization) drives a system
   permission dialog — verify banner-retires-on-complete on a device.
