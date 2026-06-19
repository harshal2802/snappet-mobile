# Workout-Type Parity — bring every type up to the climbing structure

> **Snappet Mobile** · Quick Session (freeform) · 2026-06-18
>
> Follow-on to the **climb-first Quick Session redesign** (PR #175). That change gave *climbing* a rich
> entity-then-effort structure. This one brings **Strength, Running, Dance & Other** to the same
> structure, makes **timing an orthogonal axis** (any set can be reps × weight **and** timed), and gives
> **clips/photos** the same per-set + entity-level attach across every discipline.
>
> | File | What it is |
> |------|------------|
> | **README.md** (this) | The design + phased implementation plan. |
> | **[wireframes.html](./wireframes.html)** | **Open in a browser** — 13 real-looking iPhone surfaces (incl. a media flow) across all types. The visual deliverable. |
> | **[wireframes/workout-type-parity.png](./wireframes/workout-type-parity.png)** | Rendered PNG of the same (real `SnappetColor` tokens, 2×). |
>
> *Every `file:line` below was verified against source by an adversarial review pass. All paths are under
> `ios/App/Snappet/Features/WorkoutTracker/` unless noted.*

---

## TL;DR

**The problem.** The climb redesign proved a great pattern — a named, typed **entity** whose **efforts** log
underneath it in an expandable card, with last-time prefill, a live stats ribbon, per-set clips, and a
type-adaptive summary. That richness is **uneven** across the other types in the same freeform session:

- **Strength** is a *flat, always-open List section* (`liftingOrTimedSection`, `FreeformPlayerView.swift:577-648`) —
  no entity card, no collapse, no rolled-up header; and adding an exercise *drops its target sets/reps/weight*
  (`addLifting` hardcodes `targetSets: 0, targetReps: ""`, `FreeformPlayerView.swift:1070-1078`).
- **Timed** (`.duration`) *already is* a climb-style card (`timedSection`, `:480-484, 496`) — but its sets
  render flat (no expand) and it carries no live ribbon. (So the deficit is **not** "climbing-only"; it's
  strength being flat + the missing disciplines below.)
- **Running, Dance, Other** *don't exist* as disciplines — `SetKind` has only
  `repsWeight / duration / climbAttempt` (`WorkoutModels.swift:179-202`). A run can only masquerade as a bare
  timer or fake reps.
- **Timing is a separate top-level type**, so a strength set can never *also* be timed — even though the
  storage field for it already exists.

**The fix — one move above all others: split the monolithic `SetKind` into two orthogonal axes.** A
**discipline** on the entity (climb / strength / run / dance / timed / other) and **measurement axes** on
each effort (reps · weight · *duration* · distance/pace · outcome). A `SetLog` already carries reps, weight
*and* duration simultaneously (`WorkoutModels.swift:226-238`, all `Optional`, no per-kind gating), so
"8 × 60 kg · 0:42" is just *two axes present* — and climbing *already ships exactly this combined row*
(`SetMeasure.summary` `.climbAttempt`, `SetMeasure.swift:36`). Once efforts are axis-based and the climb card
is extracted into a discipline-parameterized component, "timed strength," "weighted hang," "run with pace,"
and "dance for time" all fall out of the same plumbing.

**Migration-free at the SwiftData layer.** Every new field is an additive `Optional` on the existing Codable
composites (`SetLog` / `SessionExercise`), so lightweight migration applies with no schema work — the
documented invariant at `WorkoutModels.swift:220-225`, which **also** holds for backup
(`SnappetBackup.WorkoutSessionRow` stores `exercises: [SessionExercise]` whole, so new fields round-trip for
free). *Caveat:* the backup **golden-byte tests** and **Android's** parallel store are not free — see §8.

**Media is mostly already done.** The capture + auto-assignment pipeline is **discipline-agnostic today**:
`SessionMediaAssignment.completions` flattens *all* sets by completion time and never inspects kind
(`SessionMediaAssignment.swift:38-49`), and `SetMediaStrip` files clips against `(exerciseID, setIndex)`
(`SetMediaStrip.swift:53-55`). Parity is small — see §5.

---

## 1. Decisions locked with the user (2026-06-18)

| Question | Decision |
|----------|----------|
| **Which types reach full parity now?** | **All four** — Strength, Running/cardio, Dance, Other. |
| **How does adding a strength exercise work?** | **Hybrid** — keep the fast bulk multi-select catalog, add an optional per-exercise default `sets × reps × weight × unit` (the `⚙` affordance). |
| **How does "timed" work across types?** | **Orthogonal** — keep the standalone **Timed** discipline (hangboard / Tabata / EMOM structured runs) **and** add "⏱ Time this set" to any strength/run/other effort. |
| **Running metric depth (implied)** | **v1 = manual distance + duration → derived pace** + time-in-HR-zone. **GPS / splits / route is a fast-follow** (needs a location series `WorkoutSession` lacks, `:404`). |

---

## 2. The unifying abstraction — two axes, one card

Today `SetKind` does *two unrelated jobs at once*: "what discipline is this entity" **and** "what does each
effort measure." Splitting them is the spine of the whole change.

```
            BEFORE                                AFTER
  SessionExercise.kind: SetKind        SessionExercise.discipline: WorkoutDiscipline   (entity axis)
    .repsWeight | .duration              .strength | .climb | .run | .dance | .timed | .other
    | .climbAttempt                          ↓ drives icon · add-sheet · card chrome · summary · rest · HK type

  one SetLog rendered by `kind`        SetLog populates ANY combination of effort axes   (effort axes)
                                         reps · weight · duration · distance/pace · outcome
                                         → SetMeasure renders "whichever axes are present, joined by ·"
```

- **① Discipline (on the entity).** A new `WorkoutDiscipline` raw value on `SessionExercise` drives icon,
  add-sheet, card chrome, summary branch, rest context, **and the watch HK workout type** (§8 cross-cutting).
  `kindRaw` is kept for back-compat (legacy/`nil` ⇒ derive: `.repsWeight→.strength`, `.duration→.timed`,
  `.climbAttempt→.climb`).
- **② Measurement axes (on the effort).** `SetLog` is *already* an all-optional union of every kind's fields.
  A leaf "has reps & weight AND is timed" simply by populating `actualReps`/`actualWeight` **and**
  `durationSec`. `SetMeasure.summary` becomes "render whichever axes are present."
- **③ One card component.** Extract `climbSection`/`climbHeader`/`climbFooter`
  (`:658-695` / `:701-751` / `:811-861`) into a discipline-parameterized `EntitySection`.

**Why it's safe, not a rewrite:** `SessionExercise` (`:242-314`) is *already one struct that hosts all three
kinds*; the codebase already proves the two patterns we generalize — the combined timed+categorical row
(`SetMeasure.swift:36`) and orthogonal timing (`RestTimerDefaults.Context` already buckets
climb/timed/lifting, `RestTimerDefaults.swift:17-42`). We extend validated patterns.

---

## 3. Data-model changes (all additive `Optional` → no SwiftData migration)

New keys on existing **Codable composites** inside `WorkoutSession.exercises`. Synthesized `Codable` decodes a
*missing* optional key as `nil` (invariant at `WorkoutModels.swift:220-225`). No `SnappetSchema` change unless
a new `@Model` is added — we add **none** in v1 (the deferred per-entity history table, §10, would).

**`SetLog` (`WorkoutModels.swift:226-238`) — new effort axes:**
- `distanceMeters: Double?` — running/cardio distance. **Pace is derived** (`distanceMeters` + `durationSec`),
  not stored, to avoid drift. Needs a `DistanceUnit` (km/mi) decision — a *new* `SetMeasure` branch, not just
  a tweak (see §6).
- `rpe: Int?` — optional effort rating for strength/timed (parallels climbing's outcome).
- *(reps + weight + `durationSec` already coexist — combining them is a formatter + UI change.)*

**`SessionExercise` (`WorkoutModels.swift:242-314`) — discipline + generic metadata:**
- `disciplineRaw: String?` — the new entity axis (`nil` ⇒ derive from `kind`).
- `notesText: String?`, `location: String?`, `tags: [String]?` — generalize the climb's `gym`/`wall`.
- A kind-agnostic `bestResult` rollup (generalize `resolvedClimbStatus`, `:307-313`).
- **Reuse the existing `target*` columns** (`targetSets` 245 / `targetReps` 246 / `targetWeight` 248 /
  `targetWeightUnit` 249) for the strength default prescription. ⚠ **They are NOT unconditionally free** — the
  guided routine player reads `targetReps`/`targetWeight` (`WorkoutPlayerView.swift:39-40, 573-576`). In
  freeform they're unused (`addLifting` zeroes them), but the **prefill precedence** (a `⚙` default vs the
  last *actual* logged set from `LastSetLookup`, `LastSetLookup.swift:32`) must be specified — see §10.

**New value type — `WorkoutDiscipline`** (mirrors `ClimbType`'s shape: rawValue + symbol + accent + default
effort axes + HK activity type). The timed spec is already universal: `timedSpecData` (`:284`) lives on every
`SessionExercise` — it's just only *read* when `kind == .duration` today; reading it for any discipline is a
routing change.

---

## 4. Per-type design

### Strength — wireframe steps 1–4
- **Hybrid add (step 2).** Keep `ExercisePickerView`'s multi-select speed; each picked exercise gets a `⚙` to
  set a default `sets × reps × weight × unit` (stored in `target*`). Returns a testable `AddStrengthParams`,
  feeds one `addStrengthFromSheet` (the `AddClimbParams`/`addClimbFromSheet` pattern). Skipping `⚙` is fine —
  the card prefills last time.
- **Rich entity card (steps 3–4).** Collapsed rollup = **top set · set count · e1RM PR**. Expanded = set rows
  (top set highlighted) + the keyboard-free `QuickAddRow` ± stepper (`:1624-1684`, seeded from the last set,
  **+ inline unit toggle** which it lacks today) + footer `+ Add set` / `⏱ Time this set` / `↻ Repeat`.
  Checkmark auto-starts a remembered rest timer.
- **Inline edit-existing-entity** — strength gets an `updateStrength`/edit sheet mirroring climbing's
  `updateClimb` + `EditClimbTarget` (`:1134-1152`): rename, change default, change unit — keeping logged sets.
  (Missing from v0 of this plan; now in scope. Wireframe TODO, see §10.)

### Timed as an orthogonal axis — steps 5–6
- **"⏱ Time this set"** opens a generalized `TimedAttemptCover` (its header is climb-hardcoded today; **audit
  the whole cover, not just the header** — it also has climb load/outcome logic). The load stays pre-locked;
  the count-up ring measures TUT; **Stop & Log** writes `durationSec` *beside* reps/weight → "8 × 60 kg · 0:42".
- **Two mentalities.** A timed *effort* defaults to **count-up** (open TUT). It may opt into **count-down**
  only when there's a *prescribed target hold* (a 30 s plank / a fixed hang) — same `StopwatchView.arm(target:)`
  capability. The standalone **Timed** discipline keeps the count-down **structured runner**
  (`StructuredTimedRunner` + `IntervalSchedule`, both type-agnostic in `Shared/`) for hangboard/Tabata/EMOM.
- **Consolidate** the two existing climb-timing entry points (`TimedAttemptCover` + the in-`LogSetSheet` "Time
  the attempt" toggle) into the one generalized cover so we don't add a third parallel impl.

### Running / cardio — step 7
- New discipline; hero = **distance**. v1 add-sheet captures **distance + duration → derived pace** (manual).
  HR engine is type-agnostic, so **time-in-zone** (`ZoneBar`, `WorkoutHRStats`) paints for free. "Log a leg"
  appends efforts under the run entity.
- **GPS / live splits / route = fast-follow** — needs a location series on `WorkoutSession` (it has only
  `hrSeries`, `:404`); the one genuinely large piece, deferred.

### Dance / Other — step 8
- The **lightest** disciplines: default to a single **open count-up** (hero = Duration) + live HR. The entity
  grammar is *offered* ("Name a routine" / "Time a piece") only once the user logs a second thing, so a quick
  one-off never hits forced hierarchy.

---

## 5. Media (clips & photos) — every type — wireframe steps 11–13

**The pipeline is already discipline-agnostic.** A clip filmed mid-set auto-files to whichever effort was
running at capture time — `SessionMediaAssignment.completions(from: exercises…)` flattens *all* sets by
completion offset and never inspects kind (`SessionMediaAssignment.swift:38-49`); `SetMediaStrip` is keyed by
`(sessionID, exerciseID, setIndex)` (`SetMediaStrip.swift:53-55`) with a manual PHPicker "Attach to this set"
(`:85-92`). Videos tap straight into the shared **Studio** editor (`presentStudio`). So the parity work is small:

| Media parity item | Today | Change | Effort |
|---|---|---|---|
| Per-set strip on **every** set | climbs show it per *attempt* (`:681`); strength/timed only on the **last** set (`:631`, `:537`) | render `SetMediaStrip` per set in the generalized `EntitySection` for all disciplines | small |
| Deep-tap clip menu (move/remove/delete) | wired **climb-only** (`onReassign`/`onRequestDelete`/`moveTargets` passed only at `:681-684`); label hardcoded "Move to attempt…" (`SetMediaStrip.swift:148`) | turn the menu on for all disciplines; generalize `climbClipMoveTargets` (`SessionMediaAssignment.swift:89-94`) → discipline-aware "Move to **set / leg / attempt** N" | small |
| Entity-level photos | climbs attach climb-level photos (`attachClimbPhotos`, `:1116`; `presentStudioForClimb`, `:771`) | generalize to a run/strength entity photo (trail shot, form ref) | small |
| Studio caption overlay | climbs thread name + attempt # into Studio (`FreeformStudioPresentation.climbCaption`/`suggestedAttemptNumber`, `:1570-1577`) | **scope decision:** strength/run get the per-set strip + Studio editor, but the climb-specific caption overlay is climb-only in v1 (don't promise full Studio caption parity) | trivial (scoping) |

Net: clips/photos "just work" for the new types because the assignment is kind-blind; we surface the strip
everywhere and generalize one menu label.

---

## 6. The card refactor + live stats + summary

**Card (`EntitySection`).** `exerciseSection` 3-way switches on `ex.kind` (`:474-488`). Refactor: extract
`climbSection` → `EntitySection(discipline:)` with injected header/footer/rollup/rowFormatter closures;
`expandedClimbs` → `expandedEntities`. **Re-point BOTH existing cards** — climb *and* the already-rich
`timedSection` (`:496`) — onto it **with no behavior change**, shipped as its own PR verified green against the
existing climb **and** `TimedSetTimerTests` *before* any new type rides. This isolates the only structurally
risky change behind two existing suites.

**Stats bridges (pure, device-free).** Three values modeled 1:1 on `FreeformClimbStats.stats`
(`FreeformClimbStats.swift:15-61`): **`StrengthSessionStats`** (volume, per-exercise volume, e1RM PRs),
**`RunSessionStats`** (distance, pace, time-in-zone), **`TimedSessionStats`** (total TUT, longest hold).
⚠ e1RM is **new math** (Epley), not "lift the inline view math" — today's strength milestone uses
`topWeightedSet`/`bestKg × reps` (`FreeformSummary.swift:133-138`), so this adds a formula + a milestone case.

**Live ribbon for every discipline.** Generalize `statsRibbonSection` (today gated by
`FreeformClimbStats.hasClimbing`, `:130`): strength = "Volume · sets · top set", timed = "TUT · best", run =
"distance · pace". Tap → the matching live sheet (the `LiveClimbStatsSheet` shape).

**Type-adaptive + mixed summary.** `FreeformSummary.dominant` (`FreeformSummary.swift:43-51`) and the
milestone switch (`:130-156`) are **3-case-exhaustive `switch`es** — widening them to N disciplines is a
breaking signature change, so it belongs in **Phase 0** (a run is `.duration` today → mislabels as "timed" if
deferred). A **mixed** session rolls up *each* discipline (today the non-dominant is hidden) — wireframe step 10.
Milestones extend to e1RM PR / longest hold / farthest-fastest run; reuse `CelebrationBurst`, gated.

---

## 7. Reusable hooks (what we lean on, not rebuild)

| Need | Reuse |
|------|-------|
| Entity card | `climbSection`/`climbHeader`/`climbFooter` (`:658-861`) + `expandedClimbs`/`toggleExpanded` |
| Reps/weight grammar | `WorkoutPlayerView` set-input + `QuickAddRow` (`:1624-1684`) — device-verified |
| Hybrid add sheet | `PickTimedExerciseSheet` two-stage shape + `ExercisePickerView`/`CustomExercise` + `AddClimbParams`/`init(from:)` |
| Edit-in-place | `updateClimb` + `EditClimbTarget` (`:1134-1152`) |
| ± steppers / chips | `stepperRow` (`PickTimedExerciseSheet.swift:~350`) + `chip()` (`AddClimbSheet.swift:~670`) |
| Timed set capture | `SetLog.durationSec` + `StopwatchViewModel.arm` + `TimedAttemptCover` (generalize, audit body) |
| Structured runner | `StructuredTimedRunner` + `IntervalSchedule` (`Shared/`, type-agnostic) |
| Rest timer | `RestTimerDefaults.Context` (`:17-42`) — already orthogonal; add a case |
| Media | `SetMediaStrip` (`:53-55`) · `SessionMediaAssignment` (`:38-49, 89-94`) · `ClipContextMenu` · `presentStudio` — kind-blind |
| Stats → ribbon → sheet → summary | `FreeformClimbStats → KilterSessionStats` bridge; `statsRibbonSection`; `LiveClimbStatsSheet`; `WorkoutMath` |
| HR / zones | `WorkoutHRStats` + `ZoneBar` + `LiveMetricsPanel` — type-agnostic, zero new code for display |
| Commit funnel | `appendLog` (`:1194-1213`) — every kind commits here |
| Row formatting | `SetMeasure` — extend `.duration`/`.repsWeight`/new distance to the combined row `.climbAttempt` proves (`:36`) |

---

## 8. Phased plan — one PDD prompt = one PR

> Each phase ships a committed feature prompt, keeps `pdd/context/` true, records choices in
> `pdd/context/decisions.md`, and updates `docs/knowledge-graph/data.js` in the same change (CLAUDE.md).

| Phase | Scope | Tested by |
|-------|-------|-----------|
| **0 · Model + axes + summary enum** | `WorkoutDiscipline`; `disciplineRaw` + metadata + `distanceMeters`/`rpe`/`DistanceUnit`; discipline-derivation from legacy `kind`; `SetMeasure` combined + distance formatter; **widen `FreeformSummary.dominant` + milestone switches to N disciplines** (they're exhaustive — must move here, not Phase 6). **No new UI.** | unit: axis derivation, legacy-decode round-trip, formatter, dominant mapping |
| **1 · `EntitySection` extraction** | Extract the climb card → discipline-parameterized component; **re-point climb AND `timedSection` onto it, no behavior change.** Publish the **a11y-identifier inventory** (`freeform.expand`/`entityMenu`/`logSet`/`timeThisSet`/`logLeg`…) the parity UITests will grab. | existing climb UITests **+ `TimedSetTimerTests`** stay green |
| **2 · Strength parity** | Hybrid add (`⚙` defaults, `AddStrengthParams`); strength rich card + rollup; quick-add unit toggle; recent-prescription chips; rest timer; **inline edit-entity**; per-set media strip on all sets. | unit: params/rollup/e1RM; UITest: add → log → expand → edit |
| **3 · Timed-orthogonal** | Generalize/audit `TimedAttemptCover`; "⏱ Time this set" on strength/run/other; count-up default + optional count-down target; consolidate the 2 climb-timing entry points. | unit: combined-set persistence; UITest: time a strength set → "8×60·0:42" |
| **4 · Running** | `distanceMeters` axis + derived pace; running card + add-leg sheet; time-in-zone reuse; entity photo. | unit: pace/`RunSessionStats`; UITest: log a leg |
| **5 · Dance / Other + chooser** | Expand the type chooser to 6; light open-count-up entity; offer-hierarchy-on-2nd-thing. | UITest: dance session + chooser |
| **6 · Stats + ribbon + mixed summary** | `StrengthSessionStats`/`RunSessionStats`/`TimedSessionStats`; ribbon for all; mixed summary; cross-type milestones; deep-tap clip menu on all disciplines. | unit: each pure stats value + milestones |
| **X · Cross-cutting (fold into the relevant phase)** | **(a)** watch `WorkoutDiscipline → HKWorkoutActivityType` map (`WorkoutActivityMapping.swift:~24`) + decide the **mixed/unknown-at-start** behaviour for `LiveMetricsCoordinator`'s single `HKWorkoutSession` (`:~124`); **(b)** the **second** `kind` switch in saved-session detail `SetTileRow` (`SessionDetailView.swift:773-776`); **(c)** the **history filter** facet keyed on `SetKind` (`HistorySectionView.swift:142, 185-188`) → discipline chips; **(d)** **backup golden-byte tests** (`SnappetBackupTests`) + **Android `BackupRoundTripTest`**. | per-area unit/UITest |
| **7 · On-device hardening** | Device burn-in on MrRobot; Live-Activity/widget discipline-awareness (icon/hero — it *ships* today, just isn't discipline-aware); GPS, watch-run, Spotlight/App-Intents per discipline → tracked follow-ups. | manual device pass |

**Phasing realism:** 2 → 3 → 4 **share** `EntitySection` + `SetMeasure` + the history filter + the backup
Row, so **serialize** them (not parallel); only 5/6 fan out cleanly. **Android is its own multi-PR wave**
(separate `WorkoutModels.kt`/`WorkoutDao.kt`/`WorkoutPlayerScreen.kt` + a possible **Room migration** for new
columns), not the one-liner v0 implied.

---

## 9. Testing strategy (pure-logic-first, per CLAUDE.md)

- **Unit (no simulator):** axis derivation + legacy-blob decode (migration); `SetMeasure` combined + distance
  formatter; `dominant` mapping; `AddStrengthParams`; e1RM + `StrengthSessionStats`; derived pace +
  `RunSessionStats`; `TimedSessionStats`; cross-type milestones; `SessionMediaAssignment` for non-climb sets;
  discipline-aware `clipMoveTargets`. Pure values like `KilterSessionStats`, in `SnappetTests`.
- **UITests (simulator):** strength add→log→expand→time-a-set→edit; per-set clip attach; running log-a-leg;
  dance open session; history-filter facets; mixed-session summary. Built on the a11y inventory from Phase 1.
- **Migration / backup:** decode a pre-change `WorkoutSession` blob (additive guarantee); update
  `SnappetBackupTests` golden bytes and Android `BackupRoundTripTest` in the same waves.
- **UI-suite policy:** Phase 0 (logic-only) gates on unit + build-for-testing + review; Phases 1–6 run XCUITest.

---

## 10. What v1 does NOT change (explicit scope guards)

- **The guided ROUTINE player stays reps × weight-only.** `WorkoutPlayerView` (826 lines) is hard-locked to
  reps/weight (`:39-40, 573-576`) and `RoutineExercise` has no discipline. Bringing the routine
  *player/builder* to parity is a separate, later effort — "every type logs like climbing" is true for the
  **freeform** Quick Session in v1, not the routine flow.
- **GPS/route for running** — manual distance only in v1.
- **Discipline-aware Live Activity / widget / Spotlight / App-Intents** — the Live Activity *ships* today
  (`WorkoutActivityAttributes` via `pushLiveActivity`, `:1543`) and won't crash for new types, but its
  icon/hero won't be discipline-aware until a follow-up. Spotlight/App-Intents "Start a Run/Strength" deferred.
- **Per-entity history `@Model`** (cross-session "this exercise again" / PR history) — deferred; v1 scans
  session blobs. It's the one change that would need `SnappetSchema` + `SnappetBackup` registration.
- **Studio caption overlay** stays climb-only (strength/run get the strip + editor, not the caption).

## 11. Open questions to resolve

1. **Prefill precedence** — when a strength card has a `⚙` default *and* a fresher last-actual set
   (`LastSetLookup`), which wins? *Recommend:* last actual set wins for the quick-add seed; `⚙` default seeds
   only the first set of a fresh exercise.
2. **Watch HK type at session start / mixed sessions** — freeform has no discipline at start, and one
   `HKWorkoutSession` can hold one `HKWorkoutActivityType`. *Recommend:* start as `.other`/`.mixedCardio`,
   and (stretch) re-start the HK session on the first discipline pick; never silently log a run as strength.
3. **DistanceUnit** — km vs mi (not in `WeightUnit`); sticky per user. Needs a new `SetMeasure` branch.
4. **e1RM formula** — Epley (`w·(1+reps/30)`); store reps+weight so it's recomputable.
5. **Weighted timed set in stats** — hold time is the headline; weight a secondary chip; exclude from volume.
6. **Mixed-session hero** — pick by HR-time-share, fall back to most-efforts; show all disciplines as cards.

## 12. Wireframe TODO (next pass, from review)

The current wireframe covers the 13 core surfaces. Still to draw before implementation: **edit-existing-entity**
sheet (strength/run); **empty states** (a run before any leg; an entity with zero sets); the **mixed-session
live canvas** (climb + strength + run cards stacked mid-session); the **history filter** with 6 disciplines;
and, if the routine flow is ever pulled in, the **routine builder**.

---

## 13. Obligations on implementation (CLAUDE.md)

- **PDD:** one feature prompt per phase, committed with the code; keep `pdd/context/` true.
- **Knowledge graph:** every new surface (strength/running/dance cards, "Time this set" cover, the per-set
  clip strip on new types, live stats sheets, mixed summary) gets a `nodes` entry + `links` edge in
  `docs/knowledge-graph/data.js` in the same change.
- **Platform purity:** new stats stay pure value types (device-free tests); HealthKit/location I/O behind the
  service edge; `HighlightEngine` stays platform-free.
- **Android:** its own wave after iOS lands (model + Room migration + backup round-trip mirror).

---

*Built on the real code — derived from a 7-reader deep-review workflow and an adversarial verification pass
over `WorkoutModels.swift`, `FreeformPlayerView.swift`, the media pipeline, the timed system, the strength
flow, the summary/stats, and the design tokens. Every cited `file:line` was checked against source.*
