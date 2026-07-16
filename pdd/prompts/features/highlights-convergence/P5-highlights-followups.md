# Prompt: Highlights follow-up trio — the Health offer, honest reel rows, the hero card (P5)

**File**: pdd/prompts/features/highlights-convergence/P5-highlights-followups.md
**Created**: 2026-07-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: highlights convergence follow-up (P1–P4 shipped in PR #288, `5f2b9ad`) — the three
small items its decisions.md entry (2026-07-15) left open.
**Source**: P1–P4 review + decisions.md 2026-07-15 ("HealthKit read priming is a KNOWN GAP,
deliberately not patched at launch")
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Close the three deliberate leftovers of the highlights convergence in one small PR: (1) the
fresh-install **HealthKit read-priming gap** — the retired Workout Reels onboarding was the only
surface that requested Health read access, and without it the watch→Clips import silently returns
nothing — closed by a **contextual, dismissible "Connect Apple Health" offer in Clips** (never a
launch-path request; that was tried and REVERTED); (2) posted reels stop leaking into **editing**
surfaces — a rendered reel is an output, not an input, so it leaves the Studio's seeded timeline
and stops reading as a plain "General" clip in the session detail's media list; (3) the compact
`WeeklyReelHeroCard` grows into the **wireframe's coral-gradient hero** (screen 1,
`docs/ux-research/workout-reels-v2/wireframes.html`) without touching the feed's scroll budget.

## Context the implementer needs

- **The reverted trap (do not re-trip it):** requesting Health authorization inside
  `AppModel.reconcileWatchWorkouts()` fires on every launch until answered — an unsolicited system
  sheet at first open that violates the value-first permissions rule and races UI tests. The offer
  must request ONLY from an explicit user tap. HealthKit read-auth status is **not queryable**
  (Apple hides read grants), so the gate is a persisted asked/dismissed flag + "no watch-imported
  session exists yet" (`WorkoutSession.isFromAppleWatch`), not an auth check.
- `-uiTestFreshStore` resets SwiftData but NOT UserDefaults; test-deterministic `@AppStorage` keys
  are cleared explicitly in `SnappetApp.init` (the `expense.myName` / `freeform.*` precedent) — the
  new flag needs the same treatment.
- Reel rows = `SessionMedia` with `reelTitle != nil` (`isReel`). The reel-of-reel INPUT filters
  already exist (`ReelSource.workoutSession`/`.kilterSession`, `WeeklyReelHostView`); the leaks are
  the Studio timeline seeds — `StudioEntry.seedClips` + its `resolveProject` late-clip reconcile +
  the Kilter mirror (`KilterSessionDetailView.resolveStudioProject`) — and the counting helpers
  (`videoCounts`, `SessionDetailView.hasVideo`) that decide whether "Edit in Video Studio" /
  dashboard candidates light up. Excluding reels from the seed but not the counts would offer a
  Studio that opens onto an empty timeline for a reel-only session.
- The hero card must stay **render-cheap**: it sits in the feed's `LazyVStack` scroll path, so
  decorative gradients/shapes only — no players, no thumbnails, no live blur (the prompt 92/97
  perf discipline). Keep the `clips.weeklyReel` identifier and the `WeeklyReelRoute` push.

## Approach

**1 — Contextual "Connect Apple Health" offer in Clips.**
Pure `ClipsHealthOffer` (Features/Feed): `shouldShow(hasWatchImportedSession:resolved:)` — show
only while NO watch-imported session exists AND the user has neither connected nor dismissed.
`ClipsFeedView` renders a dismissible card (top of the feed, and above the empty state — the
fresh-install case it exists for) gated by `@AppStorage("clips.healthOffer.resolved")` + the
existing `workoutSessions` query. The card explains the value (Apple Watch workouts appear in
Clips automatically); **Connect** marks the flag resolved, calls `app.health.requestAuthorization()`
and then `app.reconcileWatchWorkouts()`; **✕** just marks it resolved. Either way the card never
returns (auth status isn't queryable — asked is as good as answered). `SnappetApp` clears the key
under a fresh-store launch so UI tests stay deterministic; the system sheet fires only from the tap.

**2 — Posted reels leave the editing surfaces.**
`StudioEntry`: `seedClips`, `videoCounts`, and `resolveProject`'s late-clip reconcile all skip
`isReel` rows; same for the Kilter mirror's seed + reconcile. `SessionDetailView`: `hasVideo`
counts non-reel videos; a reel's media row shows its `reelTitle` + a small ✦ REEL chip
(reels-coral, the feed badge's look) instead of "Video · tap to edit", and drops the tap-to-edit /
"Edit in studio" affordances (the Studio no longer knows the clip) — Remove stays.

**3 — Weekly hero toward the wireframe.**
`WeeklyReelHeroCard` becomes the screen-1 drop card: dark coral-gradient canvas with decorative
radial glows, the ✦ WEEKLY HIGHLIGHTS tag, a centred play badge, a mini filmstrip strip (6 static
gradient frames — decoration, not thumbnails), and the title/subtitle meta. Same NavigationLink,
same `clips.weeklyReel` id, no new queries.

## Output

- `ios/App/Snappet/Features/Feed/ClipsHealthOffer.swift` (pure) + the offer card in
  `ClipsFeedView.swift`; the key reset in `SnappetApp.swift`.
- Reel exclusions in `StudioEntry.swift`, `KilterSessionDetailView.swift`; the ✦ REEL media row +
  `hasVideo` fix in `SessionDetailView.swift`.
- The upgraded `WeeklyReelHeroCard` in `ClipsFeedView.swift`.
- Tests: `ClipsHealthOfferTests.swift` (new); reel-exclusion cases in `StudioEntryTests.swift`.
- `pdd/context/decisions.md` entry + knowledge-graph updates in the same change.

## Acceptance criteria

- [ ] Fresh install (no watch imports, flag unset): Clips shows the offer card — on the empty
      state and atop a non-empty feed; Connect fires the Health sheet FROM THE TAP ONLY, then
      reconciles watch workouts; ✕ dismisses; neither state ever shows the card again; a store
      with a watch-imported session never shows it.
- [ ] No permission request is added to any launch/reconcile path (the reverted trap stays out).
- [ ] `StudioEntry.seedClips`/`resolveProject`/Kilter's reconcile never seed or append a reel row;
      a reel-only session offers neither "Edit in Video Studio" nor a Studio dashboard candidate.
- [ ] The session detail's reel row reads ✦ REEL with its title and is not tap-editable; Remove
      still works.
- [ ] The weekly hero renders the coral-gradient + filmstrip treatment, keeps `clips.weeklyReel`,
      and adds no players/thumbnails/live blur to the scroll path.
- [ ] App type-checks (iOS 18 SDK, Swift 6); unit suite green; `HighlightEngine` untouched.
- [ ] `decisions.md` + knowledge graph updated in the same change.

## Constraints

- On-device only; `HighlightEngine` untouched; no new permission requests outside an explicit tap.
- Additive persistence only — the flag is UserDefaults (`@AppStorage`), no SwiftData schema change.
- Honest verification: the Health sheet + watch import need a device; sim verifies gating/layout.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — unit suite incl. `ClipsHealthOfferTests` +
   the `StudioEntryTests` reel cases.
2. `make ios-sim SIMULATOR='iPhone 17 Pro'` — full app build; then the affected XCUITest suites
   (`ClipsFeedUITests`, `LiveWorkoutStudioWalkthroughTests`) — real UI changed. If a run wedges
   with "Failed to synthesize event": `xcrun simctl shutdown all` and re-run.
3. **Device leg (MrRobot, phone UNLOCKED — a locked phone fails the DDI mount and `devicectl`
   can exit 0 through a pipe; verify with `devicectl device info apps`):** fresh-ish state →
   Clips shows the offer → Connect pops the Health sheet → grant → watch workouts appear; posted
   reel shows ✦ REEL in the session detail and stays out of the Studio timeline; weekly hero
   renders the new treatment and still opens the builder.
