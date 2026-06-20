# Decisions: Snappet Mobile (iOS)

Reverse-chronological. Each entry: the decision, why, and what it rules out. These are the
non-obvious choices already baked into the v0.1 code — written down so future prompts don't re-litigate
or accidentally reverse them.

## [2026-06-19] Kilter Improvement P0 — all-time stats engine (`KilterAllTimeStats`, keystone)

**Decision**: lift the all-time climbing math (today hand-rolled inline in `KilterHistoryView`) into one
pure, unit-tested value type `KilterAllTimeStats` so the later dashboard (P3) and history roll-ups /
adaptive cards (P4) consume tested aggregates instead of re-deriving math in the view. No UI, no schema,
no new `@Model`, no new `SnappetColor` brand token. Branch `kilter-improvement-plan`.

- **`KilterAllTimeStats` is Foundation-only** (no SwiftUI/SwiftData/UIKit), the all-time analogue of the
  per-session `KilterSessionStats`. It operates on plain `[KilterClimbLog]` (built via `KilterClimbLog.from`)
  plus an optional `[KilterSessionSummary]` (a new plain-value bridge `from(KilterSession)` carrying
  `id/startedAt/endedAt/angle`), so it stays device-free and unit-tested with synthetic values. **Public
  API**:
  `static func make(logs:sessions:now:calendar:climbingLevelWindow:weeklyVolumeWindow:) -> KilterAllTimeStats`.
  Computes: `totalSends/totalAttempts/totalClimbsLogged/distinctClimbs`; `sendRate` (sends ÷ climbs logged)
  and `flashRate` (flashes ÷ sends); `attemptsToSend` (avg attempts among sent climbs, `nil` with no sends);
  `maxGradeDifficulty`+label (all-time send ceiling) and a recency-windowed `climbingLevelDifficulty`+label
  (reuses `KilterRecommender.workingDifficulty` over the most recent N sends, so an old PR doesn't peg the
  level); `maxGradeProgression` (best send per calendar month, chronological); `sendsPerWeek` (trailing-N
  ISO-week volume buckets, zero-filled, oldest→newest); `angleDistribution` (sends & attempts per angle);
  an all-time segmented `pyramid`; and `monthRollups`/`weekRollups` → `{periodLabel, sessions, sends,
  hardestGradeLabel}`. **Empty inputs → `.empty`** (all-zero/empty). Deterministic; **Kilter-board data
  only** (no Quick-Session fold-in).
- **Roll-up session counting**: when a `sessions` list is supplied, "sessions" per period counts one per
  session that **started** in that period; when omitted, it falls back to **distinct `sessionId`** among
  that period's logs (ad-hoc logs with `sessionId == nil` don't count). ISO weeks use `.iso8601`-style keys
  (`yearForWeekOfYear` so week 1 doesn't collide across the new-year boundary).
- **`KilterClimbLog` extended additively** with `var angle: Int = 0` and `var sessionId: UUID? = nil`
  (defaulted → zero call-site breakage), set in `KilterClimbLog.from(_:)` from the entry's `angle`/`sessionId`
  — the all-time angle distribution + session roll-ups need them; the per-session engine ignores them.
- **`KilterSessionStats.GradeCount` extended additively** with `flashes`/`projects`/`attemptsOnly`
  (all default `0`). **`sends` keeps its exact meaning** (sent + flash, the existing pyramid total) so every
  current caller (`ClimbGradePyramid`, `FreeformPlayerView.miniPyramid`) compiles unchanged; `flashes` is a
  **SUBSET** of `sends`, and `projects`/`attemptsOnly` are the non-send counts at that grade — enough to
  render a segmented flash|send|project bar in P3. The segmentation is built by a new shared
  `KilterSessionStats.segmentedPyramid(from:gradeLabel:difficulty:status:)` used by **both** the per-session
  `make` and the all-time engine, so the pyramid rule (a grade row appears only if it has ≥1 send;
  easiest→hardest) is defined once. The pyramid still excludes grades with only projects/attempts.
- **Ascent-style colour vocabulary** lives in a separate SwiftUI file `KilterAscentStyle.swift` (so the
  aggregator stays pure): `glyph`/`label`/`color`/`decoration` over `KilterAscentStatus`. Colours are
  **derived** — flash → local Okabe-Ito/Wong bluish-green (`0x009E73`, colourblind-safe, distinct from the
  perf green) via `Color(hex:)`; sent → `perfFresh`; project → `perfModerate`; attempt → `textSecondary`.
  **No new `SnappetColor` brand token**; always glyph+label (never colour-only).
- **Recompute from rows, no denormalized persistence** in P0 (defer caching unless a real history lags).
  P3 will delete the now-redundant inline aggregation in `KilterHistoryView`.

## [2026-06-19] Workout redesign E3 — Workout Library (discipline-spined `LibraryItem`; in-memory climb/run templates; "Exercises → Library" rename)

**Decision**: the flat, strength-only "Exercises" tab becomes a **library organized by workout TYPE as the
top facet** (Apple-Fitness+-style). One polymorphic, pure `LibraryItem` value type wraps every source, the
faceted filter swaps its facets by active discipline, a "Recent across all types" band crosses disciplines,
and the detail is discipline-adaptive. PR for issue #183 (part of epic #179), depends on E0, feeds E4.

- **`LibraryItem` WRAPS the `exerciseId` contract, never replaces it.** Its `id` is the verbatim
  `exerciseId` for a strength item (bundled or `custom-…`), `timed:<uuid>` / `timed.seed:<key>` for a timed
  exercise, and the starter key for a climb/run template. A `Source` enum holds the backing value
  (strength `Exercise`, timed spec+category+catalogID, climb/run starter) so the detail + E4's routine
  builder can seed a block without re-resolving. Routines/history persist nothing new.
- **NEW-@MODEL-vs-TEMPLATES CALL → in-memory templates, NO new `@Model`** (README §9/§10 Q5). Climb/run
  starters are pure in-memory value types (`ClimbStarter`/`RunStarter`/`RunTerrain` in `Library.swift`),
  mirroring `TimedExerciseCatalog.suggestions`. **Why:** a saved climb/run template `@Model` would have to be
  registered in BOTH `SnappetSchema.models` AND `SnappetBackup` with a golden-byte `BackupRow` mirror (the
  `SnappetBackupTests` tripwire) — out of proportion to seeding a handful of style/terrain suggestions, and a
  *real* saved climb is already the freeform "Add a climb" `SessionExercise` (persisted inside
  `WorkoutSession`). So E3 ships **zero schema/backup change**; the backup golden bytes are untouched.
- **Faceted filter SWAPS by discipline** via one `LibraryFacets` value type. Strength → muscle + equipment +
  "no equipment"; climb → style (`ClimbType`); timed → protocol (`TimedExerciseCategory`); run → terrain
  (`RunTerrain`). The discipline chip's `keepOnly(_:)` drops now-irrelevant facets on switch so a stale
  strength-muscle filter never silently hides every climb. "All types" keeps all facets (cross-search).
- **Two "type" vocabularies reconciled** (README §10 Q6): `LibraryBuilder.discipline(for: ExerciseCategory)`
  maps `cardio → .run`, everything else (strength/powerlifting/olympic/strongman/plyo/stretch) → `.strength`
  — the bundled Free-Exercise-DB is a strength catalog, so we don't over-fragment it.
- **Detail is discipline-adaptive; muscle map is STRENGTH-ONLY.** Strength routes to the existing, well-
  tested `ExerciseDetailView` (keeps Edit/Delete for custom). Climb/run/timed render `AdaptiveItemDetail`
  (discipline header → metadata/how-to → records `StatRibbon`). We deliberately do **not** fake anatomy for a
  climb or a run. Records (`LibraryRecords`) are **best-effort from session blobs** — the per-movement
  cross-session history `@Model` is DEFERRED (README §9), so climb/run/timed records are discipline-wide
  aggregates (no per-template id in the blobs yet), stamped with a "best-effort from your logged sessions"
  caption so the limitation is honest.
- **"Exercises → Library" rename done here** (deferred from E0). `WorkoutSection.browse.title` → "Library";
  the `browse` **case id** + the `workout.sectionPicker` a11y id are unchanged (the #74 id-vs-display rule, so
  historical state / deep links / the XCUITest segment query never orphan). `WorkoutWalkthroughTests` was
  re-pointed from `section("Exercises")` to `section("Library")`.
- **Pure-logic-at-a-thin-edge**: `LibraryItem`/`LibraryBuilder`/`LibraryFacets`/`LibraryRecords` are
  Foundation-only value types, unit-tested in `SnappetTests/LibraryTests`; `ExerciseResolver.library(timed:)`
  is the only `@MainActor`/SwiftData edge (maps live `TimedExerciseCatalog` rows to value snapshots). Views
  (`WorkoutLibraryView`, `LibraryItemDetailView`) stay thin. `RecentSessions.rows` (E1) is reused verbatim for
  the cross-type band. `ExerciseBrowserView.swift` was trimmed to the still-shared `ExerciseRow` + the
  `ExerciseFilters` chip-source extension (the routine picker/builder/settings still use them); the old flat
  browser view + its private filter sheet are superseded by `WorkoutLibraryView`.

**Verified**: `xcodegen generate` + `build-for-testing` (iPhone 17 Pro sim, Swift 6) **SUCCEEDED**, 0 errors.
Unit: `LibraryTests` **13/13**, `WorkoutDisciplineTests` 10/10, `WorkoutMathTests` 7/7, `SessionRecapTests`
5/5, `WorkoutDashboardStatsTests` 6/6 — all 0 failures. UITest: `WorkoutWalkthroughTests` **1/1** (the Library
rename, 59s). Knowledge graph: `wt-library` / `wt-library-detail` nodes + edges added, `node --check` passes.
Deferred (carried to E4 / a follow-up): per-movement cross-session history `@Model`; the climb/run templates
are not yet selectable into a routine block (that's E4's builder, which consumes `LibraryItem.Source`).

## [2026-06-18] Quick Session redesign — climb-name overlay is a PER-CLIP property (prompt 12)

**Decision**: the Studio's freeform climb-name tag is now a **property of its clip**, not a whole-project
overlay. `OverlayItem` gains four additive-optional, migration-safe fields: `clipID: UUID?` (the owning
`TimelineClip.id`), `showsAttemptRaw: Bool?` / `attemptNumber: Int?` / `showsSetterRaw: Bool?` (the
persisted compose flags). **Why each:**

- **Bug #1 (tag spanned the whole project).** `addClimbNameOverlay()` now stamps `clipID = selectedClip?.id`
  and seeds the window from that clip's placed slot (whole-project fallback when no clip is selected). The
  on-screen window is **resolved at RENDER time** from `clipID` → the clip's *current* placed slot via a new
  `outputWindow(for:)` — so trim/reorder/split never desync the tag. Both the canvas gate AND export read
  this resolved window. **Where it's resolved:** in the VM's `scopedSnapshot`/`canvasOverlays` (a new
  `renderedOverlays(_:)` re-derives each `.climbName` overlay's `startSec/endSec` + composed `content`), NOT
  in `StudioOverlays`/`StudioComposer` — the lower-risk of the two options the prompt allowed ("re-derive into
  those fields before makeAnimationTool"), so the export composer is untouched and `applyVisibility` reads the
  fresh window. The persisted model keeps the BASE window/caption.
- **Bug #2 (tap "Climb" re-added a box).** `addClimbNameOverlay()` is now idempotent: if a `.climbName`
  overlay with `clipID == selectedClip?.id` exists, it just SELECTS it (never re-seeds the caption — that
  would wipe a manual edit; the lower-risk choice) and returns. The "Climb" bar button shows "Climb ✓" when
  the selected clip already has a tag (like Music/HR).
- **Canvas time-gate.** `StudioOverlayCanvas` takes `currentTime` and renders a text/sticker/climb chip only
  while `selected || startSec-eps ≤ currentTime ≤ endSec+eps` (the selected overlay always renders so a
  just-added/off-segment tag stays draggable); PiP frames always render (they're in the player). Opacity is
  now sampled from `opacityKeyframes` at the playhead with the 0.15 floor dropped (held only for a *selected*
  chip so it stays grabbable) — preview now matches the export bake.
- **Multi-clip attempt#.** `select(_:)` repoints `selectedOverlayID` to the `.climbName` overlay owned by the
  newly-selected clip (by `clipID`) before `refreshAttemptLineForSelection()`, so the Attempt# acts on the
  RIGHT per-clip tag. Attempt number = that clip's `SessionMedia.assignedSetIndex + 1`.
- **Killed the transient Sets + the regex.** The in-memory `climbAttemptEnabled`/`climbSetterEnabled` Sets and
  the `\nAttempt \d+$` strip regex are GONE. Toggle state lives on the model (`showsAttempt`/`showsSetter`,
  read back correctly across reopen/undo). The rendered string is COMPOSED at render time by a new pure
  `KilterClimbCaption.composeClimbTag(base:setter:showSetter:attempt:showAttempt:)` = base (+ " · by {setter}"
  on the detail line if `showsSetter`) (+ "\nAttempt N" if `showsAttempt`) — used by BOTH the canvas chip and
  export, so user text and the system lines never share an encoding (no more caption corruption / setter-edit
  wipe). Unit-tested.
- **Migration safety gotcha**: a non-optional `Bool = false` is **NOT** decode-safe — Swift's synthesized
  `Decodable` calls `decode` (not `decodeIfPresent`) and throws `keyNotFound` on a missing key even with a
  property default (it broke the existing `testOverlayDecodesFromPreStyleJSON`). So the flags are stored as
  **optional raws** (`showsAttemptRaw`/`showsSetterRaw`, `nil → false`) with non-optional accessors — the same
  `boldRaw`/`italicRaw` precedent. `clipID`/`attemptNumber` are optional so they're fine as-is.
- **Polish**: `removeClip` prunes `s.overlays.removeAll { $0.clipID == id }` (no orphan tags); "Show setter"
  is gated behind `canShowClimbSetter` (`resolvedClimbUUID != nil`) so it's HIDDEN for freeform climbs; an
  empty resolved caption no-ops the add and empty-content chips are filtered from the canvas (matching the
  export filter); `TextOverlayChip` gets a11y label/value/`.isSelected`/`studioOverlayChip` id.

**New editor op**: `StudioProjectEditor.setOverlayClimbFlags(_:id:showsSetter:showsAttempt:attemptNumber:)`
(pure, each param optional → leave-unchanged; `attemptNumber` is `Int??` so it can be cleared). The
`StudioProjectSnapshot`/undo-redo carry the new fields automatically (they're part of the Codable `OverlayItem`).

**Verified**: `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 errors / 0 new warnings in the
changed files — the only warnings are the pre-existing `StudioComposer` CIFilter deprecation + the
`SnappetBackupTests` main-actor isolation). Full `SnappetTests` **887** green (2 skipped) incl. new
compose/window-resolution/idempotency/migration tests; `SnappetUITests` `NamedClimbTests` + `EditClimbTests`
+ `LiveWorkoutStudioWalkthroughTests` all pass (studio walkthrough green first try). Device-only / deferred:
the actual export burn-in of a per-clip tag (only-its-segment) + the drag/scrub feel — covered by the pure
compose/window unit tests + the green studio UITest; the on-device render is the usual export-burn check.

## [2026-06-18] Quick Session redesign Phase 2 — live timed-attempt FOCUS cover

**Decision**: replaced Phase 1's minimal `TimedAttemptSheet` (a `.sheet(item:)`) with a full-screen
**`TimedAttemptCover`** presented via `.fullScreenCover(item: $timingAttemptFor)` — a dark, glass FOCUS
surface that times ONE climbing attempt. RUNNING state: near-black gradient · "Peek canvas"
(`timedAttempt.cancel`) + "try N" · a glass climb card (type chip · name · grade pill) · a big
SF-Rounded tabular hero timer (`timedAttempt.timer`) · an optional glass HR chip (`timedAttempt.hr`) ·
a full-width ≥64pt STOP (`timedAttempt.stop`). STOP freezes/greys the timer and cross-fades in a **2×2
outcome grid** — thumb-nearest BOTTOM row = the "close the climb" Send/Flash pair, TOP row =
Fall/Project (`timedAttempt.outcome.<status>`) — plus a "Save as attempt" (`timedAttempt.saveAsAttempt`).
Commits through the SAME `logAttempt(toExerciseID:status:durationSec:)` funnel (stamps grade +
completedAt + haptic) — no model change.

**Why these specifics**:
- **`StopwatchViewModel(.countUp)` driven DIRECTLY**, NOT the packaged `StopwatchView`. The packaged
  view's composite collapses under XCUITest on iOS 26 (hides its inner `stopwatch.toggle`); driving the
  `@Observable` VM directly lets the cover own its OWN leaf ids (`timedAttempt.timer`, `.stop`,
  `.outcome.*`) — one a11y id per interactive leaf, the iOS-26 rule. The VM is still the single
  wall-clock-backed timing source: auto-`start()` `onAppear`, `endTicking()` `onDisappear`,
  `syncToWallClock()` on scenePhase `.active` (correct across backgrounding, no drift).
- **Never silently drop a captured effort**: a dismissal (Peek / swipe-down) AFTER a Stop save-as-attempt
  via `onDisappear` (commit `.attempt` + the captured duration); BEFORE a Stop logs nothing. The
  outcome-tap path clears `capturedSeconds` first so the `onDisappear` guard can't double-log the same
  effort.
- **HR chip OMITTED entirely (not "♥ --") when `latestHR == nil`** — a missing sample never renders as a
  misleading inert chip; zone via `HeartRateZone.forBpm(bpm, maxHR: resolvedMaxHR ?? defaultMaxHR)`.
- The hero timer renders `SetMeasure.formatDuration(vm.reading.elapsed)` so the captured value matches
  the attempt row EXACTLY and a long attempt rolls to H:MM:SS (formatDuration already handles it).
- **No milestone celebration here** — Phase 3 owns that.

**Rules out**: a half-sheet timed attempt; counting ticks instead of the wall clock; an id on the
packaged StopwatchView (collapses the composite). The `ClimbAttemptTimerTests` UITest was rewired to
drive the cover (tap `freeform.timedAttempt` → wait the auto-started `timedAttempt.timer` →
`timedAttempt.stop` → `timedAttempt.outcome.sent` → assert a `freeform.setRow` shows the captured M:SS).

**Verified**: `xcodegen generate` + `xcodebuild build-for-testing` clean (0 errors, 0 new warnings —
the test-target actor-isolation warnings are pre-existing across the whole suite); `SnappetTests` green
(829, 2 skipped); `ClimbAttemptTimerTests` green (1 test, ~44 s). **Device-only / deferred**: the live
HR chip needs a real watch/BLE HR source (the simulator has none, so the chip is exercised only via its
nil path); the glass/material rendering feel.

## [2026-06-18] Quick Session redesign Phase 1 — climb-first hierarchy (Add-a-climb sheet · expandable climb cards · attempts under climbs)

**Decision**: turned the freeform **Climbing** flow from flat attempt rows into a **climb-first
hierarchy** (`quick-session-redesign/PLAN.md` → Phase 1). Tapping Climbing (the empty-state
`freeform.cardClimbing` card OR the add-menu "Climbing" button) now presents a new **`AddClimbSheet`**
that captures the climb's identity ONCE — TYPE (drives the grade scale) → a scale-aware DISCRETE grade
rung picker + recent-grade chips + V/Font·YDS/French toggle → optional NAME → optional GYM under a
"More" disclosure (inherited from the session's most recent climb). The created climb is an
**expandable card** (`climbSection`): a rolled-up header (type icon · inline-editable name
`freeform.climbName` · grade pill · status badge · "N attempts" · time-on-climb) that toggles open to
the attempt list + a footer ("+ Log attempt" → an inline outcome strip · "Timed attempt" · "Repeat
last"). This fixes "you can't group three tries on the same V4 project". Lifting + Timed flows are
unchanged this phase (`liftingOrTimedSection` keeps the flat set-list rendering + `LogSetSheet`).

**Why these specific choices**:
- **Grade is stamped onto each attempt `SetLog` (`climbGradeLabel`), captured once on the climb card.**
  The pure `FreeformSummary` / `KilterMilestones` reads are per-`SetLog`, so stamping the climb grade
  onto every attempt keeps sends/pyramid/milestones working **unchanged** and old flat data still
  renders — no rewrite of the stats engines, no migration. The per-attempt **row** (`SetMeasure.attemptRow`)
  shows only outcome (+ optional duration + tries), NOT the grade (the grade lives once on the header,
  so repeating it per row would be noise). The existing `SetMeasure.summary(.climbAttempt)` is kept
  verbatim for History / back-compat.
- **Ember, not coral.** Primary CTAs/accents stay `SnappetColor.workout` (the module's established
  ember) — NOT the research doc's "Pulse Coral" — for native consistency with the rest of the player.
  Boulder grade pills use `SnappetColor.kilter` (amber); route pills a cool tint (`SnappetColor.budget`).
- **Route status relabels reuse `KilterAscentStatus`** (no enum change): `ClimbType.statusLabel` only
  **relabels** the four states for display (flash→Onsight, sent→Redpoint, project→Project, attempt→Fell)
  so the outcome strip + status badge read naturally for ropes without touching the persisted vocabulary
  or the send/pyramid math. Boulder uses the plain labels.
- **`AddClimbSheet` a11y ids** (one per interactive leaf, the iOS-26 rule): `addClimb.type`,
  `addClimb.grade` (container) + `addClimb.gradeValue` (the picked label, queryable), `addClimb.rung.<G>`
  per rung, `addClimb.recent.<G>`, `addClimb.scaleToggle`, `addClimb.name`, `addClimb.gym`,
  `addClimb.add` / `addClimb.addAndLog`. The card footer: `freeform.logAttempt`,
  `freeform.outcome.<status>`, `freeform.timedAttempt` (+ the in-sheet `freeform.timedOutcome.<status>`),
  `freeform.climbExpand`, `freeform.gradePill`, `freeform.climbStatus`; attempt rows keep `freeform.setRow`
  and the climb name keeps `freeform.climbName`.
- **Recent grades** persist per scale in `UserDefaults` (key `freeform.recentGrades.<scale>`), most-
  recent-first, de-duplicated, capped at 5 — the warm path is two taps (recent chip → CTA).
- **Timed attempt stays a minimal sheet for now** (`TimedAttemptSheet`: a count-up `StopwatchView`
  whose Stop captures `durationSec`, then an inline outcome) — Phase 2 replaces it with a full-screen
  FOCUS cover. The StopwatchView carries no `accessibilityIdentifier` itself (it would collapse the
  composite and hide the inner `stopwatch.toggle` on iOS 26); the outcome buttons are disabled while the
  stopwatch runs so a capture can't be dropped mid-run.

**Tests**: `SetMeasureTests` extended for `attemptRow` (boulder/route relabels, duration appended, tries
> 1, grade never present, no-outcome dash). The three climb UITests rewritten to the new flow
(`NamedClimbTests` = Add-a-climb sheet → graded card + attempt + inline rename; `ClimbAttemptTimerTests`
= card footer "Timed attempt" → stopwatch capture → outcome → duration in the attempt row;
`FreeformFlowWalkthroughTests` climbing leg → Add-a-climb sheet → grade pill + outcome). `TrackingTypeFilterTests`
is Timed-only and unchanged. Verified: `xcodegen generate` + `build-for-testing` clean (Swift 6,
0 warnings in the changed files); full `SnappetTests` green (829, incl. the 5 new `attemptRow` tests).

**Rules out**: per-attempt grade entry (the old `LogSetSheet(.climbAttempt)` free-text grade path is no
longer reached for new climbs — kept only for legacy decode); a separate `@Model` for the climb (it
stays a `SessionExercise(.climbAttempt)`, attempts stay its `sets`, all new fields additive Optionals).

## [2026-06-17] Quick Sessions UX rework — freeform player: canvas · faster entry · inline climb naming · completion moment · live metrics · live clips · clip→Studio (issue #158)

**Decision**: reworked the routineless **`FreeformPlayerView`** end-to-end (issue #158, one combined PR;
the guided `WorkoutPlayerView` is reused read-only, never modified). Shape:
- **Pure helpers first** (shipped no-callers, the `StopwatchTiming` precedent): `FreeformSummary`
  (value-labelled Repeat label · completion stats with a dominant-kind headline Volume/Sends/Hold-time ·
  the milestone decision composing `WorkoutMath.topWeightedSet` [a weighted-only top set added so a
  high-rep bodyweight set can't mask or zero-out a real weighted PR] + `KilterMilestones.isFirstSend`) and
  `LiveMetricsSummary` (current bpm+zone · running avg/max/redline over the live buffer via
  `WorkoutHRStats` · recovery via `RecoveryReadiness`). Both unit-tested (`FreeformSummaryTests`,
  `LiveMetricsSummaryTests`); no SwiftUI/SwiftData/device.
- **§A canvas + command bar**: empty-state three `.snappetTile()` type cards; inline-editable session
  title (`freeform.sessionTitle` → `routineName`); a persistent bottom command bar
  (`safeAreaInset(.bottom)`: wall-clock timer · live-HR chip · always-present Finish), retiring the
  toolbar "End".
- **§B faster entry**: cross-session prefill (cached `LastSetLookup`, never re-scanned per render);
  keyboard-free inline `[−] value [+]` quick-add (custom leaf buttons, not a native `Stepper` — see
  below) through the one `appendLog`; value-labelled Repeat via `FreeformSummary.repeatLabel`.
- **§C inline climb naming** — *reverses the [2026-06-16] "Named free-flow climb: prompt-on-tap"
  decision*: tapping Climbing now **adds immediately** (named "Climbing"); the section header is an
  inline `TextField` (`freeform.climbName`, a directly-queryable leaf) committing via the same tested
  `SetMeasure.climbName` on return/blur. Model impact is identical to PR-5 (zero — reuses `displayName`).
- **§D completion moment**: Finish opens an in-cover summary (seal + the three `FreeformSummary.stats`)
  with a milestone `.celebrates(on:)` burst (haptic always, confetti suppressed under Reduce Motion);
  CTAs Done / View detail (`onViewDetail` → finish+save then push `SessionRoute`) / Keep going / Discard.
- **§E live HR/metrics/recovery**: the command-bar chip (bpm+zone+recovery dot) opens `LiveMetricsPanel`
  (HR chart, time-in-zone, avg/max/redline, calories, a recovery ring from the engine's recovery
  `fraction`, an optional wall-clock rest timer), throttled ~2 s.
- **§F live clips**: wired the existing `SetMediaStrip` per exercise (latest set) + a ~20 s discovery
  cadence (`SessionMediaService.discover` → insert auto rows → reconcile via the pure
  `SessionMediaAssignment`, sticky manual/general untouched).
- **§G clip→Studio**: a freeform video thumbnail opens the shared `StudioEditorView` scoped to the clip
  (`StudioEntry.resolveProject`, one project per `sessionID`); the editor's own HR load falls back to the
  live watch+BLE buffer, so a mid-workout clip keeps its overlay (no separate flush).

**Why** (the non-obvious build choices, each forced by a real failure during the rework):
- **Add-exercise is a toolbar `Button` + `confirmationDialog`, not a `Menu`.** A bottom-of-list `Menu`
  became unreachable as the logbook grew; a *toolbar* `Menu`'s item action then fired **unreliably** under
  XCUITest (the Timed add silently no-op'd). `confirmationDialog` buttons are dependable. Its trigger
  label is "New exercise" (not "Add …") so it doesn't collide with the picker's nav-bar "Add (N)" commit
  that the UITests match by `BEGINSWITH 'Add'`. Kept the `freeform.addExercise` id + the option labels.
- **`ScrollViewReader` auto-scrolls to a newly-added exercise.** A `List` renders off-screen rows
  lazily, so with the taller sections (quick-add, media strip) a new exercise landed off the bottom,
  **unrendered** — invisible to the user *and* absent from the a11y tree (`adds.count` undercounts). Auto
  -scrolling fixes both; `contentMargins(.bottom)` keeps the last row clear of the floating command bar.
- **Quick-add uses custom leaf `+/−` buttons, not a native `Stepper`** — a SwiftUI `Stepper`'s
  increment/decrement aren't reliably addressable in XCUITest; leaf buttons get their own ids
  (`freeform.quickReps.plus`, …). The quick-add **Log** label stays plain; only **Repeat** is value
  -labelled — and tests match a set row's value **exactly** (`== '8 × 60 kg'`), since the value-labelled
  Repeat ("Repeat 8 × 60 kg") leaks into `staticTexts` and a `CONTAINS` query would double-count.

**Supersedes**: the [2026-06-16] "**Deferred (device-pending): photo attachment to a free-flow climb**"
note — now in scope via the shipped `SessionMedia` + `Studio` (§F/§G). Capture/discovery/Studio remain
**device-verified, not CI** (no Photos/HR on the simulator); the pure assignment/summary logic is
unit-tested and the affordances render everywhere.

**Rules out**: modifying the guided `WorkoutPlayerView`; any SwiftData model change (all figures are
derived; clip naming reuses `displayName`; clip storage is the existing `SessionMedia`); a SwiftUI `Menu`
for add-exercise; a native `Stepper` for quick-add; treating a clean type-check as device verification.

## [2026-06-17] CI: path-gate the ~30-min UI suite to `ios/**` PRs (PR #173, follow-up)

**Decision**: the slow `SnappetUITests` leg (~30 min, 33 tests) no longer runs on every PR push — only
when a PR touches `ios/**` (all app + UI + engine source) **or `.github/workflows/ci.yml`** (the build
recipe itself). A cheap Linux `changes` job runs `dorny/paths-filter` and emits a **dynamic test matrix**
(`["SnappetTests","SnappetUITests"]` vs `["SnappetTests"]`) that the macOS `app` job consumes via
`fromJSON(needs.changes.outputs.suites)`, so the UI runner is **never requested** (omitted from the
matrix, not skipped-in-place) on docs/`pdd`-only PRs. This enforces in config what was previously a
manual policy.

**Why these specific guards (each closes a footgun an adversarial review confirmed):**
- **`ios/**` is the trigger, not a per-file allowlist** — every app/UI/engine input lives under `ios/`
  (incl. `project.yml`, assets, `Package.resolved`, fastlane), so any app-affecting change is caught;
  `ci.yml` is added because it *is* how the suite is built. `release-ipa.yml`/`testflight.yml` are not
  (they don't affect the PR test build).
- **Fail-OPEN**: UI is dropped only on an explicit `ios == "false"`; any empty/ambiguous filter value
  keeps the full suite. We never *skip* UI by accident — at worst we over-run it.
- **`if: ${{ !cancelled() }}` + `fromJSON(… || '[full]')` on `app`**: if the `changes` job itself fails,
  the build degrades to "run everything" instead of `needs:`-skipping `app` and **silently losing the
  unit signal**. Unit (`SnappetTests`) + engine therefore ALWAYS report.
- **The UI leg must NOT be a required check.** It's deliberately skippable, so requiring it would block
  any PR that legitimately skips it. Require only `engine` + `App tests (SnappetTests)` for merge.

This rules out top-level `paths-ignore` (would skip the whole workflow incl. the fast gate) and a
static matrix. Combined with the [#172] PR-only `cancel-in-progress`, a PR now runs the minimum useful
set and main runs full + uncancelled.

## [2026-06-17] Xcode Cloud post-clone setup + CI concurrency scoping (PRs #169–#171, follow-up)

**Decision**: make Xcode Cloud build the **generated** project from a freshly cloned repo, and stop
`main`'s post-merge CI runs from cancelling each other. Two systems, two distinct fixes:

**Xcode Cloud (the `SnappetAI | Default` commit check).** The `.xcodeproj` is XcodeGen-generated and
gitignored, so it is absent on a fresh clone. A `ci_post_clone.sh` regenerates it — but three
non-obvious constraints stack: (1) Xcode Cloud resolves `ci_scripts/` **relative to the Xcode project**
(`ios/App/`), NOT the repo root, so the script must live at `ios/App/ci_scripts/ci_post_clone.sh` (a
byte-identical copy is kept at the repo root as a fallback — keep them in sync); (2) Homebrew's bin is
not reliably on the non-login `/bin/sh` PATH, so the script resolves `$(brew --prefix)/bin` explicitly
before calling `xcodegen`; (3) Xcode Cloud **disables automatic SwiftPM resolution at the environment
level**, so `xcodebuild -resolvePackageDependencies` inside the script can't generate the lock (exits
74) — we instead **commit `ios/App/Package.resolved`** (negated in `.gitignore`) and the script copies it
into `Snappet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`. The script `set -ex`-traces every
step and **guards loudly** (missing project / missing `Package.resolved`) with the exact refresh command,
so a future failure is legible in the build log instead of an opaque downstream error. **Refresh the
committed lock** (`xcodebuild -resolvePackageDependencies` → copy out → recommit) whenever a package
version in `project.yml` changes, or Xcode Cloud resolution fails again.

**GitHub Actions `ci.yml` concurrency.** `cancel-in-progress` is scoped to **pull requests only**
(`${{ github.event_name == 'pull_request' }}`), not a blanket `true`. A new commit on a PR branch still
cancels its stale run (saves runner minutes), but back-to-back **merges to `main` no longer cancel each
other** — each merge's post-merge verification runs to completion so its commit status reports green.
Rapid merges previously cancelled the prior main run, which surfaced as a red "failure" that was really
just `cancelled`. This rules out relying on the latest main run alone as a health signal during a merge
train; with the scope fix, every main commit gets its own honest result.

## [2026-06-17] HR stat-tile "Glass HUD" redesign (issue #163, prompts 77–78) — supersedes the #160–162 catalog

**Decision**: rebuild the HR stat tile's visual language as a premium **"Glass HUD"** with a strict
**hero → secondary → tertiary** hierarchy and an **anti-crop layout engine**; bring the live HR chart
back as a premium **zone-banded trace**; default to **Glass Hero Card with the sparkline ON** (the
`hero` model case — replacing the Scorebug default). Model `rawValue`s are unchanged, so persisted
tiles + the walkthrough UITest's `studioTileTemplate.<raw>` ids keep working; migration-safe Codable +
the SwiftData phantom-tile→nil normalization stay. The pure `HRTileLayout` is still the single source
of truth feeding both the SwiftUI preview and the Core-Animation export (WYSIWYG).

**The actual on-device crop fix is honest widths + tabular numerals — NOT a font floor in the fit
math.** On-device crop is an **export** phenomenon (the burned-in `.mp4`): the export rect is in
**pixels** (~1080 wide), so the raw font is always far above the 11pt floor there and the floor never
bites. The old crop came from (1) a non-tabular export `UIFont` (digits wider than estimated) and (2)
the fictional `HROverlayMetric.tileValueChars` underestimating width. So we ship **value-only chips**
(`142` + caption `AVG`, not `142 avg bpm` — ~40% narrower), an **honest width estimate** (em-advance
0.66 over the real value-only char counts), and a **tabular rounded `UIFont`** (`kMonospacedNumbers`) in
every export text layer. We deliberately **keep the 11pt floor OUT of the fit/reflow math** — applying
it there (as the spec's rule #5 reads literally) would make a small preview (points) and a large export
(pixels) reflow to *different* metric counts, breaking the scale-invariance that makes WYSIWYG hold.
The floor stays a preview-only legibility guard on the *reported* size.

**Per-template hard caps + `hiddenCount` (`+N · enlarge`), not silent cropping.** Each template caps
the visible metrics (one hero + secondary + tertiary; hero 5 / scorebug 4 / ring 4 / hudPill 3 / list 6
/ bento 6 / chartBanner 4). "Toggle all 10 on" fills the cap by priority and parks the rest into
`HRTileLayout.Result.hiddenCount`, which the editor surfaces as a `+N · enlarge tile` affordance.
Spawn sets are focused (never all 10) so a freshly-placed tile reads cleanly before any toggle.

**Chart auto-grow is a normalized editor nudge + a fractional carve — never an absolute-point min in
the pure layout.** Enabling the chart nudges `tile.height` up to the template's `minHeightWithChart`
(normalized) so the curve has room; the pure layout carves the chart as a *fraction* of the tile. An
absolute "≥24pt" min in the layout would diverge between preview points and export pixels — so it lives
in the (normalized) model/editor, not the scale-invariant layout.

**No `strokeEnd` draw-on — full curve + moving dot, both sides.** The SwiftUI preview is a per-frame
snapshot with no `strokeEnd` animation, so a Core-Animation draw-on would diverge from the preview
*during playback*. We render the full smooth curve with only the playhead **dot** moving. The export dot
is **x-synced** (position `CAKeyframeAnimation` keyed by `x = t/maxT` with `.linear` — the same timeline
fraction the preview tracks; NOT `.paced`, which parameterizes by arc length and would desync from the
preview's x-fraction) and its halo/core colours animate by the **zone under the dot** (colour keyframes),
so the burned-in dot tracks the same point AND the same colour the preview's live dot shows — preview ==
export at every frame, the project's top invariant.

**Curve gradients: horizontal zone-banded stroke (flip-safe), flat area wash (flip-ambiguous).** The
zone-banded **stroke** is a horizontal `CAGradientLayer` (`(0,0.5)→(1,0.5)`) masked by the smooth stroke
shape — x isn't flipped, so it's identical in preview and export. The **area** fill is a flat low-alpha
zone wash on both sides: a *vertical* `CAGradientLayer` orientation is flip-ambiguous in the raw tool
tree (bottom-left origin) and only device-verifiable, so we avoid it. The smooth path itself is the
shared pure `HRChartGeometry.smoothedPath` (Catmull-Rom→bézier `CGPath`), consumed by `Path(cgPath)` and
`CAShapeLayer` alike. `ResolvedHRTile.maxHR` is threaded through so the export's zone colours tint
against the *same* bound as the preview.

**Colour: near-white hero, selective zone accents.** The hero number is near-white `#F2F4F8` (the kit's
"never pure white"); the zone pill / sparkline carry the zone hue; chip/field values use the zone or
semantic colour only for the live-intensity metrics (zone / %HRR / redline / recovery) and near-white
for the aggregates — so a single hue never misrepresents a multi-zone session (the prompt-51 rule,
refreshed for the value-only chips).

**Phase 2 — the full premium catalog (prompt 78).** The 6 non-default templates got bespoke geometry on
the PR1 foundation: HR Trace (`chartBanner`, top row + curve + 4-up), Broadcast (`scorebug`, accent bar +
5-cell zone bar + right stat columns + chart lane), Vertical Rail (`list`, vertical zone bar + label→value
rows), Zone Ring (`ring`, %HRR sweep gauge with the zone in the arc colour), Gradient Strain (`bento`, the
Glass Hero layout on an effort gradient skin), HUD Pill (unchanged). Two shared primitives: a `.zoneBar`
role and a `Decoration` (accent bar / gradient skin) the pure layout places so both renders draw it from
the same frame; `Reading.fraction` carries %HRR/redline for the sweep + bars. Non-obvious choices:

- **The gauge sweep + zone bar ANIMATE in the export (keyframes), not just the preview.** They bind to
  live+animated metrics (zone/%HRR), and the preview re-resolves per frame, so a static export froze the
  arc/lit-cell at the clip start — a WYSIWYG break (caught by the phase-2 adversarial review). Fix: the
  export keyframes the gauge's `strokeEnd`/`strokeColor` and cross-fades a per-segment lit-cell overlay
  on the zone bar, the same baked-keyframe pattern the hero number / zone pill / chart dot already use.
- **Chrome (accent bar / gradient skin) is STATIC — the clip's AVERAGE-bpm zone, both sides.** Keyframing
  a background tint per-frame isn't worth it; a stable "effort backdrop" (computed identically in preview
  and export from the avg bpm) is cleaner and trivially WYSIWYG. The live tracking stays on the
  hero/pill/zone-bar/gauge/dot. The gradient skin is **horizontal** (cool → zone) so its orientation is
  flip-safe in the Core-Animation tool tree (a vertical gradient is flip-ambiguous — same call as the
  curve's flat area fill).
- **Zone-bar orientation is explicit per template (`MetricSlot.zoneBarVertical`), never inferred from the
  slot aspect** — Broadcast's bar is horizontal even though its slot is taller-than-wide at the default
  size (inferring from aspect flipped it vertical).
- **`hiddenCount` credits a colour-encoded metric.** The Zone Ring shows the zone as the arc colour (no
  slot), so an enabled `.zone` there is *covered*, not parked — otherwise a pristine ring showed a false
  "+1 · enlarge". The builder's `+N` hint (`tileHiddenCount`, computed on a nominal canvas scaled by the
  tile size) only promises metrics that enlarging can actually reveal.
- **Per-template caps match each design's spawn set** so the focused default fully shows and only
  user-added extras park.

**Phase 3 — on-device feedback polish (prompt 79).** Two additions after seeing the tiles on a phone:
(1) a user **tile-opacity** control (`HRTile.opacity`, default 1.0, clamped to `minOpacity 0.25`) applied
to the whole tile on both sides — SwiftUI `.opacity(...)`, and the export composes it with the per-clip
gate via a `level:` param on `gateSegmentOpacity` (gated tile ramps to `opacityF`, whole-timeline tile
sets `container.opacity`) so preview == export; (2) a plain-English **`HROverlayMetric.explanation`** per
metric shown under each builder toggle, so the user knows what each readout means. Opacity is a render/
model concern, deliberately NOT in the pure `HRTileLayout`.

**Phase 4 — the legacy free-floating-badge fallback was deleted.** Removed `HROverlayElementsView` +
`StudioHRChartView` (whole files), `StudioOverlays.hrElementLayers`/`hrBadgeLayer`/`hrChartLayer` + the
legacy `makeAnimationTool` branches + the `hrConfig`/`hrElements`/`PlacedClipHR.elements`/
`StudioClipHRContent.elements` threading through `StudioComposer`, `HROverlayValues.resolve(_:)` +
`ResolvedHROverlay`, and the view-model element-CRUD / `setShowChart`/`setHRPosition`/`setHRScale` +
`LegacyHROverlayControls`/`StudioHRElementRow`. **Deliberately KEPT** (NOT "also delete"): `HRTileMigration`
+ `HROverlayElement` + `HROverlayConfig.elements` (decode-only) + `.showChart` — because the live tile
resolver reuses `HROverlayElement` and migration folds any old persisted `elements[]` into a tile, so a
project not yet re-opened since the tile shipped does NOT lose its HR overlay (zero data loss). The other
legacy `HROverlayConfig` fields (`scale`/`colorHex`/`normalizedX`/`showBPM`) stay too — they're the
persisted-blob schema, harmless, and dropping them is a separate migration concern. A 9-agent adversarial
review confirmed the tile path + migration are intact with no dangling refs.

## [2026-06-16] Kilter planned-session Android port: faithful mirror with Android-specific divergences (kilter-planned-session A-PR1..4)

**Decision**: the iOS planned-session feature is ported to Android (Kotlin/Compose/Room) mirroring the
iOS semantics + the invariants above. Branch `claude/android-kilter-planned-session`. Five layers:
`KilterPlanProgress.kt` (pure logic, port of `KilterPlanLogic.swift`), `KilterPlanEntity` (Room),
session-manager plan ownership + recover, `KilterPlanScreen` (generate/session-home + config sheet),
and cross-screen re-entry (Home resume card + climb-detail strip).

**Android-specific divergences (intentional)**: (1) plan items ride as a **JSON `String` column**
(`itemsJson`, kotlinx.serialization via `KilterPlanItemsCodec`) on `KilterPlanEntity` — this codebase
has **no Room `@TypeConverter`** and iOS's embedded `[KilterPlanItem]` array has no Room equivalent.
(2) The Android **backup is schema-agnostic** (reads every table at the SQLite level), so the new
`kilter_plan` table is covered automatically — no per-model row like iOS's `KilterPlanRow`
(`BackupRoundTripTest` seeds one row to keep its "every exported table was seeded" invariant honest).
(3) DB **v5→v6 AutoMigration** (additive table, no SQL). (4) `KilterSessionManager` is `remember`-scoped
in `KilterRoot` (not AppContainer like iOS's AppModel-owned manager), so **`recover()` runs on entry**
to re-hydrate the open session + pinned plan from the store — the store is the source of truth, which
survives nav-out/in + relaunch and sidesteps an AppContainer/HR-source hoist. Outside-Kilter re-entry
surfaces (Home card) are **store-derived** (Flows), not manager-derived. (5) Plan RMW is serialized
through a **Mutex** (iOS is @MainActor-atomic). (6) `start()` folds `recover()` and `startPlan()`
re-enters an existing open plan — the same single-open-session / one-open-plan invariants as iOS.
(7) The Home "Resume" card deep-links via a new `SuiteRouter.Route.KilterPlan` parked on
`KilterDeepLinkBus` (mirrors the existing `KilterClimb` deep-link), consumed by `KilterRoot` to open the
plan-home. Goal-grouped reel + a floating shell-wide chip (iOS App-Library chip) remain deferred on both
platforms; the Home card + in-Kilter strip cover re-entry.

## [2026-06-16] Kilter plan customization: named strategies over Options + a weighted allocation (kilter-planned-session PR 07)

**Decision**: "Plan a session" gains an **Adjust** sheet leading with climber-language **strategies**
(`KilterRecommender.Strategy`: balanced / volume / project / power / flash / recovery) that seed three
knobs — session length, grade offset, prefer-unsent — plus a goal **mix**. Picking a strategy seeds the
knobs; the climber can then fine-tune them while the strategy's mix stays applied. Persisted in
`@AppStorage`; snapshotted onto `KilterPlan` (incl. `optionsGradeOffset`) on Start.

**Non-obvious choices**: (1) `Options.mix` is **Optional** — `nil` keeps the original balanced
`allocation(target:)` byte-for-byte (pinned by `testBalancedDefaultUnchangedByOptionalMix`), so the
existing `KilterRecommenderTests` and default behaviour don't drift; non-nil routes through a new
**largest-remainder** `allocation(target:mix:)` (sum==target, ≥1 per positive-weight goal for reachable
counts ≥3, drops zero-weight goals). (2) The **grade offset is applied to the anchor in the view**
(`KilterPlanView.rebuild`), NOT inside `Options`/`recommend` — the recommender's contract requires the
candidate-query window and the bands to share one anchor, so offsetting anywhere but the shared anchor
would point the deep bands at unfetched climbs. (3) `planKey` includes every knob so the preview
regenerates live; a started plan stays frozen (session-home never rebuilds).

## [2026-06-16] Kilter climb screen = a station in the plan: advance-by-order + reset-to-plan nav (kilter-planned-session PR 05)

**Decision**: the climb screen's session strip gains a forward loop for plan-backed runs — "Next pick →"
swaps `currentUUID` **in place** (like `goToSibling`, no stack growth) to `nextPlanClimb(excluding:)`,
and "Back to plan" does `router.open(module:"kilter") + push(KilterPlanRoute())`.

**Two anti-regression subtleties (from the PR-05 review)**: (1) `nextPlanClimb(excluding:)` advances by
**plan order** — the pending pick immediately after the current one in the ordered `planPendingUUIDs`,
falling back to the earliest pending when the current climb isn't pending. A naive "first pending that
isn't me" **oscillates** (w↔s, never reaching p) when the user taps Next pick without logging — pinned
by `testNextPlanClimbAdvancesByOrderWithoutLogging`. (2) "Back to plan" must **reset** the path
(`open(module:)`) before pushing, not bare-`push(KilterPlanRoute())`: the dominant flow is already
`[kilter, KilterPlanRoute, KilterClimbRoute]`, and a bare push appends a *second* plan route, accreting
a stale Plan/Climb pair every loop (NavigationPath has no dedup). `open()` replaces the path, so it
reaches the plan-home cleanly from any entry (plan flow or an off-plan catalog climb) — the same pattern
the live chip and Home card use. `planPendingUUIDs` is cached on the manager (lockstep with
`planProgress`) so the strip needn't fetch on every HR-tick re-render.

## [2026-06-16] Kilter plan-home reads stored status; one open plan per session; plan closed with the session (kilter-planned-session PR 02)

**Decision**: `KilterPlanView` has two modes off one screen — **generate** (recommender preview,
recomputed) and **session-home** (the live session has a pinned `KilterPlan` → read the **stored,
frozen** plan; per-pick ticks come from `KilterPlanItem.status`, order never reshuffles). On Start,
`startPlan` snapshots the preview into a `KilterPlan`, and `KilterSessionManager.attachPlan(_:in:)`
pins it (`sessionId`) and freezes it. The log path calls `applyLogToPlan` to tick the matching item.

**Invariants (from the PR-02 adversarial review)**: (1) **one open plan per session** —
`attachPlan` closes any other open plan already pinned to the session, and `startPlan` re-enters an
existing open plan instead of forking a second (with `recover` on appear + before Start so the
view matches the store on a deep-link race). Without this, a `start` that adopts a stale open session
which already had a plan could leave two open plans, and both readers use an unordered `.first` →
non-deterministic tick/order. (2) **a plan never outlives its session** — `end(sessionID:in:)` stamps
the attached plan's `completedAt` in lockstep with `session.endedAt` (no orphaned open `KilterPlan`
rows accumulating; an ended session's plan can't resurface as active), and `undoStart` deletes the
plan attached to the torn-down session. Pinned in `KilterPlanSessionTests` (store-level, unbound
manager).

**Rules out / non-obvious**: `KilterSessionManager.currentPlanId` is written here but first **read**
by the PR-03 cross-screen live chip — kept (not removed) because PR 03 is the immediate next step; the
one-open-plan invariant guarantees `currentPlanId` (keyed by plan.id) and `activePlan` (keyed by
sessionId) resolve to the same plan, so they can't diverge. The user-facing "Finish plan" (a later PR)
routes through `end`, which already closes the plan.

## [2026-06-16] Kilter planned session becomes a persisted, frozen-on-Start entity (kilter-planned-session PR 01)

**Decision**: the "Plan a session" plan stops being ephemeral `@State` recomputed from
`KilterRecommender` on every render and becomes a persisted **`KilterPlan` `@Model`** with ordered
**`KilterPlanItem`** value structs (embedded Codable array, like `KilterSession.hrSeries` — so it's
**one** new `@Model` + a trivial lightweight migration, not a SwiftData relationship). On **Start** the
recommender `Plan` is **snapshotted** into the items and the plan is **frozen** (pinned to its
`KilterSession` via `KilterPlan.sessionId`); the recommender never rebuilds it again.

**Why**: all four reported defects trace to the plan being a pure function of volatile inputs with
completion re-derived live. The headline bug — logging a Send/Project pick didn't tick it while warm-ups
did — was the recommender dropping the now-sent UUID (`allowSent: !preferUnsent`) and reshuffling on the
`entries.count`-keyed rebuild. Storing per-pick state on `KilterPlanItem.status`
(`pending`/`sent`/`attempted`/`skipped`) and reading done-ness from it (never from `logs ∩ recommend()`)
makes the defect structurally impossible and gives the run a re-enterable home.

**Rules out / non-obvious**: (1) completion is keyed by **`climbUUID`**, not a log id —
`KilterLogEntry` has no stable UUID, and `climbUUID` is also `SessionMedia.assignedClimbUUID`, so a plan
row inherits its session clips by a pure join (no plan→media FK; no `SessionMedia` schema change for
v1). (2) A later *send* upgrades an `attempted` item to `sent`; an off-plan/ad-hoc climb leaves the plan
untouched. (3) `skipped` counts toward neither done nor pending (surfaced as "N skipped" in the
summary). (4) Pure logic (`KilterPlanProgress`) is SwiftData-free so it unit-tests without a device;
the `@Model` lives in `KilterModels.swift`, registered in `SnappetSchema.models` and covered by
`SnappetBackup` (`KilterPlanRow`) — the backup tripwire + round-trip count (now 22) enforce it.
## [2026-06-16] History tracking-type facet: a pure derivation over `SessionExercise.kind` (no model change), composed in `HistorySearch`

**Decision** (workout-with-timer PR 6/6 — the final slice, prompt 72): the workout **History** gains a
**tracking-type facet** — a second chip row, alongside the routine-name chips (issue #73), of the three
`SetKind`s (Reps & weight / Time / Climb) — that keeps a session when **any** of its exercises tracks a
selected kind. A session's tracking types are **derived** from the set of `ex.kind` across its
`exercises` (`SessionExercise.kind`, which already reads `kindRaw` and defaults `.repsWeight`), so this
is a **pure derivation over existing data with NO model change** (`SetKind` + `SessionExercise.kindRaw`
already exist). The semantics are **union, not intersection** (selecting Time + Climb keeps a session
tracking *either*) and **empty selection = inert** (all sessions through), so the prior behavior is the
default. Filtering stays in the **pure, unit-tested `HistorySearch`** (no SwiftUI in the logic): a new
composable `filterByTrackingTypes(_:kinds:)` carries the one-line "any selected kind" rule, and
`apply(_:query:routine:kinds: Set<SetKind> = [])` calls it in the funnel **routine chip → tracking-type
facet → text query**. The defaulted `kinds:` keeps the existing `apply` call site and the existing
`HistorySearchTests` untouched. The chip row **mirrors `routineChips`** exactly (horizontal `ScrollView`
of plain pill `Button`s, active = `SnappetColor.workout.opacity(0.2)` fill + `SnappetColor.workout`
foreground, `.snappetAnimation(SnappetMotion.quick, value:)`, `.accessibilityAddTraits(.isSelected)`),
uses `SetKind.allCases` with each chip's `.display` label + `.symbol` icon, and is shown once
`!history.isEmpty` so a kind can always be toggled. Selection lives in a `@State private var kindFilter:
Set<SetKind>` (the `ExerciseFilters` `Set`-per-facet precedent). Chose **(both, layered)** over either a
bare `kinds:` param or a standalone helper: the helper is directly testable and composable, the param
threads it through the one funnel, and the default preserves the old surface.

**Why**: a bouldering/route session, a stretch/hold session, and a lifting session should each be
findable by *what they tracked*, not only by routine name. Deriving from `SessionExercise.kind` is the
smallest change (zero migration — nothing new persisted), and keeping the rule in pure `HistorySearch`
means it's covered without a simulator and composes cleanly with the routine + text layers already there.

**UI-test approach**: the real flow is drivable end-to-end (Quick Start → log a Timed set via the
`LogSetSheet` Manual mode → `freeform.finish` commits a saved finish with **no** confirm dialog → the
`segmentedControls["History"]` segment → toggle `history.kindChip.duration`), so `TrackingTypeFilterTests`
drives it: with a fresh store the timed session is the only `historyRow`, so toggling **Time** keeps it,
adding **Reps & weight** keeps it (union), and turning **Time** back off (leaving only Reps & weight)
**hides** it — the distinctive narrow/widen. A chip-render + toggle fallback was the documented
contingency but wasn't needed. Each chip is a **leaf** with id `history.kindChip.<rawValue>` (e.g.
`history.kindChip.duration`); rows are queried **type-agnostically**
(`descendants(matching: .any).matching(identifier: "historyRow")`, not `app.cells`) — the PR 2–5 lesson
that an id on a composite collapses the a11y subtree on iOS 26.

**Rules out**: a stored "tracking types" field on `WorkoutSession`/`SessionExercise` (derive from
`kind`); a second/parallel filter funnel (extend `HistorySearch`); intersection semantics or a
non-inert empty selection; an `accessibilityIdentifier` on the composite chip row; touching the
guided `WorkoutPlayerView`, the watch/widget, or `HighlightEngine`.

## [2026-06-16] Named free-flow climb: custom climb name via the existing `displayName` (no model change); prompt-on-tap

**Decision** (workout-with-timer PR 5/6, prompt 71): in the freeform player a **climbing** exercise can
carry a **custom climb name** (e.g. "Cave Project", "Blue V4") so per-attempt logging groups under the
named climb instead of the fixed "Climbing". Tapping "Climbing" in the add-exercise menu no longer adds
immediately — it presents a small **`.alert("Name this climb", …)`** with a leaf `TextField`
(`accessibilityIdentifier("freeform.climbName")`) + Add/Cancel; "Add" calls the **existing**
`addExercise(kind: .climbAttempt, name: SetMeasure.climbName(draft))`. The typed name is stored on the
**existing** `SessionExercise.displayName` and rendered by the **existing**
`resolver.name(for:override:)` (which already returns a non-empty override as the header) — so there is
**NO model change** and the name rides every existing path (persist · Live Activity label · backup) for
free. A new pure `SetMeasure.climbName(_:)` trims `.whitespacesAndNewlines` and falls back to "Climbing"
on a blank entry, so naming is **optional** and the prior behavior is the default. The trim/fallback is
the one tested definition (unit-tested in `SetMeasureTests`, no simulator) rather than inline in the
view. Chose the **prompt-on-tap** option over add-then-rename: it puts naming where the intent is, keeps
the per-exercise header `Menu` simple (still just "Remove exercise"), and reuses the repo's existing
alert-with-`TextField` pattern (`StudioEditorView`'s "Add text"/"Rename"). Attempt logging, the PR-4
per-attempt timer, summaries, and Repeat set are untouched; only the name the attempts group under
changes. The text field is a **leaf** with its own id and is queried via `app.alerts.textFields` (an id
on a composite collapses the a11y subtree on iOS 26 — the PR 2/3/4 lesson).

**Why**: a bouldering/route session wants attempts grouped by the *specific* problem ("Cave Project"),
not all lumped under "Climbing"; storing that in the already-rendered `displayName` is the smallest
change that achieves it (zero migration risk on the `Codable` blob). Putting the trim/fallback in pure
`SetMeasure` keeps "what name to store" as one tested rule and leaves room to reuse it from a future
rename surface.

**Deferred (device-pending)**: **photo attachment to a free-flow climb** (a reference shot of the
boulder/route) is intentionally **not** in this PR — it needs PHPicker/Photos, which is **device-only and
unverifiable in this CI-only environment** (a clean type-check ≠ a device run for Photos), so it is split
into a separate follow-up to be done where a device run is available.

**Rules out**: a new `SessionExercise`/`SetLog`/`WorkoutModels` field for the climb name (reuse
`displayName`); a second add-exercise site or inlining the trim/fallback in the view; changing attempt
logging / the per-attempt timer / summaries / Repeat set / the guided `WorkoutPlayerView`; implementing
photo attachment in this PR; an identifier on a composite alert view.

## [2026-06-16] Climb attempts: optional per-attempt timer reusing `durationSec` (no model change), off by default

**Decision** (workout-with-timer PR 4/6, prompt 70): the freeform `LogSetSheet`'s `.climbAttempt` case
gains an **opt-in** "Time the attempt" `Toggle` (`accessibilityIdentifier("logset.climbTimerToggle")`),
**default off** so quick log-and-go is byte-for-byte unchanged. When on, it reveals PR 1's
`StopwatchView(mode: .countUp)`; its `onStop` capture is stored in the **existing**
`SetLog.durationSec` — a field that was unused for `.climbAttempt` until now, so there is **NO model
change** — and `build()`'s `.climbAttempt` arm gains `durationSec: climbTimed ? climbDurationSec : nil`.
`SetMeasure.summary`'s `.climbAttempt` arm appends `formatDuration(durationSec)` (when `> 0`) after
grade/status/tries → "V4 · Sent · 3 tries · 0:42", reusing the one duration funnel. This is the
**climb-side analogue of PR 2's timed-set timer** and the **second real consumer** of the stopwatch
primitive. The `StopwatchView`'s `onRunningChange` drives a `climbTimerRunning` flag that
`.disabled(...)`s the toggle while running, so it can't be collapsed mid-run (which would tear down the
timer without a Stop and silently drop the capture — the PR 2 lesson). The toggle is a **leaf** control;
the `StopwatchView` carries **no** identifier (on iOS 26 an identifier on a composite collapses its
subtree and hides the inner `stopwatch.toggle`/`stopwatch.elapsed` from XCUITest — the PR 2/3 lesson).

**Why**: timing a boulder/route is occasionally wanted (projecting, comparing burns) but must never slow
the common grade-and-go log — hence opt-in and off by default. Reusing `durationSec` (rather than a new
`SetLog` field) means no migration risk on the `Codable` blob and the value rides every existing path
(persist · `SetMeasure.duplicate`/Repeat · backup) for free; the summary append is the only render
change, kept in the one tested formatter. `build()`'s save shape and the `SetMeasure.hasInput` Add-gate
are unchanged — grade/outcome still decide loggability; the timer is purely additive.

**Rules out**: a new `SetLog`/`WorkoutModels` field for the climb time (reuse `durationSec`); making the
timer on-by-default or mandatory; a second duration formatter; an identifier on the `StopwatchView`
composite; changing `.repsWeight`/`.duration`, the `.medium` detent, or the Add-gate.

## [2026-06-16] Repeat set: one-tap identical-set loop via a pure `SetMeasure.duplicate` through the one append path

**Decision** (workout-with-timer PR 3/6, prompt 69): the freeform player gains a one-tap **"Repeat set"**
control on every exercise that already has ≥1 logged set. It appends a copy of that exercise's most
recent set — every kind-specific field (reps/weight/unit · `durationSec` · climb grade/status/attempts)
carried over verbatim, only `completedAt` replaced with `now` — and **does not open `LogSetSheet`**. The
copy is built by a new pure `SetMeasure.duplicate(_:now:)` (next to `summary`/`hasInput`/`isSend`) and
then handed to the **existing** `appendLog(_:toExerciseID:)`, so the append + `persist()` +
`pushLiveActivity()` + `Haptics.success()` path is reused unchanged — Repeat is just another producer of
a `SetLog`, not a second save site. The control is a **sibling leaf `Button`** beside `freeform.addSet`
(`accessibilityIdentifier("freeform.repeatSet")`), gated by `if !ex.sets.isEmpty` so it's absent with
nothing to repeat.

**Why**: the slow part of straight sets / a bouldering burn of the same problem is re-typing identical
numbers; one tap removes it for the common case while the sheet stays the path for a *different* set.
Putting the copy in the pure `SetMeasure` keeps "duplicate a set" as one tested definition (a `SetLog`
struct copy carries every additive-optional kind field for free); `now` is injected so the duplicate is
unit-tested deterministically without a device. Note `appendLog` re-stamps `completedAt = .now` itself,
so the duplicate's stamp is authoritative-by-the-append — `duplicate` still owns the field-copy + stamp
semantics that the tests pin. The control is a leaf `Button` (never a wrapped composite) because on
iOS 26 an identifier on a composite collapses its subtree and hides children from XCUITest (PR 2 lesson).

**Rules out**: a second save/persist site for Repeat; inlining the `SetLog` copy in the view; opening a
prefilled `LogSetSheet` for a repeat; changing `LogSetSheet`/`build()`/`SetLog` or any `SetKind`'s
behavior; an identifier on a composite Repeat view.

## [2026-06-16] Timed sets: live-time a duration with the shared stopwatch; Timer/Manual toggle over one save path

**Decision** (workout-with-timer PR 2/6, prompt 68): the freeform `LogSetSheet`'s `.duration` case
gains a **Timer | Manual** segmented toggle, **Timer the default**. Timer mode embeds PR 1's
`StopwatchView(mode: .countUp)` — its `onStop` writes the captured elapsed back into the **same**
`minutes`/`seconds` `@State` the Manual fields use (mapped by a new pure `SetMeasure.splitDuration`,
the inverse of the build path's `min*60 + sec`), so `build()` and the `SetMeasure.hasInput` Add-gate
are **byte-for-byte unchanged** — the timer is just a third way to fill two fields, not a second save
path. This makes the freeform timed-set sheet the **first real consumer** of the stopwatch primitive
that PR 1 deliberately shipped with "no callers yet" (de-risking it before the heavier per-climb-attempt
timer, PR 5).

**Why**: typing minutes/seconds for a plank/hang is the wrong affordance — you want to press Start,
do the hold, press Stop. Routing the capture through the existing `minutes`/`seconds` state (rather than
a parallel `durationSec` state) keeps the one tested save expression and the Add-enablement gate intact,
so the only new logic is a pure, unit-tested mapping. `splitDuration` lives next to `formatDuration` /
`parseReps` / `parseWeight` because the repo funnels every duration string through one place — no second
formatter. Manual stays as an exact-value override (and the path `FreeformFlowWalkthroughTests` already
drives, after it first taps Manual).

**Rules out**: a separate `durationSec` state or a forked `.duration` save branch; inlining the
seconds→Min/Sec split in the view; a second duration formatter; changing `SetLog`/`build()`,
`.repsWeight`/`.climbAttempt`, or the sheet's `.medium` detent.

## [2026-06-16] CI + release builds pin Xcode 26.5 on `macos-26` (match the shipping toolchain)

**Decision** (workout-with-timer PR 1/6, wiring the PR CI gate): every GitHub Actions workflow that
compiles the app — `ci.yml`, `release-ipa.yml`, `testflight.yml` — pins **`runs-on: macos-26` +
Xcode 26.5** (`maxim-lobanov/setup-xcode@v1`, `xcode-version: '26.5'`): the exact toolchain this repo
is developed and verified on (see the "Xcode/SDK 26.5" entries below). NOT `latest-stable`, NOT
`macos-15`.

**Why**: the new PR CI proved the app build is **toolchain-version-fragile**, and the GitHub runners
had drifted off our toolchain. `latest-stable` on `macos-15` → **Xcode 26.3**, whose Swift
type-checker times out ("unable to type-check this expression in reasonable time") on complex SwiftUI
expressions (`WorkoutDashboardSection`, `WorkoutTrackerModule`) that 26.5 compiles fine. Pinning
"Xcode 16" → **16.4**, whose older Swift 6.0 rules make `View`-conformance actor isolation a hard
*error* (`KilterBoardView.holdPath`) where 26.5 only warns. `macos-15` also has no Xcode ≥26.4 and
only iOS 18.5/18.6/26.x sim runtimes (so Xcode 16.0–16.3 can't build for iOS there at all). Only
`macos-26` carries 26.5.

**Two pre-existing Swift 6 build breaks fixed forward** (real defects on `main`, masked by the
timeouts + by never doing a clean CI module-emit — NOT toolchain hacks): (1) `SnappetBackup.recordCount`
→ an **imperative running total**; both a 20-term `+` chain (times out on 26.3) and a 20-element
array-literal `+ reduce` (times out on 26.5) overflow the expression type-checker, but `n += …` is
trivial everywhere. (2) `SceneScorer` → **`@unchecked Sendable`** (an explicitly-`Sendable` class
whose only stored property is a thread-safe `CIContext`, which Apple doesn't mark `Sendable`).

**Rules out**: `latest-stable` / `macos-15` for any app-compiling workflow; folding `recordCount`
back into one expression; plain `: Sendable` on `SceneScorer`.

## [2026-06-10] Android CRUD sweep: one confirm component, long-press as the secondary-action idiom (issue #88)

**Decision** (prompt 41): every destructive flow goes through **one** `ConfirmDeleteDialog`
(static title, consequence in the message, destructive confirm — the iOS `confirmationDialog`
idiom), and **long-press is the suite's secondary-action gesture** (the Budget category row had
already established it; swipe-to-dismiss was rejected — it fights LazyColumn scrolling and has no
established precedent in this codebase). Kilter ascents get **status correction** (not just
delete) — a fat-fingered Flash is fixed in place, preserving timing fields. Expense group deletion
**cascades records** via `deleteExpensesFor` (flat `groupId`, mirroring the iOS sweep). Group
EDITING reuses the dormant `NewGroupSheet(existing)` mode + pure cross-group name suggestions;
the iOS "remembered me" framing is deliberately deferred (beyond this issue's ACs). The recompute
guarantee is locked at the **pure layer** (`CrudRecomputeTest`) — the stats/balance functions are
pure over input lists, so delete-then-recompute equals never-existed.

## [2026-06-10] Android Pomodoro: app-owned engine + FGS chronometer + exact alarm (issue #85)

**Decision** (prompt 40, mirroring iOS #70): `PomodoroTimerState` is owned by **`AppContainer`** —
never `remember {}`-scoped — and everything background hangs off **one seam**
(`onScheduleChanged(phase, end?)`): SharedPreferences persistence (`PomodoroStateStore`, incl.
paused progress), the **foreground-service chronometer notification** (`specialUse` FGS — timers
have no dedicated type on API 34+; the system ticks the countdown, zero app CPU), and an **exact
wake-from-Doze alarm** (`setExactAndAllowWhileIdle`; inexact fallback when the API-31+ special
access is off) whose receiver posts the phase-end alert even after process death. `sync(now)` walks
every elapsed boundary anchored at phase ends (the #70-review catch-up, ported), so a focus completed
while dead is **logged to Room during restore**. Rules out WorkManager (15-min minimum, wrong tool
for a 25-minute boundary) and a sticky service holding timer logic (the engine stays pure; the
service only renders). `POST_NOTIFICATIONS` asked in-context on the screen, not at app launch.

**Adversarial-review addenda (same day):** (1) **the alarm receiver chains the schedule itself** —
a single un-chained alarm meant every boundary after the first was silent and the countdown went
stale once the screen-scoped ticker died; the receiver now walks the persisted anchor via the pure
`PomodoroSchedule` (the SAME walk the engine's restore does, so they can't disagree), posts the
alert, refreshes the countdown via plain `notify()` (no FGS start from a background process), and
arms the next boundary. (2) A **BOOT_COMPLETED receiver** re-arms the chain — alarms die on reboot,
the SharedPreferences anchor doesn't. (3) **`MainActivity` touches `container.pomodoro` at launch**
(a foreground context) so a process-death session restores — and away-completed focuses get logged
with their **true boundary timestamps** (the seam now carries `completedAtMillis`) — without
opening the module. (4) **`USE_EXACT_ALARM`** replaces `SCHEDULE_EXACT_ALARM`: a timer app
qualifies, and the grantable variant is denied-by-default on API 34+ which would have made the
inexact (~up-to-15-min-late) path the norm. (5) Settings stepper values are clamped at the change
site and the engine refuses degenerate durations (a 0-minute phase briefly made the seam re-emit a
past schedule 4×/sec). (6) Fresh-test container swaps also clear the displaced service/alarm;
instrumented tests pre-grant `POST_NOTIFICATIONS` (`GrantPermissionRule`).

## [2026-06-10] Android branding + dark mode: vector Pulse mark, splash handoff, mode-aware board paper (issue #96)

**Decision** (prompt 39): the launcher icon is a **hand-authored vector** (white ECG "Pulse mark" on
brand coral, adaptive + monochrome) — no raster assets to generate or license; the same drawable is
the splash icon (`androidx.core:core-splashscreen`, `Theme.Snappet.Starting` → `Theme.Snappet`).
The white-flash fix is at the **window level** (`windowBackground` matching the Compose Pulse
background, with a `values-night` variant) — Compose theming alone can't fix a cold-start frame.
The Kilter board keeps its schematic look but reads a **mode-aware "board paper"** token
(`PulseColors.BoardPaper*`), resolved in the composable because a Canvas draw scope can't read the
theme; the lit (BLE) render stays black in both modes by design. Status text goes through
**`pulseSuccess()`/`pulseWarning()`** (≥4.5:1 per mode) — the old hardcoded `#1E7E48`-class hexes
were ~2.6:1 on dark surfaces. Filled send/project button colors are left for #93 (log-button
clarity) — changing fills changes meaning, not just legibility.

**Adversarial-review addenda (same day):** the 4.5:1 bar is computed against the text's OWN
alpha-tinted chip wash (the harder case — a token that passes on plain paper can fail on its wash):
SuccessLight/WarningLight darkened to `#136134`/`#854C00`, all placements verified ≥4.5:1 up to a
0.22 wash in both modes. A **`pulseNeutral()`** token covers the Attempt status (the old `#888888`
failed both modes on its chip); the BLE session chip rides `pulseSuccess()`; the create-screen role
tallies keep the LED hex as a swatch DOT while the numeral reads in `onSurface` (raw cyan digits
were ~1.3:1 on light). Accepted residuals: the tokens read `isSystemInDarkTheme()` directly (a
`SnappetTheme(darkTheme:)` override or dynamicColor would desync them — no such call site exists;
revisit with the #97 token sweep), the icon's pulse endpoints sit 0.5dp inside the adaptive safe
zone (don't widen the stroke), and #93 must include the filled log-button contrast (white on
`#30A46C` ≈ 3.2:1), not just layout clarity.

## [2026-06-10] Android: schema changes are migrations, never wipes; backup is schema-agnostic SQLite-level JSON (issue #84)

**Decision** (prompt 38) — REVERSES the documented norm that DB bumps "ride the existing
fallbackToDestructiveMigration": `exportSchema = true`, the v4 schema JSON is **committed**
(`app/schemas/`), and the destructive fallback is **gone from the build path entirely** — a missing
migration fails loudly in development instead of silently erasing every module's history in
production (the wipe path had already fired across bumps 1→4). Every future bump ships an
`autoMigrations`/`Migration` entry; `MigrationBaselineTest` is the scaffold each bump extends.

**Backup format**: one versioned JSON of column→value row maps read at the **SQLite level**
(`sqlite_master` walk + `SELECT *`), not per-entity DTOs — 17 serializable mirrors would drift,
whereas a new `@Entity` is covered with zero backup changes. Import is **strict same-schema-version**
(cross-version restore = open in the old build, migrate, re-export; never best-effort money/health
restore) and **transactional all-or-nothing**. Codec is pure (`SnappetBackupTest`, JVM); the
round-trip (export → wipe → import → identical reads + re-export equality) is instrumented.
Instrumented runs use direct `adb shell am instrument` (Gradle's connected task wedges on this
iCloud Desktop, 2026-06-09 note).

**Adversarial-review addenda (same day):** (1) pre-baseline installs (DB v1–3, whose schemas were
never exported) keep the old wipe via `fallbackToDestructiveMigrationFrom(1, 2, 3)` — a crash loop
would brick them and correct migrations can't be authored retroactively; never-wipe holds from the
committed v4 baseline forward. (2) Import runs through `db.runInTransaction` so Room's
InvalidationTracker refreshes — every module screen observes DAO Flows, which a raw SQLite
transaction left rendering pre-import data. (3) `userTables` filters in Kotlin with literal
prefixes — SQL `LIKE 'room_%'` treats `_` as a wildcard and would silently drop a future table
named e.g. `rooms` from every backup. (4) BackupScreen's encode/stream legs run on Dispatchers.IO
(SAF uris can be remote providers), and a failed export deletes the empty document it created.
**Accepted residuals (tracked, not fixed here):** strict same-version import means backups don't
outlive a schema bump — the v5-era follow-up is migrate-on-import (materialize the payload into a
temp DB at its version, run the now-mandatory migrations, re-read); and the migration tripwire is
instrumented-only (no Android CI exists in this repo) — bumps must run `MigrationBaselineTest`
manually until CI lands.

## [2026-06-10] Money entry: commit-then-save + keypad Done everywhere; "me" is a device-local convention (issue #82)

**Decision** (prompt 37): every value-formatted money form saves through **commit-then-save** (resign
focus, then save on the next runloop tick) because `TextField(value:format:)` commits its binding on
focus resign — a mid-edit Save must never read the stale value. The keypad-Done affordance is **one
shared `keypadDoneToolbar`** (Tip's `placement: .keyboard` pattern, promoted to DesignSystem with a
`Bool` and a `Hashable?` overload) rather than per-form copies. The settle-up rows became buttons that
open `RecordSettlementSheet` **prefilled** via a new initializer — same sheet node, new entry point, so
the knowledge graph is unchanged. **"Me" is `@AppStorage("expense.myName")`, set by convention from
slot 1 of a group the user creates** — rules out accounts, contacts access, and a profile screen for
what is one string; an edit never overwrites it (you may manage a group you're not in). Second-person
phrasing + cross-group name suggestions are pure `SettleUp` helpers (`FinanceUXTests`).

## [2026-06-10] One tactile language: shared Haptics + a single celebration primitive (issue #80)

**Decision** (prompt 36): all commit feedback goes through **one** `DesignSystem/Haptics` helper
(success / warning / tap; the `WorkoutPlayerView` enum promoted, Pomodoro's bespoke generator
removed) and all milestone moments through **one** `.celebrates(on:)` modifier wrapping a
TimelineView/Canvas confetti burst (no particle dependencies). **Reduce Motion suppresses the burst
entirely — the success haptic alone acknowledges the moment** (consistent with the SnappetMotion
contract; a "reduced burst" would still be motion). Milestone decisions are pure and unit-tested:
`HabitMilestones` (streak math extracted from the view — one definition for the list UI and the
toggle-time decision; milestones [7, 30, 100], a backfill jump fires only the highest) and
`KilterMilestones.isFirstSend` (prior-send count fetched BEFORE the new log lands so an entry can't
shadow itself). Rules out per-feature generators and `.sensoryFeedback` scattered per-view (one seam
to tune), and celebration on every send (only the *first* at a grade — scarcity keeps it meaningful).

## [2026-06-10] Pomodoro: app-owned timer + schedule-at-start notifications + third Live Activity (issue #70)

**Decision** (prompt 35): `PomodoroTimer` is **owned by `AppModel`** (the `KilterSessionManager`
hoist pattern) so popping to the Apps grid no longer kills a running session; the view is just a
window onto it. Background alerting hangs off **one seam** — `PomodoroTimer.onScheduleChanged(phase,
endDate?)`, fired on start / auto-advance (absolute end) and pause/reset (`nil`) — wired once in
`AppModel.init` to (a) `PomodoroNotifications` (the `WorkoutNotifications` schedule-at-start pattern:
a foreground ticker is suspended in the background, a scheduled `UNNotification` is not; stable id,
replace-don't-stack) and (b) `PomodoroLiveActivityController` (a **third, separate**
`ActivityAttributes` type — same reasoning as Kilter's, 2026-06-06; countdown rendered with
`Text/ProgressView(timerInterval:)` so the OS ticks it with zero background CPU; no update throttle
needed — phase edges only). Rules out: scenePhase-driven re-sync hacks, a foreground-only haptic as
the sole completion signal, and overloading the workout/Kilter activity contracts. The in-app
re-entry chip is **scoped to the Apps tab's NavigationStack** (overlay on `AppLibraryView`) because
`SuiteRouter` is still `@State` there — the shell-global surface arrives with the #71 hoist.
Live Activity / lock-screen **render** is device-pending (the Kilter verification class).

**Adversarial-review addenda (same day):** (1) notification `add()` fails silently while auth is
`.notDetermined`, so `scheduleBoundaries` issues its adds **from the authorization completion**
(immediate pass-through once determined) and the screen prompts on appear — otherwise the first-ever
focus block alerts nothing. (2) **Two boundaries stay scheduled** (this end + the next phase's end):
the app can't schedule while suspended, so a phone locked through focus still gets "break's over".
(3) `sync(now:)` walks **every** elapsed boundary anchored at each phase's end (not at resume time)
— reopening after a long lock lands mid-whatever-phase the wall clock says; internal for injected-now
tests. (4) The timer distinguishes **paused from idle** (`isPaused`) so the root view's re-applied
durations can't wipe a paused session's progress. (5) The chip overlay hangs on the
**NavigationStack itself** — on the root page it would slide away under every pushed module.
(6) Relaunch **adopts an orphaned Live Activity** (the Kilter `adoptRunningActivity` pattern) and
restores the countdown from its absolute end, or cleans up if the end passed (that focus is not
retro-logged — the store isn't reachable from `AppModel.init`; accepted). (7) The
`com.apple.developer.usernotifications.time-sensitive` entitlement is declared so the phase-end alert
survives a user's focus mode — the canonical Pomodoro configuration.

## [2026-06-10] Destructive deletes confirm via dialog (no UndoManager); Journal blank cleanup on onDisappear, not defer-insert

**Decision** (prompt 34, issue #69): Expense-group, budget-category, and journal-entry deletes stage a
`pending…` value and confirm through `confirmationDialog(presenting:)` — the pattern Habits already
shipped — with a **pure impact-message builder** (`ExpenseGroupDeleteImpact` / `BudgetCategoryDeleteImpact`)
stating exactly what cascades (group → its `ExpenseRecord`s, which the flat `groupID` reference would
otherwise orphan; category → its transactions across **all** months). Rules out an Undo affordance: no
`UndoManager` is configured anywhere in the suite, and one dialog idiom everywhere beats two recovery
models.

**Journal blank rows — discard on POP, never on onDisappear**: kept `createEntry()`'s
insert-before-navigate (the editor's `@Bindable` and SwiftData autosave preserve typed content if the
user back-swipes), and the abandoned-blank discard runs in `JournalRootView` from
`.onChange(of: newEntry)` — the `navigationDestination(item:)` binding nils exactly on pop. An
`.onDisappear` cleanup in the editor was tried first and **adversarial review proved it a blocker**:
`onDisappear` also fires on a TabView tab switch (the Apps tab's stack is preserved `@State`), which
deleted the entry out from under the still-pushed editor — Done then silently failed to persist the
typed entry. Rules out: editor-side onDisappear cleanup (tab-switch hazard) and defer-insert-until-save
(silently discards typed content on back-swipe). Residual process-death path (autosave persists the
pre-inserted blank; no view callback fires) is closed by an appear-time sweep using
`JournalEntry.isAbandonedBlank` = blank **and** `updatedAt == createdAt` (never Done-saved — so a real
entry the user deliberately emptied is never swept); `createEntry()` pins both dates to one instant
because the init's two `.now` defaults differ by microseconds. All definitions unit-tested in
`DeleteConfirmationTests`; the Expense cascade is locked by `ExpenseGroupDeletionTests` (in-memory
container). Confirmation dialogs use a **static title + `presenting:`** so the copy can't flash nil
fallbacks during the dismiss animation (the Habit dialog's immunity, kept deliberately).

Tip/Kilter-history single-row swipes stay unconfirmed deliberately — one low-stakes row per swipe.

## [2026-06-07] Kilter board session lifecycle — persisted store is the single source of truth

**Decision**: The active Kilter session is no longer in-memory-only. `KilterSessionManager` is **owned
by `AppModel`** (not `@State` on `KilterRootView`) so it survives navigating out of the module, and it
**recovers** the open session (`endedAt == nil`) from SwiftData on appear/relaunch via the pure
`KilterSessionRecovery` planner. Recovery enforces a **single-open-session invariant** (adopt the
newest open, auto-close duplicates) and **auto-closes sessions abandoned > 6 h** (stamped at last
activity, never "now"). `end(sessionID:in:)` closes a session by id from any surface.
(`pdd/prompts/features/11-kilter-session-lifecycle.md`.)

**Why**: `KilterRootView` is a `navigationDestination`; SwiftUI destroyed/recreated it on pop, resetting
the `@State` manager to `current == nil` while the `KilterSession` row stayed open. That stranded the
session: the bar vanished, "End" became a no-op, post-reset logs got `sessionId: nil` (orphaned /
double-counted), and board-connect / re-start forked duplicate open sessions. An audit found 23 such
failure modes, nearly all downstream of this one defect.

**Also**: the session is **decoupled from the BLE link** — a board *disconnect* no longer ends the
session (a brief drop shouldn't kill an in-progress session); the board→session bridge moved from the
transient detail view to the root (stable). History surfaces live sessions (badge + running timer) with
swipe-to-End; History/Settings "Clear" skip the active session.

**HR-on-clips during the session**: `hrSeries` used to be flushed onto the session only at `end()`, so
clip HR overlays were empty until the session ended (the clip editor reads the *persisted* series via
`SessionHRSeries.forSession`, once, on open). Added `KilterSessionManager.syncLiveHR(in:)` — flushes the
cumulative live HR buffer onto the active session **without ending it** — called on opening the session
summary, after each log, before opening a clip, and before "Find my clips". Clips recorded mid-session
now overlay heart rate without ending the session first.

**Rules out**: tracking "active" purely in memory; ending via the in-memory `current` pointer; coupling
session lifetime to the board connection. **Deferred (low/device-only)**: Live-Activity `staleDate`,
live-summary stats throttle, tagging the cross-module activity log with the session id.

## [2026-06-07] Freeform/dynamic WorkoutTracker sessions + ad-hoc climbing (polymorphic SetKind)

**Decision**: Made WorkoutTracker sessions **grow-as-you-go** and able to log **ad-hoc (non-Kilter)
climbing** — gym bouldering / outdoor — which the user confirmed they do. (dynamic-sessions D3/D4/D5;
`pdd/prompts/features/dynamic-sessions/DESIGN.md`.)

- **Polymorphic set unit (D4).** `SetKind` (`repsWeight`/`duration`/`climbAttempt`) on
  `SessionExercise.kindRaw: String?` (nil ⇒ legacy reps/weight) + **optional** fields on `SetLog`
  (`durationSec`, `climbGradeLabel`, `climbStatusRaw`, `climbAttempts`). **Migration nuance (load-bearing):**
  `SetLog`/`SessionExercise` are nested **Codable composites**, not `@Model`s — SwiftData lightweight
  migration doesn't reach inside the encoded blob, so every added field is **`Optional`** (synthesized
  `Codable` decodes a missing optional key as nil; a non-optional key would throw on old data). The climb
  outcome **reuses `KilterAscentStatus`** (one climbing vocabulary across Kilter + WorkoutTracker +
  the recommender). Pure `SetMeasure` (summary/format/validate, e.g. "8 × 60 kg" / "0:45" /
  "V4 · Flash · 3 tries") + `SetMeasureTests` (12 cases). **Rejected** a `SetMeasure`
  enum-with-associated-values (bigger hand-written-`Codable` surface, no user-visible gain).
- **Freeform player (D3/D5) is a NEW, self-contained view, not a rewrite.** `FreeformPlayerView` (a
  list-based logbook) handles routineless sessions (`routineID == nil`): add exercises (Lifting via the
  existing `ExercisePickerView` · Climbing · Timed), per-exercise add set/attempt via a kind-adaptive
  `LogSetSheet`, swipe-delete, finish. **Why separate:** the guided `WorkoutPlayerView` is device-verified
  and tightly coupled to reps×weight + a fixed index walk; a logbook is the right shape for "add as you
  go" and avoids destabilizing it. **Quick Start** (`startFreeform()`) creates the empty session; the
  player cover branches on `routineID == nil`. `SessionDetailView.detailText` now renders climb/timed
  sets via `SetMeasure` (detected from the set's own fields → no call-site churn).

**Why**: closes the "I don't know my next climb / I want to add as I go" gap for non-board climbing and
ad-hoc lifting, reusing the existing model (no new `@Model`, additive-only) and finish/HR pipeline.

**Rules out / caveats**: **No build/sim/test run** — the authoring box has no Swift toolchain, so
`xcodebuild test` + a sim pass on a Mac are owed (only the graph integrity was checked: 162 nodes / 284
edges, no orphans/dups). Followups: distance/GPS (Shape ②) isn't a `SetKind` yet; ad-hoc Climbing/Timed
exercises use a fixed default name (inline rename later). Graph: added `wt-freeform-player` +
`wt-set-measure` nodes.
- **Freeform Live Activity (fixed in review).** `FreeformPlayerView` now pushes to the **Live Activity**
  (mirroring `WorkoutPlayerView`): live HR + the current exercise + the paused state, via `onChange` on
  `liveWorkout.latestHR`/`isPaused` and after each log/add. Previously it only seeded the activity once,
  so the Lock Screen showed a stale "Workout" label, blank HR, and a timer that kept running while
  paused. Only the per-set "Set N of M" line is intentionally omitted (a freeform logbook has no fixed
  target); the `startLiveActivity` seed also no longer emits a nonsensical "Set 1 of 0" for an empty
  freeform exercise.

## [2026-06-07] Kilter-driven session recommender — pick a session from your logs

**Decision**: Shipped the high-value remainder of the dynamic-sessions design (`pdd/prompts/features/
dynamic-sessions/DESIGN.md`, refreshed) as a **pure recommender + a Plan screen in the Kilter app**.
Re-baselined first: `main`'s `18-ios-kilter-rich-session` already gave climbing sessions live HR, per-climb
timing/attempts (so a board session is *already* the "dynamic climbing" the user asked for), media + a
highlight reel, and a rich summary — so the original Part B (project Kilter into WorkoutTracker history)
was **dropped** (redundant; would fight the 2026-06-02 "keep Kilter separate" call). What remained novel
was *using* the logs to suggest a session.

- **`KilterRecommender` (pure, Foundation-only)** — `[KilterClimbLog]` history + `[KilterListItem]`
  candidates → a goal-tagged `Plan` (Warm up / Send / Project). Detects the **working grade** = hardest
  rounded-difficulty bucket with ≥ `sendThreshold` (default 2) sends (else hardest single send, else nil
  cold-start); allocates `targetCount` ~⅓ warm-up / bulk sends / one project; bands warm-ups below, sends
  at, project above the working bucket; ranks by quality→ascents→easiest→uuid (**deterministic**);
  `preferUnsent` keeps already-sent climbs out of send/project goals. **Reuses** the existing
  `KilterClimbLog` value type (from `KilterSessionStats`) and catalog `KilterListItem` — no new `@Model`,
  no schema change, no migration.
- **`KilterPlanView` + `KilterPlanRoute`** — More-menu "Plan a session": reads `KilterLogEntry`s, queries
  the catalog for a window around the working grade, runs the recommender, shows grouped picks; **Start
  session** begins a manual `KilterSession` (reusing `KilterSessionManager` → live HR / Live Activity /
  media) and taps through each pick, with a live "logged this session" check.
- **Tests**: `KilterRecommenderTests` (14 cases — working-grade detection, allocation sum, banding by
  goal, prefer-unsent, higher-quality-wins, determinism, no-dup-across-goals, cold start, empty
  candidates, **candidate-window coverage, explicit-anchor band centre, deep warm-up fallback**).
  **Graph**: added `kilter-recommender` (pure) + `kilter-plan` (screen) nodes + edges
  (integrity re-checked: 162 nodes / 284 edges, no orphans/dups).
- **Recommender ↔ view coherence (fixed in review).** The band centre and the catalog-query window
  must share one `anchor`: `recommend` takes an explicit `anchor:` and the view fetches over
  `KilterRecommender.candidateWindow(anchor:)` (`w-4.5 … w+2.5`, fully bracketing the warm-up→project
  bands). Earlier the view fetched `anchor-3 … anchor+2`, leaving the `w-4` warm-up fallback unfetchable
  and letting two independent cold-start anchors (grade-scale median vs candidate median) disagree and
  silently drop a goal.

**Why**: it's the most on-brand piece — a deterministic pure function over data the app already keeps,
turning history into action — and the catalog/session machinery to act on it already exists.

**Rules out / honest caveat**: recommender lives in **Kilter**, not WorkoutTracker (follows main's
"Kilter is the climbing home"; the pure core is UI-agnostic so it's reversible). Remaining/ deferred:
freeform **lifting** Quick-Start sessions (A.1) and a polymorphic `SetKind` for **ad-hoc** non-catalog
climbing in WorkoutTracker (A.2, gated on a product call now that Kilter covers board climbing). **No
build/sim/test run**: the authoring box has no Swift toolchain, so `xcodebuild test` on a Mac is owed to
green the recommender tests + sim-verify `KilterPlanView` (only the graph integrity was checked here).

## [2026-06-06] Kilter Board — LED map by the user's BOARD SIZE + send led_color (real-board fix)

**Decision**: Resolve each lit hold's LED address from the `leds` table **for the user's chosen
`product_size`**, not an arbitrary one, and send the role's **`led_color`** (not `screen_color`) to the
board. Found on real hardware: the board connected and lit up (the #52 GATT/framing fix worked) but lit
the **wrong/shifted holds**.

- **Root cause**: `ledPositions` used `MIN(product_size_id)` for the layout — i.e. it always assumed
  one specific board size (for Kilter Original that's size 7, "12×14 Commercial", 527 LEDs). A layout
  exists in **many** physical sizes (Original: 7×10/8×12/12×12/12×14/16×12; Homewall: per-dimension ×
  LED-kit), and the **same hole has a different `leds.position` on each size**, so any other board lights
  the wrong LEDs. A taller assumed board (12×14) shifts every address → the user's "shifted/offset"
  symptom.
- **Fix**: `KilterCatalog.sizes(forLayout:)` lists a layout's `product_sizes`; `holds(for:sizeId:)`
  maps LEDs for the selected size (falling back to the layout's smallest when unset/invalid).
  `KilterHold` gains `ledColorHex` (`placement_roles.led_color`) used by the controller, keeping
  `colorHex` (`screen_color`) for the on-screen render — they differ for `start` (LED `00FF00` vs
  screen `00DD00`).
- **UX**: a persisted **Board size** preference (`kilter.productSizeId` AppStorage / SharedPreferences),
  picked in Settings (next to Board/Angle) and in the inline **"Wrong holds?"** control on the climb
  screen (size picker first — the likely cause — then the Standard/Legacy dialect). Changing it re-maps
  every LED and re-lights the current climb instantly. Seeded to the layout's default; reset when the
  layout changes.

**Why**: the board can't report its size and the LED address space is size-specific, so the app must
know the size — there's no auto-detect. **Rules out**: a single hardcoded size; a uniform position
offset (sizes differ in hole sets, not by a constant shift); per-climb size. **Verified**: off-device
unit/instrumented tests with a 2-size fixture prove `holds(sizeId:)` selects the right size's positions
and the board uses `led_color` (`KilterCatalogStoreTests` / `KilterCatalogStoreTest`). Lighting the
**correct** holds on the wall stays **device-pending** until re-tested on the real board with the size set.

## [2026-06-06] Kilter Board — ship both Aurora payload dialects (Standard/Legacy) with a user toggle

**Decision**: Support **both** Aurora illumination "API levels" and let the user choose, rather than
hardcoding level 3. The level is the *payload* dialect, set by the board's firmware generation; it is
**not advertised or negotiated**, so the app can't auto-detect it. A mismatch still **connects** fine
(same BLE link/UUIDs) but lights the **wrong holds/colors** — so the right UX is a cheap manual switch
exactly where the problem shows up.

- **Encoder** (`KilterProtocol`, both platforms): added `APILevel { v3, v2 }`. `messages(for:level:)`
  defaults to `.v3` (so the connect-fix tests and all existing callers are unchanged). `v3` = 3-byte
  holds, R3G3B2, markers 82/81/83/84; `v2` = 2-byte holds (byte0 = position low 8 bits; byte1 =
  R2G2B2 in bits 7–2 OR the high 2 position bits in bits 1–0), markers 78/77/79/80. `bodyChunk = 12`
  serves both (multiple of 2 and 3; framed ≤ 20 bytes either way). Color packers (`colorByte` v3 /
  `colorBitsV2`) are pure + unit-tested with exact byte vectors.
- **Controller**: holds `apiLevel` + remembers `lastHolds`; `setAPILevel(_:)` switches dialect and, if
  a climb is currently lit, **re-sends it immediately** so the wall updates live. No-op when unchanged,
  so it's safe to call on every settings sync.
- **UX (smooth path)**: default **Standard** — zero friction for the ~all boards that use it. Two ways
  to switch, both persisted (`kilter.apiLevel` AppStorage / SharedPreferences): a **Settings** picker,
  and — the key affordance — a quiet **"Wrong holds lighting up?"** link in the *connected* controls on
  the climb screen that reveals a Standard/Legacy switch and re-lights instantly. The shared controller
  is the single sink; the root view (iOS) / root + detail `LaunchedEffect` (Android) push the persisted
  value down, so a change anywhere takes effect everywhere without re-navigating.

**Why**: shipping both encoders + a one-tap switch is far better UX than guessing wrong and showing a
broken wall, and there's no reliable on-wire signal to auto-pick. **Rules out**: auto-detecting the
level (not possible over BLE); a level-negotiation handshake (Aurora doesn't expose one); per-board
persistence (one preference fits a user's single wall). **Verified**: pure encoder vectors for both
levels pass off-device on iOS + Android (`KilterProtocolTests` / `KilterProtocolTest`). The live
re-light + the switch UI stay **device-pending** per the repo's hardware rule.

## [2026-06-06] Kilter Board — fix BLE connect addressing + packet framing

**Decision**: Correct the Aurora/Kilter BLE protocol on both platforms to match the canonical
community reverse-engineering (`1-max-1/fake_kilter_board`). Two bugs, both of which the prior code
flagged as "device-unverified — verify against hardware":

- **Wrong GATT addressing (the connect bug).** The controllers discovered services/characteristics on
  the board's *advertised* service `4488B571-…` and looked for a `4488B572-…` write characteristic
  that doesn't exist. `4488B571` is only **advertised**; the writable endpoint is the **Nordic UART**
  GATT service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` + characteristic `6E400002-…`. With the wrong
  UUIDs the write characteristic was never found, the connection never reached `.connected`, and the
  discovery watchdog fired with *"Connected, but the board didn't respond. Try again."* — the reported
  symptom. Fix splits the constant into `advertisedServiceUUID` (scan/recognise + `retrieve­Connected­Peripherals`)
  vs `gattServiceUUID`/`writeUUID` (discover + write). `isLikelyBoard` keeps matching the advertised
  UUID/name, so that test is unchanged.
- **Malformed packet framing.** `wrap()` emitted `[0x01, len, cksum, <payload>, 0x02]`; the spec is
  `[0x01, len, cksum, 0x02, <payload>, 0x03]` (missing the `0x02` data marker; terminator must be
  `0x03`). Corrected, and `bodyChunk` drops `15 → 12` (4 holds × 3 bytes) so the framed packet is
  `6 wrapper + 1 marker + 12 = 19 ≤ 20` bytes. The hold encoding (uint16-LE position + R3G3B2 color)
  and markers 82/81/83/84 were already correct.

**Why**: these are the only things wrong on the connect path; the rest (scan-by-name, system-connected
adopt paths, timeout watchdog) is sound. **One axis deliberately left out of scope**: Aurora "API
level 2" (older boards — 2-byte holds / R2G2B2 / markers 77–80). The write **UUIDs do not vary by
board** across the Aurora family (Kilter/Tension/Grasshopper/Decoy/So iLL all share the Nordic UART
endpoint), so no multi-UUID handling is needed; only the *payload* API level differs, and level 3 is
now the common case. **Rules out**: per-board UUID tables; API-level-2 fallback (a follow-up if an
older board surfaces); negotiating the API level (it isn't negotiated — the app picks).
**Verified**: new pure encoder tests (`KilterProtocolTests` / `KilterProtocolTest`) pin the exact
framed bytes off-device on both platforms. The live BLE write path stays **device-pending** per the
repo's hardware rule — not reported as working until lit on a real board.

## [2026-06-06] Kilter — in-app catalog download from a hosted dataset (Phase 2) (#42)

**Decision**: `KilterCatalogSyncView` gains a **Download from Kilter** button that fetches a board's
catalog as a **gzipped SQLite from a static host the user controls** (the Snappet *Board Explorer*
GitHub Pages site, `board-data/<board>.sqlite.gz`, by default), then **trims it on-device** with the
same filters the explorer's `exportDb.ts` uses, and installs it through the unchanged
`KilterCatalogInstaller` path. The user **explicitly accepted the legal trade-off** (2026-06-06) that
prompt 22 deferred. This reverses *only* the "sync stays inert" part of the [2026-06-05] entry;
everything else there (no re-bundling, user-data model untouched, file-import primary) **still holds**.

**Why a hosted dataset and NOT Aurora's API**: the first cut called Aurora's `/sync` directly (mirroring
`boardlib`'s `login` + paginated sync). That host (`kilterboardapp.com`) turns out to **reject every TLS
handshake** (verified from macOS curl/openssl/Python *and* the iPhone — an IONOS box that returns
`internal_error`); `boardlib`'s real catalog path doesn't use `/sync` at all, it extracts `db.sqlite3`
from the official APK. Scraping a 108 MB APK from apkpure on-device was the only other "live" path —
heavy, fragile, and the worst legal posture. The user already hosts the datasets on their own Pages
(under their own ToU acceptance) via the Board Explorer, so the app just downloads a file from a URL the
user controls — much closer to "bring your own file" than any Aurora-direct fetch.

**Concrete choices made:**
- **`KilterAuroraSync.swift` → `HostedCatalogClient`** owns the module's only `URLSession` (ephemeral):
  one GET for `manifest.json` (to list importable boards) and one for `<board>.sqlite.gz`. It streams
  the gzip through **zlib** (`inflateInit2_(…, 47)` — added `libz.tbd` + `#import <zlib.h>` to the
  bridging header) to a temp file, never holding the ~165 MB raw DB in memory.
- **Trim mirrors the Board Explorer `exportDb.ts`**: `ATTACH` the downloaded DB, recreate each table from
  its source DDL, copy reference/geometry tables (`FULL_TABLES`) whole, subset the climb tables to a
  `_keep` set of filtered uuids, recreate indexes, `VACUUM`. The filter (`CatalogFilter`) mirrors
  `query.ts buildConditions` (layout/grade/ascents/quality/setter/name/benchmark/listed/single-frame)
  **plus a `maxClimbs` top-N-most-climbed cap** — the explorer expects manual narrowing; a phone always
  caps (like `build_bundled_db.py --limit`). Real-data check: top-2000 → a **6.1 MB** importable catalog.
- **No accounts.** The dataset is a static file, so there are no credentials — the picker is board +
  filters only. The host URL is editable (`@AppStorage`) so the user can point elsewhere.
- **Pure half unit-tested; download is device-owed.** `KilterAuroraSyncTests` covers the real zlib
  gunzip (round-trip) and the filtered build (top-N cap, empty-match → throw, benchmark-only) by feeding
  the `KilterCatalogFixture` as a synthetic source through the real reader. The 81 MB download itself is
  verified on the physical device.

**Follow-up same day (filter parity · layout scope · multi-catalog library):**
- **Full Board-Explorer filter parity** in the download sheet — `CatalogFilter` already mirrored
  `query.ts buildConditions`; the sheet now surfaces all of it (layouts, **angle**, min/max grade, min
  ascents, min quality, setter, name, benchmark/listed/single-frame) + the top-N cap. Grade/angle/layout
  option lists are **static Kilter constants** (`KilterCatalogOptions`) since the dataset isn't loaded
  until after download; the grade scale is the real `difficulty_grades` (difficulty 10–33 → V0–V16).
- **Scope today = Kilter Original (1) + Homewall (8) only.** Other boards (from the manifest) and other
  Kilter layouts render **struck-through / disabled** in the sheet as explicit future work — the reader
  is Kilter-shaped and only these two layouts are validated.
- **The store became a multi-catalog *library*.** `KilterCatalogStore` now keeps each install under
  `catalogs/<uuid>/` with an `active-catalog` pointer file (was a single `kilter.sqlite3`); `install`
  **adds + activates** (no longer replaces), and there's `installed()` / `remove(id:)` / `setActive(id:)`
  + a one-time migration that folds any legacy single file into the library. A meta `name` (optional,
  back-compat) labels each entry. **Settings** gained a **Download from Kilter** button and a
  **Downloaded catalogs** list — tap to make active, swipe to remove — replacing the single
  refresh/remove rows. The reader still opens the *active* catalog and reloads on the change
  notification, so switching active in Settings re-points browse.

**Android port (same day):** the whole feature is ported to Kotlin/Compose at parity — `HostedCatalogClient`
(`HttpURLConnection` + `java.util.zip.GZIPInputStream`, so no zlib shim is needed unlike iOS;
`SQLiteDatabase` ATTACH for the same exportDb-style trim), the multi-catalog `KilterCatalogStore`
(`catalogs/<id>/` + `active-catalog` pointer, install adds + activates, `installed()`/`remove(id)`/
`setActive(id)`, legacy migration), a `KilterCatalogDownloadSheet` (ModalBottomSheet) with the full
filter set + Original/Homewall scope (others struck-through), and a Settings **Downloaded catalogs**
list (RadioButton active + per-row Remove) + **Download from Kilter** button. Added the **INTERNET**
permission (was BLE-only). One Android-specific gotcha: `SQLiteDatabase.execSQL` rejects
`PRAGMA journal_mode` (it returns a row) — dropped the PRAGMA optimizations. Instrumented suite green
(23, incl. multi-catalog + filtered-build). Device-owed: the live ~80 MB download → trim on a real
Android device (the pure half is covered).

**Rules out / guardrails (unchanged)**: **not** for public App Store distribution — Aurora's ToU +
App Store Guideline 5.2.2 keep this **personal / sideload** only; the carve-out stays narrow + named.
No Aurora API calls, no re-bundling a catalog into the app, no background/auto sync (user-initiated
only), no analytics, no Snappet backend, nothing uploaded; egress is one GET to the configured host. The
user-data model (`KilterLogEntry`/`KilterSession`/`KilterFavorite`) is untouched and file-import stays
primary. Android port to follow (the seam is identical).

## 2026-06-06 — Rich text overlays: wrap-to-width fit + colour/highlight/font/style (P21)

Device feedback: a large climb-name caption spilled past both edges of the video, and text had no
styling. Two changes. **(1) Wrap-to-width fit** — the `.climbName` preview chip had NO width cap (only
`.text` did), so it grew as wide as the text and overflowed into the letterbox; the export box was also
sized from EXPLICIT newlines, not wrapped lines. Now both **wrap to ~0.9 of the video width**: the
preview uses `.frame(maxWidth: rect.width*0.9)` + `fixedSize(vertical)`, and the export measures the
wrapped height via `NSAttributedString.boundingRect` and sizes the `CATextLayer` container to it — so a
multi-line caption never clips and preview == file. **(2) Rich style** — `OverlayItem` gained
`highlightHex` (background), `fontRaw` (a new pure `StudioFont` enum: system/rounded/serif/mono), `bold`,
`italic` — all **additive + defaulted** (migration-safe Codable, like the prior optional fields).
Rendered in BOTH the SwiftUI preview (TextOverlayChip.styledText) and the Core-Animation export
(StudioOverlays.styledTextLayer) via a shared mapping: `StudioFont.swiftUIDesign` ↔ `uiFont`
(UIFontDescriptor design + symbolic traits). Text + climb-name now share ONE styled path (climb-name is
text with a dark-highlight default). A paintbrush "Style" sheet (StudioTextStyleControls) edits colour /
highlight (None + swatches) / font / bold / italic; all commit `editOverlaysOnly` (overlays aren't in the
playback composition → no rebuild). **Why a font ENUM, not a font-name string**: the four presets map
cleanly to a `Font.Design` (SwiftUI) and a `UIFontDescriptor.SystemDesign` (UIKit) so preview and export
match without bundling fonts; arbitrary font names wouldn't render identically in CATextLayer. **Why the
export measures wrapped height**: a fixed line-count box clips wrapped captions; `boundingRect` is the
only way to size the chip to the actual wrapped text. **Rules out**: a climb-name chip with no width cap;
sizing the export box from `\n` count; a font-name string field; a separate ClimbName config (text +
climb-name share the styled layer). **Limitation**: climb-name's highlight has a dark fallback so it
always shows some background (the picker recolours it); fully removing it isn't exposed. **Verified**:
builds clean, full unit suite green (301) incl. the new style setters + migration-safe defaults. **Device
pending**: the styled caption rendering in **export** on real footage.

## 2026-06-05 — PiP/base resize: aspect-locked corner-drag + flicker-free live resize (P21)

Device verification of the placement fix surfaced two more resize issues, both fixed in
`StudioOverlayCanvas`. **(1) Letterbox on free resize** — after the fill→fit change, dragging a PiP
corner to an aspect ≠ its footage left the dashed box bigger than the aspect-fit video (the box stopped
hugging the video). Fix: **lock corner-resize to the source aspect** — the canvas now receives
`sourceAspects` (resolved oriented w/h per `localIdentifier`, already computed in the VM) and the base
video's aspect; `ResizableFrame.resizedFrame` derives the off-axis from `contentAspect` and
`clampedAspectSize` clamps into [0.1,1] **while preserving the ratio**, so the box always keeps the
footage aspect → the fit video fills it edge-to-edge. Pinch + grid presets still allow free aspect (for
collages). **(2) Resize flicker** — the live-resize had been driven by a `@State liveResize` SET FROM
the corner handle's own gesture callback, and the handle's on-screen position was recomputed from that
same state. So the handle moved out from under the finger → re-fired its gesture → oscillated (the
new aspect-lock branch `newW >= newH·r` toggling each frame amplified it into a visible flicker,
confirmed by frame-diffing a screen recording: the changing pixels were the box/handles, not the video).
Fix: the **canonical SwiftUI draggable pattern** — replace `@State` with a `@GestureState cornerDrag`,
anchor the gesture-hosting handles at the **committed** size (they never move during the drag, so the
gesture's translation stays stable), offset ONLY the dragged dot, and render the live-resizing outline
as a **non-interactive** overlay (hosts no gesture → can't feed back). **Why @GestureState over @State**:
@GestureState is bound to the gesture lifecycle and auto-resets, and — critically — moving it out of the
handle's layout-position path is what breaks the feedback loop. **Rules out**: driving live-resize layout
from a `@State` the gesture writes; repositioning a gesture host from its own gesture value; per-axis free
resize for a PiP (now aspect-locked on corner-drag). **Verified on device (MrRobot)**: placement sits
under the outline (preview), corner-resize hugs the video with no letterbox, and the drag is smooth (no
flicker) — confirmed by screen recording. Builds clean; full suite green.

## [2026-06-05] Kilter — stop redistributing Aurora's catalog; opt-in on-device fetch (#42)

**Decision**: The Kilter mini-app no longer **ships** Aurora Climbing's climb catalog. The bundled
`kilter.sqlite3` is **deleted** from both platforms (`ios/App/Snappet/Resources/`,
`android/app/src/main/assets/`) and the app contains **zero** Aurora climb data. Instead, the catalog
is **imported onto the user's own device**, under their own relationship with Aurora — the redistribution
exposure flagged in #32 OQ#11.2 is removed **architecturally**, not by waiting on a licensing
negotiation. Traces to [#42](https://github.com/harshal2802/snappet-mobile/issues/42); the
written-permission path (option 2) stays recorded as complementary future scope.

**Concrete choices made:**
- **A catalog-provider seam, read path unchanged.** A new `KilterCatalogStore` owns the on-device
  catalog file (`Application Support/Kilter/kilter.sqlite3` on iOS, `filesDir/kilter/…` on Android) +
  a `catalog.meta.json` sidecar (version / climb count / size). The existing `KilterCatalog` reader is
  **reused verbatim** — it just opens the store path instead of the bundle, degrades to
  `isAvailable == false` when nothing is installed, and gains a `reload()` (iOS, via a
  `didChangeNotification`) / `reset()` (Android) to re-open after an import/remove. `KilterCatalogProvider`
  is the **only** IO edge: `FileImportProvider` (iOS **Files** / Android **SAF**) is the shipped Phase-1
  path; `AuroraSyncProvider` is an **inert, documented Phase-2 stub** (conforms to the protocol, performs
  no network calls, the sync button is disabled). `KilterCatalogValidator` opens a candidate read-only,
  asserts the required tables exist, requires ≥1 listed climb, caps size, and derives a deterministic
  version — so a malformed/foreign file is rejected with a clear message instead of installing junk.
- **First-open shows an opt-in screen, not an empty list.** `KilterCatalogSyncView` (iOS) /
  `KilterCatalogSyncScreen` (Android) explain the import, **surface Aurora's Terms of Use + a link**
  before any fetch, and make clear the data stays on-device. `KilterSettingsView`/`Screen` gain catalog
  status (version • climbs • size) + **Refresh** + **Remove downloaded catalog** (removal keeps logged
  ascents + saved climbs).
- **The on-device-only rule gets one narrow, named carve-out** (`project.md:64` footnote): the Kilter
  catalog fetch is a **user-initiated** network request, because the data is third-party-owned and can't
  be redistributed by us. No background sync, no analytics, no Snappet backend; health + media still
  never leave the device. Kept narrow so it can't be cited to justify general networking elsewhere.
- **Tests use a synthetic fixture — zero Aurora data.** `tools/kilter/build_test_fixture.py` (run +
  verified locally against every reader query) and an in-code `KilterCatalogFixture` (Swift + Kotlin,
  same rows) author a tiny invented catalog (two layouts, a small hole grid, four made-up climbs). iOS
  installs it under a `-uiTestInstallKilterCatalog` launch arg; Android via a `TestHooks` flag in
  `MainActivity`. New `KilterCatalogStoreTests` / `KilterCatalogStoreTest` cover validate/install/clear +
  reader integration; the existing Kilter UI/walkthrough tests now install the fixture first (they used
  to rely on the bundled asset).

**Why**: Aurora's [Terms of Use](https://kilterboardapp.com/terms-of-use) claim their data + derivatives
as sole/exclusive property usable only with written consent; a trimmed rebundled copy is a derivative,
and this is actively-policed IP. Shipping code that *the user* points at their own catalog distributes
**code, not Aurora's database** — the only shippable-and-legal option short of a permission deal.

**Rules out**: bundling any Aurora data in the app (the asset is gone, not just unreferenced); a live /
background / always-on sync (fetch is user-initiated only); analytics or a Snappet backend; using the
carve-out to justify networking in other modules; changing the **user-data** model (`KilterLogEntry` /
`KilterSession` / `KilterFavorite` stay in SnappetCore/Room exactly as before); APK-extraction on device
(rejected — store-hostile/fragile). Phase 2 (`AuroraSyncProvider` real endpoints) stays blocked on the
endpoint/account/ToU open questions in #42 and is **not** implemented.

**Verified** (2026-06-06, macOS + Xcode 26.5 / Android SDK): both platforms compiled and run **green**.
iOS — full suite on the iPhone 17 Pro sim: **307 unit + 16 UI tests, 0 failures**, plus the
`HighlightEngine` SPM suite (21). Android — **37 unit + 18 instrumented tests, 0 failures** (Pixel 7
AVD). One first-pass fix was needed: the Kilter UI tests filtered out every synthetic climb because the
`@AppStorage` browse filters (angle/layout/grade) persist in UserDefaults and `-uiTestFreshStore` only
resets SwiftData — a leftover `kilter.angle` (the old bundled Aurora catalog had angle-0 climbs; the
fixture only has 25/30/40) yielded "No climbs match". Fix: `KilterCatalogFixture.installForUITestingIfRequested()`
now clears the Kilter filter keys so browse opens on the fixture-covered defaults. Bundle-inspection
acceptance confirmed on the built artifacts: **no `kilter.sqlite3` in the iOS `.app` or the Android
`.apk`** (the APK carries only `androidx.sqlite` library version-stamps, not data).

## [2026-06-04] Split Expenses — typed receipts (profiles + auto-detect classifier)

**Decision**: Let the user pick a **receipt type** before scanning/pasting (or leave it on **Auto**),
and have that type tune extraction. Implemented as **parse-time only** — no persisted column, no
`ReceiptSplit` change — so it stays additive and migration-free.

- **`ReceiptType`** { auto, grocery, warehouse, restaurant, gas, pharmacy, retail, generic } maps to a
  pure **`ReceiptProfile`** (extra skip-keywords, tip-line prefixes, a `fuelOnly` flag).
  `ReceiptParser.parse(text, profile:)` gains an optional profile that defaults to `.generic`, so the
  existing `parse(text)` behaviour and all current tests are unchanged.
- **Profiles**: restaurant adds SERVER/TABLE/GUEST… to the skip set and turns a `TIP`/`GRATUITY` line
  into a "Tip" line item (split among the diners); gas skips PUMP/GALLON/UNLEADED… and collapses to a
  single "Fuel" item from the detected total; pharmacy/retail add their own metadata skips;
  warehouse/grocery use the generic Costco-tuned base.
- **`ReceiptClassifier.classify(text)`** (pure) scores signature keywords per type for **Auto**; the
  picker then snaps to the detected type so the user sees the guess and can override.
- **UI**: a "Receipt type" picker in `NewReceiptSheet` (iOS `Picker`, Android dropdown). Scan/paste now
  hand raw text back to the sheet, which parses it with the resolved profile.

**Why**: a single generic parser mis-reads restaurant tips and gas pumps; a tiny per-type profile fixes
extraction without complicating the data model. Keeping type parse-time-only (vs. a persisted
`receiptType` column) honours the "bug-fixes + validation first, types as a thin follow-up" scope and
avoids a Room migration. **Rules out**: persisting the type this cut; a separate `tipAmount`/proportional
tip (tip is an equally-split line item for now — proportional tip is a follow-up); per-type split rules.
**Verified**: `ReceiptClassifierTests`/`Test` cover classification + the restaurant/gas/generic parse
branches off-device on both platforms. UI pickers stay device-unverified per the repo's build rule.

## [2026-06-04] Split Expenses — receipt parser fixes + total/discount validation

**Decision**: From a deep review of the receipt PR, fix two parser bugs and add an advisory
**validation** pass that reconciles the captured items against the receipt's printed totals.

- **Bug 1 — tax mis-detection.** `ReceiptParser` set `tax = value` on *every* line containing "TAX",
  so the **last** one won — on the real Costco receipt that's `FSA TAX = 1.64`, not `TOTAL TAX 14.01`.
  Fix: tax now comes from the authoritative `TOTAL TAX` line (a bare `TAX` line is a fallback), and
  per-rate `%` component lines and `FSA` lines are ignored; the grand-total scan also excludes `FSA`.
- **Bug 2 — leading-minus discounts dropped.** `money()` only handled a trailing minus (`4.00-`); a
  `-4.00` token failed the digit check and vanished. It now strips a leading **or** trailing `-`.
- **Parser now also reads** `subtotal` and `itemCount` ("Items Sold: 51", handled before the money
  guard since it's a bare integer) so validation has more to check against.
- **`ReceiptValidation`** (pure, both platforms, unit-tested): builds a `Report` of independent checks
  — items − discount + tax = total (the headline; `FAIL` on mismatch with the off-by amount),
  subtotal match, tax-vs-detected, item-count, unassigned remainder, negative share. Surfaced as a
  `ReceiptValidationBanner` (Balanced / Needs review / Doesn't add up) in `NewReceiptSheet` that
  expands to the checklist; it **never blocks saving**. The detected totals are held in sheet state
  from the last scan/paste — **not persisted** (no schema change this cut), so validation runs at
  capture time where it matters; persisting a stored mismatch flag is a follow-up.

**Why**: the split is only as trustworthy as the OCR, so the app should *show its work* and flag a
bad read instead of silently producing a wrong per-person total. Keeping validation pure makes the
reconciliation logic testable without a device. Scoped per the request to **bug-fixes + validation
first** (Warehouse/Grocery profile only); typed receipts (restaurant/gas/pharmacy auto-detect) remain
a planned follow-up — see `docs/wireframes/receipt-types-validation.svg`. **Rules out**: blocking save
on a mismatch (advisory only); a new persisted column this cut; trusting the last TAX line.
**Verified**: pure logic unit-tested off-device on both platforms (`ReceiptParserTests`/`Test`,
`ReceiptValidationTests`/`Test`). UI banners stay device-unverified per the repo's build rule.

## [2026-06-04] Split Expenses — Android receipt parity + on-device camera OCR (both platforms)

**Decision**: Mirror the iOS itemized-receipt feature to Android and add **on-device camera OCR** to
both platforms so a receipt can be captured by photo, not only pasted.

- **Android mirror (Kotlin/Compose, Room).** `ExpenseRecord` gains additive, defaulted columns
  `itemsRaw` / `taxAmount` / `discountAmount`; the DB version bumps 2→3 and rides the existing
  `fallbackToDestructiveMigration` (on-device-only data, no hand-written migration). Items persist as
  a control-character-delimited `itemsRaw` string (RS/US/GS) — the same "raw string, no TypeConverter"
  approach already used for `participantsRaw`. `ReceiptSplit.kt` and `ReceiptParser.kt` are 1:1 ports
  of the Swift logic (same largest-remainder reconciliation, same parser heuristics) and get JVM unit
  tests under `src/test` (`ReceiptSplitTest`, `ReceiptParserTest`, `SettleUpReceiptTest`). UI:
  `NewReceiptSheet.kt` (items + per-item assignee FilterChips + tax/discount + live `ReceiptSummary`),
  `ReceiptDetail.kt` (read-only breakdown), wired into `ExpenseRoot.GroupDetail` with a "New receipt"
  menu item and receipt rows that open the detail.
- **Camera OCR.** iOS: `ReceiptDocumentScanner` (VisionKit `VNDocumentCameraViewController`) +
  `ReceiptScanner` (Vision `VNRecognizeTextRequest`, **synchronous** so no `CGImage` Sendable-crossing,
  mirroring `MediaPicker`'s direct-callback coordinator); gated on `isSupported` (hidden on the
  simulator) and presented in a `fullScreenCover` whose binding drives dismissal. Android: `ReceiptScan.kt`
  captures via `ActivityResultContracts.TakePicture()` through a `FileProvider` temp file (so **no
  CAMERA permission** is needed) and recognizes with **ML Kit** `text-recognition` (one new dependency).
  On both platforms the recognized text flows straight into the already-tested `ReceiptParser` — the OCR
  layer stays a thin, untested platform edge; all the brittle "what's an item / tax / discount" logic is
  pure and unit-tested.

**Why**: keeping the algorithm identical and pure on both platforms means the hard part is tested once
per language and the camera/Vision/ML-Kit code is a trivial pixels→text adapter. Using ACTION_IMAGE_CAPTURE
+ FileProvider on Android avoids a runtime camera-permission flow; using a synchronous Vision call on iOS
sidesteps Swift 6 `Sendable` friction. **Rules out**: a Room TypeConverter / JSON dependency for items
(control-char string matches the repo); a hand-written Room migration (destructive fallback is the repo's
norm for on-device data); CameraX / a bundled cropping UI on Android; bridging ML Kit's `Task` with an
extra coroutines-play-services dep (used `suspendCancellableCoroutine` instead). **Verified**: pure
logic unit-tested off-device on both platforms (iOS XCTest, Android JVM `src/test`). All SwiftUI/Compose
surfaces and the camera/Vision/ML-Kit paths stay **device-unverified** per the repo's macOS+Xcode /
Android-SDK build rule (authored on Linux/cloud) — they need a `xcodebuild test` and a Gradle
`testDebugUnitTest` + on-device run to confirm.

## [2026-06-04] Split Expenses — itemized receipts with per-item assignment + proportional tax/discount

**Decision**: Add an itemized **receipt** path to Split Expenses so a real shopping receipt (e.g. a
51-line Costco run) can be entered once and split *per item* among different people — not just one
even split per expense (user report: "put this kind of receipt and help me split stuff for multiple
people … show total, tax, discounts and per-person split"). Implemented without a new `@Model`:
`ExpenseRecord` gains three additive, defaulted fields — `items: [ReceiptItem]`, `taxAmount`,
`discountAmount` — so the SwiftData migration stays lightweight and one record type still drives all
of even-split / settlement / receipt. A record is a receipt iff `items` is non-empty.

- **`ReceiptItem`** (a `Codable` value type persisted as a SwiftData composite attribute) carries a
  name, price, and the `assignees` who share that line equally.
- **`ReceiptSplit`** (pure, device-free, in the app target so it's `@testable`) computes the
  breakdown: each item is split among its assignees, tax is allocated proportional to each person's
  pre-tax subtotal, discount is credited the same way, and **every column is reconciled to whole cents
  with a largest-remainder pass** so the per-person totals sum *exactly* to the grand total. That exact
  closure is what lets `SettleUp.balances` treat a receipt as "payer credited the grand total, each
  sharer debited their slice" and still net the group to zero — no penny drift in the balances.
- **`ReceiptParser`** (also pure/tested) turns pasted or Live-Text receipt text into items + detected
  tax/discount/total: it strips leading item-codes and trailing tax-flag letters (`28.99 E`,
  `4.00-A`), routes trailing-minus rows to the discount, and skips SUBTOTAL/TAX/TOTAL/payment rows.
  This is the "put this kind of receipt" affordance — paste once, then just tap each line to choose who
  shares it (new items default to everyone).
- **UX**: `NewReceiptSheet` (entry, with a live `ReceiptSummaryView` showing subtotal/discount/tax/
  total + per-person split) and `ReceiptDetailView` (read-only breakdown + item list, Edit reopens the
  sheet). `ExpenseGroupView` gets an "Add Receipt" action; receipt rows show a doc glyph + item/tax/
  discount summary and tap through to the detail (even-split rows still tap-to-edit).

**Why**: receipts are inherently uneven (one person's beer, shared groceries) and carry tax + savings
that must follow the items, not be split flat. Keeping the math pure + penny-exact makes it unit-
testable (`ReceiptSplitTests`, `ReceiptParserTests`, `SettleUpReceiptTests`) and keeps the existing
balance/settle-up pipeline unchanged. Reusing `ExpenseRecord` (vs. a new `@Model`) keeps per-group
`#Predicate` fetches and the balance loop single-source. **Rules out**: a separate `Receipt` @Model +
relationship; storing precomputed per-person `shares` (derive from items so there's one source of
truth); splitting tax/discount evenly regardless of who bought what; on-device Vision OCR for v1 (the
paste/Live-Text text path is device-free and testable — camera OCR is a natural follow-up). **Verified**:
pure logic unit-tested off-device (`swift`-level XCTest); the SwiftUI sheets/detail stay
**device-unverified** per the repo's macOS/Xcode-only build rule (authored on Linux/cloud).

## [2026-06-04] Dynamic sessions + Kilter-driven climbing — direction set (design only, no code)

**Decision**: Captured a design review (`pdd/prompts/features/dynamic-sessions/DESIGN.md`) for two
user-requested capabilities, **design-only** for now (iOS code needs a Mac+Xcode to compile/verify per
the on-device rules below; this records the model + decomposition a Mac session implements):

- **Dynamic / freeform sessions.** Today every session is routine-locked — the only entry is
  `startWorkout(from: Routine)` → `makeSession(from:)` and `WorkoutPlayerView` walks a **frozen**
  `session.exercises` array (mutates set slots, never appends). But the *model is ~80 % ready*:
  `WorkoutSession.routineID` is already `UUID?` and `exercises`/`sets` are plain Codable arrays, so a
  routineless **Quick Start** + **add-exercise/add-set live** needs **zero schema change** — it's a
  player + entry-point job. Ship freeform **lifting first** (self-contained, no migration).
- **Polymorphic set unit (`SetKind`).** Dynamic gym climbing is **Shape ③ (graded attempts), not
  reps×weight**, so a "set" must be able to be a climb attempt. Chose: tag the *exercise* with
  `kindRaw: String?` (nil ⇒ legacy reps/weight) + **optional** `SetLog` fields (`durationSec`,
  `distanceM`, `climbGradeLabel`, `climbStatusRaw`, `climbAttempts`). **Critical migration nuance:**
  `SetLog`/`SessionExercise` are nested **Codable composites**, not `@Model`s — SwiftData lightweight
  migration does NOT cover fields inside an encoded blob, so a new **non-optional** key would make old
  blobs throw on decode. Hence every added field is `Optional`. **Rejected** a `SetMeasure`
  enum-with-associated-values (cleaner, but a bigger hand-written-Codable blob-migration surface).
- **Kilter → WorkoutTracker bridge.** The key enabling fact: `Routine`/`WorkoutSession` and
  `KilterLogEntry`/`KilterSession` are **all in the same `SnappetSchema.models` store**, so this is an
  in-process `@Query`, **not** a sync/network path (on-device rule #1 intact). Two features: **(B.1a)** a
  read-only adapter surfacing board sessions in the unified workout history (no new `@Model`, Kilter
  stays owner) — *why:* board climbs currently have no HR/reel pipeline; and **(B.2)** a pure
  `KilterRecommender` that turns the existing grade pyramid into a suggested climbing session
  (working-grade sends + project attempts + warm-ups), feeding the `.climbAttempt` exercises.

**Why**: closes the two real gaps the user hit — sessions can't grow at runtime, and the Kilter mini-app
is an island — while reusing the existing on-device store and the pure-logic-at-a-thin-edge pattern
(`SetKind` formatter/validator + `KilterRecommender` are unit-testable on the cloud box).

**Rules out / notes**: this **partly reverses** `decisions.md` 2026-06-02 ("keep Kilter separate") —
recorded as an explicit open fork (one-way read recommended, not a two-way merge). Defers: a unified
`WorkoutSession` projection of board climbs with HR/reels (B.1b, until B.1a proves out), full GPS/splits
cardio (Shape ②), and the enum-with-payloads measure. **Status: design only** — nothing built; knowledge
graph untouched until implementation (no node exists yet).

## [2026-06-04] Photos-level clip ops + HR overlay on set clips + a deep video-feature review

**Decision**: Two user-requested capabilities on the per-clip editor + a review pass.
- **Photos-library operations (every destructive one confirmed).** `MediaLibraryService` gains
  **`overwriteVideoAsset`** (replace the original in Photos with the edited render via
  `PHContentEditingOutput` — reversible in Photos; **remove-then-copy** onto `renderedContentURL`,
  since copying onto Photos' reserved path throws "file exists") and **`deleteAssets`**
  (`PHAssetChangeRequest.deleteAssets`); both read-write auth, PhotoKit non-Sendables boxed. The clip
  editor offers **Save a copy** (new asset) + **Overwrite original** (confirm). Session-detail Remove →
  a confirmation: **Remove from session only** vs **Delete from Photos too** (deletes the asset FIRST,
  then drops the tag only on success). Hosted on the stable `List`.
- **HR chart overlay on per-set clips.** `ClipEdit.hrOverlay` (optional) + `EditPlan` carries the HR
  samples **sliced/rebased to the clip's capture window** (`[offsetSec, +duration]` from the session's
  `hrSeries`). `VideoStudio` attaches the HR Core Animation layer on **export** (reuses
  `StudioOverlays.hrChartLayer`); the clip editor previews it as a live SwiftUI `StudioHRChartView`
  (drag/pinch). A **`forPlayback`** flag was added to `VideoStudio` (mirroring `StudioComposer`) so the
  preview composition omits the Core Animation tool — this also **fixed a latent crash**: text overlays
  attached the offline-only tool to the AVPlayerItem preview, which would have raised the same
  NSException the studio hit.
- **Deep review (two agents) → fixes**: guarded the clip-editor preview `setVideoComposition`
  (NSException); strictly-increasing HR-dot `keyTimes` (duplicate timestamps dropped the export
  animation); honored PiP opacity (removed an `==0?1` bug); the studio time observer only advances the
  playhead while playing (don't fight a scrub); delete-from-Photos ordered asset-first. **Known minor
  (not blind-fixed without device visual):** exported `CATextLayer` text sits slightly higher than the
  preview chip (top-origin glyphs). **Verified:** unit suite 206 (2 skipped), studio UI walkthrough
  green on the iPhone 17 sim. Photos overwrite/delete + HR-on-clip export are device-only (owed a device
  visual pass).

## [2026-06-04] Session detail → per-set tiles (media+HR unified) + HR-overlay pinch + Find-media polish

**Decision**: Follow-up UX from device feedback.
- **HR chart overlay is pinch-resizable** in the studio preview (`StudioHRChartView` `MagnifyGesture` →
  `setHRScale`, 0.3…1), matching the PiP resize; the HR tool's size slider still works.
- **Session detail unified to one tile per set.** `SessionDetailView` no longer renders set logs and
  the tagged-media gallery in separate places. `SessionMediaSection` now owns the per-exercise sections:
  each set is a `SetTileRow` (reps/weight + the **heart rate at the set's completion**, nearest
  `hrSeries` sample, zone-coloured) and its tagged photos/videos render as **rows beneath it** (multiple
  media → multiple rows). A **General** section holds unassigned media. The big B2 HR chart stays above.
- **Media removal is discoverable** (#3 — it was context-menu-only): each media row has **swipe-to-remove**
  (trailing) + **swipe-to-move** (leading) plus the existing long-press menu.
- **Find-media workflow** (#4) reviewed — the discovery logic was already sound (padded
  `[start−90s, end+90s]` window, dedupe, offset-align in `SessionMediaService`). Added a **Settings
  escape hatch** when Photos access is `denied`/`restricted`/`limited` (auto-discovery needs full
  access; limited can only PHPick), a found-count / explained-empty message that names the searched
  **time window**, and clearer limited-access copy.

**Rules out / notes**: per-set HR is the **nearest sample at set completion** (not an interval average) —
simple + meaningful. Walkthrough-critical ids preserved (`openStudio`/`generateHighlight`/`mediaThumb` +
a "Set N" label + a "General" header). `SessionMediaThumb` gained a `side` param (compact 54 pt in
rows). Verified: studio UI walkthrough green on the iPhone 17 sim; unit suite 206 (2 skipped), 0
failures. Device visual pass owed (thumbnails/discovery are device-only).

## [2026-06-04] Studio timeline zoom + PiP video overlay + HR-chart overlay

**Decision**: Three follow-on studio features (separate commits).
- **Zoomable timeline** — `StudioTimelineView.pps` is now a computed `zoomPps · pinchScale`, clamped
  12…200 pt/s, driven by a `MagnifyGesture` (simultaneous with the scrub drag) + `−/+` buttons
  (`timelineZoomOut/In`). Everything (offset, strip widths, ruler) reads `pps`, so the whole timeline
  zooms together.

- **PiP video-over-video** — `OverlayItem.Kind.video` (content = a session clip's `localIdentifier`).
  The composer adds a **second video track** per PiP, aspect-filled into a frame
  (`ClipEditGeometry.pipRect` + `fillTransform`, Y flipped to the composition's bottom-left origin),
  oriented, and **time-gated** via opacity (0 outside `[startSec, endSec]`). PiP forces the
  **instruction path** (renders in preview AND export, unlike the export-only text/sticker tool) — so
  with a PiP present, per-clip filters are dropped (degradation; transitions+PiP also deferred). The
  WYSIWYG canvas renders a draggable + **pinchable** frame outline (the real PiP shows through from the
  player); position/scale/delete of a `.video` overlay **rebuild** (it's in the composition), unlike
  text/sticker. Add via the **PiP** action-bar button → pick a session clip.

- **Heart-rate chart overlay** (moving-playhead line) — the session's `hrSeries` (fetched by the
  project's `sessionID` FK in the VM) maps across the **whole video**; a dot tracks the video's 0…1
  progress. `HROverlayConfig` (optional on `StudioProject` → migration-safe) carries position/scale/
  colour/showBPM/zoneColored. **Pure `HRChartGeometry`** (normalized points, time→bpm sampling) feeds
  BOTH renderers, so they match: **preview** = a live SwiftUI chart (`StudioHRChartView` — line + dot +
  live BPM, draggable), **export** = Core Animation in `StudioOverlays.hrLayer` (the polyline + a dot
  animated along it via a `CAKeyframeAnimation` keyed to the timeline, bottom-left origin). HR overlay
  config is threaded through `makeComposition`/`export`/`makeAnimationTool` (`hrSamples` + `hrConfig`);
  it's not in the playback composition, so edits don't rebuild the player. Customization via the **HR**
  action-bar tool (enable · colour · size · live-BPM · zone-colour); position by dragging the chart.

**Rules out / caveats**: the **live BPM number is preview-only** (Core Animation can't keyframe a
`CATextLayer`'s string) — export shows the line + moving dot (+ zone/colour). PiP+filter and PiP+
transition still degrade (one custom `AVVideoCompositing` is the eventual unifier). **Device-pending
visual**: PiP placement (Y-flip), the HR dot sync, and the export Core Animation chart need the user's
device pass (the sim renders the SwiftUI preview chart but not the AV export). Unit suite **206
(2 skipped), 0 failures**; studio UI walkthrough green on the iPhone 17 sim.

## [2026-06-04] Studio editor → edits/CapCut layout (multi-phase redesign)

**Decision**: Rebuild the multi-clip editor UI to the edits/CapCut layout the user referenced, in
phases (separate commits, sim-UI-tested each). **Phase 1 (done)**: a custom **top bar** (X · editable
title · export-quality menu · Export), a preview with a **controls-free `AVPlayerLayer`**
(`StudioPlayerLayerView`, `.resizeAspect` so its displayed rect matches `ClipEditGeometry.displayRect`
for overlay alignment) + a **custom transport** (play/pause + live `MM:SS / MM:SS` timecode driven by a
periodic `AVPlayer` time observer in the VM, Swift-6-safe via `MainActor.assumeIsolated`), and a
**contextual bottom action bar** (Split · Speed · Filter · Transition · Text · Canvas · Delete) whose
value-pickers open a focused **bottom sheet** (`StudioToolSheet`). Split is now **playhead-driven**
(`splitAtPlayhead` cuts the clip under `currentTime`). Export quality is a pure
`StudioExportQuality` (preset-name string, no AVFoundation import) passed to `composer.export`, which
falls back to HighestQuality if the preset is unsupported.

**Why**: the prior vertical stack (preview / cards / controls list) couldn't reach edits-parity by
accretion; the transport + action-bar + tool-sheet shell is the foundation the timeline/adjust/audio
phases build on. NavigationStack chrome dropped for a custom dark top bar.

**Phase 2 (done)** — `StudioTimelineView`: a **scrubbable** timeline (clip strips laid by output
duration, a **fixed centre playhead**, a time ruler) where dragging seeks the preview + moves the
playhead, and during playback the strip auto-advances (it's offset by `vm.currentTime`). Tap a strip to
select; the selected video clip gets **drag-trim handles** (leading→`trimStart`, trailing→`trimEnd`),
committed **once on drag-end** (live handle feedback is view-local → one undo entry + one rebuild).
Clip strips are coloured placeholders — **thumbnail strips are a device-only follow-up**. The strip
layout uses `StudioGeometry.timeline` placement (so a transition overlap shows clips overlapping; rare).

**Rules out / notes**: the time observer is removed+reattached on each `rebuildPreview` (no leak); the
end-of-play notification resets the playhead. At `t=0` the first clip strip starts at the centre
playhead (so its centre is off-screen) — the studio UI walkthrough therefore asserts the action bar
(reliable) and treats per-clip timeline selection as best-effort; a dedicated `StudioEditorUITests`
covers selection/trim.

**Phase 3 (done)** — **Adjust (colour)** + export quality. `ClipAdjust` (brightness/contrast/
saturation) is an **optional** on `TimelineClip` (nil = neutral → migration-safe Codable add); the
composer's CIFilter path applies it via `StudioFilters.applyAdjust` (`CIColorControls`) after any
filter, and is now entered when a clip has a filter **or** a non-neutral adjust. Unlike overlays,
adjust+filter **do** render in the live preview (CIFilter compositions are AVPlayerItem-legal). The
Adjust tool sheet's sliders commit **on release** (`onEditingChanged`) → one rebuild per drag. Export
quality (`StudioExportQuality`) was wired in Phase 1.

**Phase 4 (done)** — **audio + overlay keyframes**. Per-clip **volume/mute** (`TimelineClip.volume`,
optional → migration-safe) applied via an `AVAudioMix` the composer now returns alongside the
composition + videoComposition (a triple; `rebuildPreview` sets `item.audioMix`, `export` sets
`session.audioMix`). **Add music**: a `.fileImporter` (`.audio`) copies the pick into Documents →
`AudioTrack(.music)`; the composer inserts it on its own audio track at `startSec` and volume-mixes it
(missing file skipped → export-safe). **Overlay opacity keyframes**: an opacity slider + a marker
button (`addOverlayKeyframeAtPlayhead`) capture opacity at the playhead into `OverlayItem.opacityKeyframes`
(the export `StudioOverlays` already animates them). Contextual **overlay controls bar** (opacity ·
keyframe · delete) replaces the clip action bar when an overlay is selected.

**Rules out / follow-ups**: per-clip volume + **transition** path (transition audio is a plain stitch,
no mix); music **fades**/trim UI; keyframed overlay **position/scale**; thumbnail timeline strips.
**Honest caveat**: the audio mix (volume + music) and the music **file import** are device-only — the
sim has no real clip audio and the import needs Files; the on-device export-success + the *sound* are
owed by the user's device pass (per the repo rule). Verified Phases 1–4 on the iPhone 17 sim: studio UI
walkthrough green; unit suite 199 (2 skipped), 0 failures.

## [2026-06-04] Studio WYSIWYG overlay positioning — draggable SwiftUI layer over the preview (edits/CapCut pattern)

**Decision**: Make text/sticker overlays **positionable by dragging them on the preview canvas**
(user ask: "how to make sure / correct the location of the text overlay", with an edits/CapCut
reference). Crucially, overlays are **NOT** rendered into the live preview video — the Core Animation
overlay tool is export-only (the crash entry below) — so the editing surface is a **SwiftUI layer on
top of the player** (`StudioOverlayCanvas`), exactly the edits/CapCut model where the chip is live UI
and the pixels are burned in only at export.

**Why it's correct (WYSIWYG by construction)**: `OverlayItem.position` is normalized `0…1`, top-left.
**Export** maps it via `ClipEditGeometry.layerPoint` (→ CALayer, y-flipped); the **preview chip** maps
the *same* normalized value into the **displayed video rect** (`ClipEditGeometry.displayRect` — the
aspect-fit area inside the player, NOT the whole player frame) via the new `previewPoint` /
`normalizedPoint` (inverse, clamped). Both read one normalized value ⇒ what you drag is what exports, at
any resolution. Chip sizes mirror `StudioOverlays` (font = canvasH·0.05·scale, sticker = canvasH·0.12·
scale). Because it's pure SwiftUI, **overlay positioning works on the simulator** (no device/Photos).

**Shape**: pure `ClipEditGeometry.displayRect/previewPoint/normalizedPoint` + pure
`StudioProjectEditor.setOverlayPosition` (clamped) — both unit-tested (6 new cases). VM gains
`overlays`/`selectedOverlay`/`selectOverlay`/`setOverlayPosition`/`deleteOverlay` and an
**`editOverlaysOnly`** path that commits+persists but **skips the player rebuild** (overlays aren't in
the playback composition, so dragging mustn't restart playback). `addText` now selects the new overlay.
Drag commits once (on end) via a `@GestureState` offset; selected chip shows a dashed ring + a Delete
affordance.

**Rules out / follow-ups**: overlay **resize/rotate** handles, **time-window** editing UI (still
`[0,3]s` default), keyframed **position animation**, and exact `.original`-aspect fidelity (the editing
rect falls back to 9:16 for `.original` since the VM doesn't track source size yet). Unit suite **195
(2 skipped on sim), 0 failures**; device build + install green. **Visual confirm owed** (drag accuracy +
the overlay landing in the exported file) — per the repo rule, tests prove the math/shape, not the look.

## [2026-06-04] Studio multi-clip editor crashed on open — Core Animation tool is export-only (device-found)

**Symptom**: opening the multi-clip Studio **aborted the app** on the device (SIGABRT). Pulled the crash
report off MrRobot (`idevicecrashreport`; the `.ips` doesn't carry the NSException *reason*, but the
backtrace did): `objc_exception_throw` → `-[AVPlayerItem setVideoComposition:]` →
`StudioEditorViewModel.rebuildPreview()`. The on-device reason (captured by guarding the call, below):
> *AVVideoCompositions using `AVVideoCompositionCoreAnimationTool` cannot be used with AVPlayerItem.
> `AVVideoCompositionCoreAnimationTool` is for offline rendering only.*

**Root cause**: `StudioComposer.makeComposition` attached the overlay `animationTool` to the **one**
videoComposition reused for **both** export and the live `AVPlayer` **preview**. The tool is legal for
export (`AVAssetExportSession`) but `AVPlayerItem` **rejects** it — and it rejects by raising an
**Objective-C `NSException`, which a Swift `do/catch` cannot catch**, so the `rebuildPreview` try/catch
didn't save it → process abort. The S0–S4 spike never caught this because it only ever drove the
**export** path (`AVAssetExportSession`), never `AVPlayerItem` — preview on a real device was never
exercised (the editor was sim-only + the cover-presentation fix).

**Fix** (two parts):
- **`forPlayback` flag** through `StudioComposer.makeComposition` / `assemble` / `assembleSingleTrack` /
  `assembleWithTransitions`: when **true** the videoComposition **omits** the Core Animation tool.
  `rebuildPreview` requests `forPlayback: true`; **export keeps `false`** (overlays still burn into the
  file). Net: filters/transitions/transforms now preview live; **overlays don't show in the live
  preview** (they do in export) — live overlay preview is a SwiftUI-overlay-layer follow-up (the
  edits/CapCut WYSIWYG pattern), NOT `AVSynchronizedLayer` inside the composition.
- **`Services/ObjCException`** (tiny ObjC `@try/@catch` + `Snappet-Bridging-Header.h`, wired via
  `SWIFT_OBJC_BRIDGING_HEADER` on the app target): lets Swift catch AVFoundation `NSException`s.
  `rebuildPreview` wraps `item.videoComposition = vc` in it — so an AVFoundation throw can **never**
  abort the studio again; it degrades to an on-canvas message + an `os.Logger` line. **Keep this** — AV
  raises ObjC exceptions in many places.

**Rules out / notes**: don't reuse one videoComposition for both `AVPlayerItem` and export when it uses
an `animationTool`. Verified on MrRobot: new `testPlaybackCompositionOmitsCoreAnimationToolAndExportKeepsIt`
(playback omits the tool + `AVPlayerItem` accepts it; export keeps it) + the 7-path export spike both
green; full unit suite **189 (2 skipped on sim), 0 failures**. **Honest caveat (unchanged)**: the device
test proves no-crash + a valid composition, NOT that the preview *looks* right — that's the user's visual
pass.

## [2026-06-04] Studio effects batch — sticker/keyframed overlays, slide/zoom, filter+overlay; filter+transition deferred

**Decision**: Filled out the studio effects (all device-export-verified via the spike, 7 paths):
- **Sticker overlays** (tinted SF-Symbol CALayer) + **keyframed overlay opacity** (drives the visibility
  animation from `opacityKeyframes` when present) — `StudioOverlays`.
- **Slide / zoom transitions** — on the two-track path, ramp **track B's transform** over the overlap
  (slide = full-width translate; zoom = scale about the canvas centre) instead of (or with) the dissolve
  opacity ramp. B is always on top, so it animates in when incoming / out when outgoing.
- **Filter + overlay** — attach the overlay animation tool to the CIFilter-handler path too.

**Deliberately CUT (quality call): filter + transition combined.** It needs a custom
`AVVideoCompositing` (the CIFilter handler composites tracks itself, so it can't cross-dissolve two
tracks). I built one but it hit Swift 6 `AVVideoCompositing` Sendability friction AND can't be visually
verified by a headless device test — shipping a blind, concurrency-fighting compositor is the wrong
trade. **Removed it; the case degrades gracefully** (the dispatch falls through to the filter path →
filters render, the transition is dropped). The unified compositor is the documented follow-up.

**Rules out / follow-ups**: filter+transition (custom compositor), animated overlay **position** (only
opacity keyframes today), Ken-Burns photos, audio cross-fade. **Honest caveat (unchanged)**: the spike
proves each path produces valid, renderable video — NOT that slides/zooms/stickers/keyframes *look*
right; that needs a visual pass (editor preview / exported file). Full unit suite 188 green (1 skipped).

## [2026-06-04] S4 studio text overlays — Core Animation overlay tool (device-verified export)

**Decision**: Added **time-gated text overlays**. `StudioOverlays` builds a Core Animation layer tree
(a `CATextLayer` per `OverlayItem` — positioned via `ClipEditGeometry.layerPoint`, scaled/rotated/
coloured, opacity-keyframed to appear only within `[startSec, endSec]`) composited via
`AVVideoCompositionCoreAnimationTool` — the proven `VideoStudio.attachOverlays` pattern, generalized to
`OverlayItem`. `StudioComposer` attaches it on the **instruction-based paths** (no-filter single-track /
two-track transition); the editor's "Add text overlay" action now renders end-to-end.

**Rules out / follow-ups**: **sticker** overlays (need image layers), **keyframed/animated** opacity &
position, and **overlay-with-filter** (the CIFilter handler composites tracks itself, so the animation
tool isn't wired on that path) — all deferred. The composer's three feature paths are unchanged; overlays
ride the two instruction paths.

**Verified on the iPhone 13 Pro Max** (the spike asserts it): a 16 s / 4-clip export **with a text
overlay** succeeds in ~4.9 s (the Core Animation tool costs more than a CIFilter, still well under
realtime). **Honest caveat**: export-success proves the composition is valid + renders — NOT that the
text's position/size/timing *look* right; that needs the editor preview / exported file. Full unit suite
188 green (1 skipped on the sim).

## [2026-06-04] Present sheets/covers with `item:`, not `isPresented:` + separate state (device gotcha)

**Decision**: The Studio cover opened as a **black empty screen on the device** (but worked on the
simulator). Cause: `.fullScreenCover(isPresented: $openingStudio)` whose content read a **separate**
`@State studioProject` — if SwiftUI evaluates the cover content before that assignment propagates,
`if let project = studioProject` is nil → an empty (black) cover. Simulator timing hid it; the device
exposed it. **Fix + rule**: when a presentation's content depends on a value, present **item-based**
(`.fullScreenCover(item: $studioProject) { project in … }` / `.sheet(item:)`), so the cover presents only
once the item is non-nil and the closure receives it — never an empty cover. Don't pair `isPresented:` with
a separate "the thing to show" `@State`. (Found by on-device testing; confirmed fixed on the device.)

## [2026-06-04] S3 studio transitions — dissolve via a two-track opacity ramp (device-verified export)

**Decision**: Added **dissolve transitions** between clips. Architecture: when any transition is set
(and no clip has a filter — the CIFilter handler composites tracks itself, so it can't combine), clips
**alternate between two video tracks** (A = even, B = odd) placed with the `StudioGeometry.timeline`
overlaps; **track B is composited on top and its opacity is ramped** over each overlap — fading B IN when
it's the incoming clip, OUT when it's outgoing — so the always-opaque track A underneath is revealed /
covered to cross-dissolve. Chosen because a single-track composition can't show two clips at once, and
this **track-B-ramp-only** scheme avoids per-segment instruction juggling and a custom compositor. Gaps on
each track are padded with `insertEmptyTimeRange`. The S1 editor's transition picker already drives it.

**Rules out / follow-ups**: slide/zoom transitions (transform ramps), combining a transition WITH a filter
(needs the unified Core Image compositor), and audio cross-fade during the overlap — all deferred.

**Verified on the iPhone 13 Pro Max** (the spike asserts it): a 16 s / 4-clip / 3-dissolve export succeeds
in ~2.8 s. **Honest caveat**: export-success proves the two-track composition is valid and renders — it
does NOT verify the crossfade *looks* right (no automated visual check); that needs the editor preview /
exported file. Full unit suite 188 green (1 skipped on the sim). The composer now has three feature paths
(single-track transform · CIFilter handler · two-track dissolve), split into `assembleSingleTrack` /
`assembleWithTransitions` for clean `sending` ownership.

## [2026-06-04] S2 studio filters — Core Image colour filters, device-verified

**Decision**: Built the first S2 effect — per-clip **colour filters** (mono / noir / fade / vivid / warm /
cool) — on the device-proven export path (S0). Architecture:
- **`StudioFilters`** (pure Core Image, unit-tested on the sim): `StudioFilter` + intensity → a configured
  `CIFilter`, with `apply()` + `aspectFill()` helpers. Warm/cool use a simple `CIColorMatrix` channel
  shift (avoids `CITemperatureAndTint`'s dual-neutral subtlety); vivid uses `CIColorControls`; mono/noir/
  fade are `CIPhotoEffect*`.
- **`StudioComposer`** routes any clip-with-a-filter through `AVMutableVideoComposition(asset:
  applyingCIFiltersWithHandler:)` — AVFoundation hands each frame to the handler as a `CIImage`, we
  aspect-fill to the canvas and apply the active clip's filter (looked up by the request's composition
  time). No-filter clips keep the layer-instruction transform/crop path. **Chose the CIFilter-handler API
  over a custom `AVVideoCompositing`** — far less coordinate/pixel-buffer risk for the same result.
- The S1 editor's filter picker now renders end-to-end (preview + export) with no UI change.

**Why it matters / rules out**: this is the template for the rest of S2+ (transitions, keyframed overlays
ride the same compositor). **Known follow-up**: the filter path currently aspect-fills (it supersedes the
per-clip *crop* transform) — combining precise crop WITH a filter is deferred.

**Verified on the iPhone 13 Pro Max** (the S0/S2 spike, now asserting it): a 16 s / 4-clip **filtered
(vivid)** export succeeds in ~3.0 s vs ~2.6 s transform-only — Core Image per-frame adds ~15 %, still
~0.2x realtime. Full unit suite **188 green** (4 new `StudioFiltersTests` incl. a warm-vs-cool channel
check; 1 skipped on the sim).

## [2026-06-04] S0 studio-export spike — **GO** (videoComposition export fixed; root cause = empty audio track)

**Decision / finding**: Ran the S0 device-profiling spike (`StudioComposerProfilingTests`, on the iPhone
13 Pro Max via free-Personal-Team signing) to gate the S2+ compositor. Verdict **CONDITIONAL GO**, full
write-up in [`live-workout-studio/RESULTS-S0.md`](../prompts/features/live-workout-studio/RESULTS-S0.md):
- **Capacity is ample** — a 16 s / 4-clip / 1080×1920 multi-clip **stitch** (passthrough) remuxes in
  **~0.1 s** on-device. Export time/memory is a non-issue at this scale (the design's worry is moot).
- **The export *mechanism* is the blocker** — applying our hand-built `AVMutableVideoComposition` (the
  transform/crop / future-effects path) fails `AVFoundationError -11838` ("operation not supported",
  underlying `OSStatus -16976`) on-device for **every** transcode preset (HighestQuality / HEVC /
  1920x1080). Passthrough-without-videoComposition is the only path that exports.
- The spike also **caught + fixed a real composition bug**: `StudioComposer.assemble` emitted one layer
  instruction per clip on the same single track (malformed) → now one layer instruction with per-clip
  `setTransform(at:)`. Also refactored `makeComposition` to expose an AVAsset-based `assemble(resolved:)`
  seam (decoupled from Photos) so the export is testable on-device without a Photos library.

**Why it matters**: the same `AVMutableVideoComposition()` + manual-instruction pattern ships in
`VideoStudio` (the B3 clip editor), which was **never device-tested** — so clip-editor *export* is almost
certainly broken on real hardware too. This is exactly the device-gated risk S0 exists to surface before
sinking effort into S2+.

**Rules out / next**: do **not** start S2 (filters/transitions/keyframes) until the videoComposition
export works on-device — they all ride the failing transcode path. Next task: fix the export (try
`AVMutableVideoComposition(propertiesOf:)` as the base; else a custom `AVVideoCompositing` +
`AVAssetReader`/`Writer` pipeline), apply the same fix to `VideoStudio`, and flip the S0 spike from
`skip` to a timing assertion.

**RESOLVED same day — verdict is GO.** The -11838 root cause was **an empty audio track**, not the
`AVMutableVideoComposition` per se: `StudioComposer.assemble` added an audio track up front, and a source
with **no audio** (the synthetic test clip, and any audio-less real video) left it 0-duration, which the
on-device videoComposition export rejects (passthrough tolerates it). Ruled the rest out one device run
each (preset, pixel format, color tags, bare-vs-propertiesOf init, 1-vs-4 clips). **Fix**: create the
audio track **lazily** (only when a clip has audio); also kept the one-layer-instruction-per-track fix and
switched to `videoComposition(withPropertiesOf:)`. **Transform export now works on-device at ~0.2x
realtime** (a 4 s clip ~0.76 s). **Correction**: `VideoStudio` (clip editor) **already** adds audio
lazily, so it was never broken — only `StudioComposer`. **Verified**: the S0 spike now PASSES on-device
(asserts both the stitch and the transform/videoComposition export); full unit suite 184 green (1 skipped,
on the sim). **S2+ (filters/transitions/keyframes) is unblocked** — no export-mechanism blocker remains.

## [2026-06-03] Full studio S1 shipped — multi-clip StudioProject + editor (sim-verified)

**Decision**: Built Track S **S1** (the full CapCut-style studio's foundation) as verifiable layers,
deliberately keeping the pixel pipeline honest:
- **Pure, unit-tested core** (no device): `StudioProject` `@Model` (multi-clip timeline — TimelineClips
  with trim/speed/crop/filter/Ken-Burns keyframes, transitions, overlays, audio tracks, canvas
  aspect/background); `StudioGeometry` (timeline placement with transition overlaps, clip durations,
  keyframe interpolation); `StudioProjectEditor` (snapshot edit ops) + a generic `UndoStack`. **31 unit
  tests** (16 geometry + 15 editor/undo) — the two that initially failed caught a real reorder bug
  (reindex was re-sorting by the stale `order`).
- **Device-only render** (`StudioComposer`, build-verified only): generalizes `VideoStudio` to a
  multi-clip composition (sequential trim+speed clips, per-clip orientation+crop on a shared canvas),
  reused for preview + export.
- **Editor UI** (`StudioEditorView` + VM): timeline (select/reorder/split/delete), per-clip
  speed/filter/transition, aspect, text, undo/redo, Export → Share; opened from `SessionDetailView` over
  the session's `StudioProject` (seeded from its video clips). Preview/export show a device-only
  placeholder on the sim.

**Why**: a multi-clip editor can't grow out of the single-clip `ClipEdit` by accretion — it needs a
timeline document + a generalized composer. Making the edit model a value snapshot kept undo/redo and
every edit op **pure and testable without a device**.

**Verified**: iPhone 17 sim — the studio walkthrough opens the editor, renders the two seeded clips in
the timeline, splits one, and undoes it (11c/11d frames); full unit + UI suites green. The UI test caught
a real presentation bug (a `.fullScreenCover` on a Group-of-Sections inside a List never presents — moved
it onto the launching Button).

**Deferred (S2+, device-only, gated by the S0 profiling spike — NOT built)**: the custom
`AVVideoCompositing` that actually *renders* filters/LUTs, transitions, keyframed overlay effects,
captions, and masks; Ken-Burns photos; the audio mix. The `StudioProject` model already carries all of
this intent — only the compositor pass is pending. **Rules out** writing that compositor blind: it can't
be sim-verified, and device verification is itself blocked on Xcode signing setup (no Apple ID / profiles
yet — `feat/live-workout-per-set-media` builds for the sim but a device install needs the team account
added in Xcode).

## [2026-06-03] Per-set media + full CapCut studio — direction set (design only, no code yet)

**Decision**: Extend the live-workout-studio initiative with two user-requested capabilities, captured
as a design review in [`pdd/prompts/features/live-workout-studio/DESIGN-full-studio.md`](../prompts/features/live-workout-studio/DESIGN-full-studio.md)
(decomposed into a Track M + Track S prompt chain). Three forks were resolved by the user (2026-06-03):

- **"Side" = each set**, with reassignment + a non-set **General** bucket. Media gets *set-scoped* on top
  of session-scoped: additive `assignedExerciseID` / `assignedSetIndex` / `assignmentSourceRaw` on
  `SessionMedia` (lightweight migration; existing rows fall into General). A set is referenced by
  `(SessionExercise.id, setIndex)` — **not** a new `SetLog.id` — because `SetLog` is a positional Codable
  value and a `Codable` default-UUID id mints fresh ids on each decode of old data until re-saved (a
  silent-break migration hazard). Auto-assignment is a **pure, unit-tested** function
  (`SessionMediaAssignment`, the `SessionHighlightInput`/`ClipEditGeometry` edge pattern): a clip is
  assigned to the set whose `(prevCompletion, thisCompletion]` interval contains its offset; a rest-period
  clip belongs to the set just completed. A `manual`/`general` provenance flag makes user choices sticky
  against re-runs.
- **Full CapCut parity** for the editor. The current single-`ClipEdit` editor **cannot** reach parity by
  accretion; it's superseded by a `StudioProject` timeline document (multi-clip main track + overlay/audio
  tracks + transitions + keyframes), a custom `StudioCompositor: AVVideoCompositing` (Core Image/Metal) for
  filters/LUTs/transitions/masks, and an incremental-recomposition preview for smoothness. `B3`'s
  single-clip behavior survives as the one-clip-project case. **GO, fully on-device** (AVFoundation + Core
  Image + Vision + Speech), no backend — the only real risk is multi-clip+effects export/preview perf,
  gated by an **S0 device profiling spike** before committing compositor depth.
- **Capture = library auto-discover + PHPicker** (no in-app `AVCaptureSession` camera this round) — so the
  set is *inferred* from capture time, which is exactly why M1 is a pure assignment algorithm with
  manual-override.

**Why**: closes the two real gaps the user hit — media is session-scoped (no per-set link) and the editor
is single-clip — while reusing the proven non-destructive / pure-math-at-the-edge pipeline and keeping
`HighlightEngine` untouched.

**Rules out**: per-rep/per-exercise granularity (chose per-set); a `SetLog.id` FK this round; in-app camera
capture this round; growing `ClipEdit` into a multi-clip model (a new `StudioProject` instead); any
cloud/off-device render (unchanged hard constraint).

**Implemented same day (Track M — per-set media)**: shipped `SessionMediaAssignment` (pure, Foundation-only)
+ additive `SessionMedia` assignment fields; rebuilt `SessionDetailView`'s gallery into per-set groups +
a General bucket with a per-clip **Move to…** reassignment menu (sticky `manual`/`general`, reconciled on
appear / after discovery); extended `StudioDemoSeed` with spaced per-set completions + 4 synthetic clips
(3 sets + General) for the walkthrough. **Verified on the iPhone 17 sim**: full unit suite green incl. the
new `SessionMediaAssignmentTests` (7 cases), **all 16 UI cases across 12 classes green** (incl. the studio
walkthrough, which now captures the grouped gallery + the reassignment menu), `HighlightEngine` unchanged.
A screenshot walkthrough video was produced (`docs/walkthroughs/per-set-media-studio-walkthrough.mp4`).

**Still design-only / unproven (Track S — full CapCut studio)**: the `StudioProject` timeline, custom
`StudioCompositor`, filters/transitions/keyframes/captions are **not** built — they're device-only and
gated by the S0 profiling spike (can't be honestly sim-verified, so deliberately not faked in the
walkthrough). That is the next executable step.

## [2026-06-03] BLE band connection — auto-detect already-connected bands + remember the last one

**Decision**: Make Bluetooth heart-rate-band connection automatic instead of a manual "open the picker,
scan, tap the band every time" flow (user report: "it does not auto-detect a Bluetooth-connected fitness
band; I had to manually do it"). Three changes, all routed through the existing `MetricsSource`/coordinator
seam so the player / Live Activity / overlay are untouched:

- **Auto-detect the already-connected band.** `BLEHeartRateMetricsSource` now calls
  `central.retrieveConnectedPeripherals(withServices: [0x180D])` on power-on / picker-open, not just
  `scanForPeripherals`. A band paired in iOS Settings (Polar/Wahoo/Garmin) is *connected but not
  advertising*, so a plain scan never saw it — this is the root cause of "wasn't auto-detected". Those
  bands now appear instantly, flagged `isSystemConnected`, and merge with scanned advertisers
  (de-duplicated by identifier).
- **Remember the last-used band.** New `BandMemory` (UserDefaults, on-device) persists the chosen
  band's `CBPeripheral.identifier` + name. On the next launch the coordinator's init calls
  `autoConnectIfRemembered()` — which *only* spins up the central when a band is already remembered (so
  the Bluetooth permission was already granted and we never prompt at launch for a first-time user) — and
  reconnects it silently; the radio scan stops on connect to save battery. The source-selection default
  (`resolve`) now treats a *remembered* band as a known band, so a returning band-only user lands on BLE
  with zero taps.
- **Honest, actionable picker UI.** The picker shows a "Saved · reconnects automatically" tag, lists
  system-connected bands, supports swipe-to-Forget, and — when Bluetooth is off / unauthorized
  (`BluetoothAvailability`) — shows a message + a Settings jump instead of an endless "Scanning…" spinner.

**Why**: the manual re-pick was the single biggest friction in the live-workout flow; the fix is pure
CoreBluetooth ergonomics (retrieve-connected + a remembered identifier) with no new transport, no cloud,
and no new HealthKit path.

**Rules out**: a vendor cloud API (Fitbit/Google still ruled out, 2026-06-01); creating the central at
launch for *all* users (would prompt for Bluetooth before any value is shown — gated on a remembered band
instead); a SwiftData store for the band (a single identifier is a UserDefaults-sized fact).

**Verified**: extended the pure XCTest suite (`BLEBandAutoDetectTests`) — merge/dedup, the remembered-row
synthesis, the auto-connect rule (remembered → single system-connected → nil), and a `BandMemory`
persist/forget round-trip over an isolated suite. **Now also verified on device (2026-06-03, iPhone 13
Pro Max + a Google Fitbit Air, which — unlike most Fitbits — exposes the standard `0x180D`/`0x2A37` HR
profile):** auto-detect with no manual scan, auto-connect + real live HR stream, cold-launch "Saved ·
reconnects automatically" zero-tap reconnect, and the Bluetooth-off empty state all confirmed.

**Follow-up fix (2026-06-03) — "Forget" must stick for a band iOS keeps connected on its own.** Device
testing surfaced a real bug: a band that stays connected to iOS at the system level (a Fitbit, kept alive
by its own app) was immediately re-grabbed by the "single system-connected band → just use it" rule right
after the user swiped **Forget**, and re-remembered on connect — so Forget never stuck. Fix: `BandMemory`
persists a **suppressed** band id; `forget` sets it (clearing remembered), `bandToAutoConnect` and the
remembered-band auto-path **exclude** it, and an explicit tap (`connect`) clears it (re-opt-in). Covered by
new `BLEBandAutoDetectTests` cases (suppressed lone band → nil; a different system band still auto-connects;
suppression survives relaunch; allow clears it) and re-verified on device.

## [2026-06-02] Kilter Board mini-app — bundled read-only catalog, not a runtime sync

**Decision**: Added a **Kilter Board** mini-app (iOS + Android) for browsing the Kilter climb catalog,
rendering a climb's holds, logging sends/projects, reviewing history, and — gated, Phase 2 — lighting
the physical board over BLE. Traces to [#32](https://github.com/harshal2802/snappet-mobile/issues/32).

**Concrete choices made:**
- **The catalog is bundled static reference data, never synced.** The Kilter database is fetched +
  trimmed at *dev time* by `tools/kilter/build_bundled_db.py` (wrapping `boardlib`) into a small
  `kilter.sqlite3` shipped as an app asset (`ios/App/Snappet/Resources/`, `android/.../assets/`), opened
  **read-only**. This keeps Snappet's on-device-only rule (#1) intact: no runtime network/sync/accounts.
  Refresh = re-run the tool, drop in the new asset, ship an app update. **Rules out** an in-app live sync.
- **Catalog stays out of SwiftData/Room.** It's read with raw SQLite (`import SQLite3` on iOS; a
  read-only `SQLiteDatabase` copied out of `assets/` on Android), so the persistence stores own *only*
  user data. User data = three models/entities (`KilterLogEntry`, `KilterSession`, `KilterFavorite`)
  added to `SnappetSchema.models` / `SnappetDatabase` (Room version bumped 1→2; destructive-migration).
- **Bundled subset, not the full ~100k climbs.** Default trim: the 800 most-climbed listed problems on
  Kilter Original + Homewall + all board geometry (~4.9 MB). Committed in *both* platform asset dirs
  (≈9.8 MB total). Open question #11.1 (full-vs-trim, possibly Git LFS) deferred to a product call;
  #11.2 (redistribution license) **must** be resolved before shipping.
- **BLE illumination is implemented but device-unverified.** The Aurora/Kilter wire format
  (`KilterProtocol`, framed ≤20-byte packets) and GATT UUIDs come from community reverse-engineering and
  are **not** confirmed on hardware — gated behind an explicit Connect tap, inert in Phase 1, and not to
  be reported as working until validated on a real board (device-only rule #6). Sessions auto-open on
  connect to group logged ascents in History.

## [2026-06-01] Live-workout studio next pass — rich watch UI, pause/resume, background/minimize, transitions, notification status

**Decision**: One coherent change set across the live-workout surfaces (the features are tightly
coupled through the `Shared/` wire types, so a single change rather than parallel branches):

- **Bidirectional pause/resume.** `LiveWorkoutMessage` gains `.pause`/`.resume` (either device can
  initiate; the receiver applies it *without echoing* to avoid ping-pong). `MetricsSource` gains
  `pause()`/`resume()` (default no-op so a stream-only BLE band needn't implement them); the
  Apple-Watch source pauses the on-wrist `HKWorkoutSession`, the coordinator tracks `isPaused`
  (reading the watch source for the watch path, a local flag for BLE). The watch manager treats a
  `.paused` `HKWorkoutSession` state as still-running (only ended/stopped clears the face).
- **Rich watch UI.** `WatchWorkoutView` becomes a two-page vertical-paging face: a zone-colored HR +
  elapsed + energy + avg-HR **Metrics** page and a Pause/Resume + End **Controls** page.
- **Background / navigate-back.** The player gets a **Minimize** control (`onMinimize`) that drops the
  full-screen cover **without** ending the session; the session stays `isActive`, the watch keeps
  recording, and a new `LiveWorkoutBanner` pinned to the WorkoutTracker home shows live metrics +
  zooms back into the player. No SwiftData schema change (reuses `isActive`).
- **Notification status.** The Live Activity (Lock Screen + Dynamic Island) is the persistent
  notification-area status; it now renders a **Paused** badge (freezing the timer) + zone-colored HR.
  A new `WorkoutNotifications` service **schedules** a "rest complete" local notification when rest
  *starts* (a foreground `Task.sleep` is suspended in the background), cancelled on skip/pause/finish.
- **Transitions.** A central `Motion`/`AnyTransition` vocabulary (`Features/Shell/Transitions.swift`):
  iOS 18 `.zoom` for App Library card→module and banner→player, a section-swap for the workout
  segmented control, a cross-fade-and-slide for the player's exercise↔rest↔done phases, and a
  bottom slide for the banner.
- **`HeartRateZone` moved to `Shared/`** so the phone overlay, watch face, and Live Activity render
  the same bpm→zone color/label from one source of truth (no logic change).

**Why**: pause + background-continue + a way back in are the table-stakes gaps for a real workout
session; routing all of it through the existing `Shared/` wire types + the `MetricsSource`/coordinator
seam keeps the watch/phone/widget from drifting and adds no new HealthKit path.

**Rules out**: a SwiftData pause-interval ledger (the displayed timer freezes via a captured value;
"total" stays wall-clock and is documented); per-feature parallel branches (they'd conflict on the
shared wire/UI files); a bespoke push-notification stack (local `UNUserNotifications` only, on-device).

**Verified**: extended the pure XCTest suites — `LiveWorkoutTests` (pause/resume message round-trip,
source + coordinator pause state), `LiveActivityTests` (paused snapshot push + `ContentState`),
`WorkoutNotificationsTests` (rest-complete copy). **Build/sim run is device-pending**: this change was
authored in a Linux environment with no Xcode toolchain, so it has **not** been compiled or run on a
simulator — `xcodebuild test` on the iOS 18 sim + a paired-watch device pass is owed at the merge gate.

## [2026-06-01] Knowledge graph extended for the Live Workout Studio initiative — per-node screenshots + embedded walkthrough video

**Decision**: Updated the interactive knowledge graph (`docs/knowledge-graph/`, branch
`feat/graph-studio-update`) to cover the just-merged **Live Workout Capture + Video Studio** initiative
(A1–B5), and added two new presentation affordances to the detail panel.

**Concrete choices made:**
- **`data.js` nodes (16 added, 1 retired, several updated)**. Added the pluggable live-metrics layer
  (`metricssource`, `livemetricscoordinator`, `applewatchsource`, `blesource`) and the studio services
  (`sessionmediaservice`, `videostudio`, `medialibraryservice`); the shared Live Activity contract node
  `workoutactivityattributes`; the new `@Model`s `model-sessionmedia` + `model-clipedit`; the new sheets
  `wt-hr-source-picker`, `wt-clip-editor`, `wt-highlight`; the OS-framework nodes `ext-corebluetooth` +
  `ext-watchconnectivity`; and an **overview node `live-workout-studio`** (type `section`) that carries the
  walkthrough video and `contains`/`feeds` the key new nodes so it's discoverable. **Retired** the stale
  `liveworkoutservice` node (the file `LiveWorkoutService.swift` was renamed in A3 to
  `LiveMetricsCoordinator.swift` + `AppleWatchMetricsSource.swift`) — its edges re-pointed to
  `livemetricscoordinator`. **Updated** `sharesheet` (B5 generalized it → `Features/Shell/ShareSheet.swift`),
  `wt-player`/`wt-session-detail`/`wt-settings` descs (A4 overlay / B2 summary / A3 picker entry), and
  `model-workout` (B2 `hrSeries`). Wired the full live + studio edge flows with the existing edge types
  (`uses`/`streams`/`persists`/`feeds`/`present`/`contains`). The link-id integrity check passes (every edge
  source/target is a defined node id; no orphans, no duplicate node ids) — 109 nodes total.
- **Per-node screenshots**. Added an optional `shot` field; `renderDetail(n)` injects an `<img class="shot">`
  under the head (safe when absent), styled in `styles.css` (full panel width, rounded, bordered, `max-height`
  + `object-fit: contain` so tall phone shots fit). Curated 17 shots: the 9 existing suite screens
  (`01-home`…`09-budget`) + 8 NEW live-workout frames copied from `/tmp/studio-walkthrough-frames/` into
  `docs/screenshots/` with semantic names (`workout-dashboard`, `workout-routines`, `routine-detail`,
  `live-player`, `workout-history`, `workout-summary`, `workout-settings`, `hr-source-picker`). The
  **ClipEditor / SessionHighlight** screens are **device-only** (no simulator video) → their `shot` is left
  unset; their detail still shows desc + connections.
- **Embedded walkthrough video**. Added an optional `video` field rendered as a `<video class="shot-video"
  controls preload="metadata">` in `renderDetail`, attached to the `live-workout-studio` overview node
  (`docs/live-workout-studio-walkthrough.mp4`). Added a "▶ Walkthrough video" affordance in `index.html`'s
  header (an `<a class="btn">` to the relative path, offline-friendly). The root `README.md` gained a
  **"Walkthrough video"** subsection (HTML5 `<video>` off the GitHub **raw** URL + a relative-link fallback)
  and the 8 new live-workout screens in the Screens grid; the graph `README.md` "How it was built" note now
  cites the initiative + the `shot`/`video` additions.
- **Stays static/offline**: no build step. **Verified**: braces balanced in `data.js` (310/310); the
  `renderDetail` template-literal injection follows the existing `${cond ? \`…\` : ""}` pattern; every
  `shot`/`video` path resolves to an existing file (17 PNGs + the mp4); link-id integrity + no-duplicate-id
  checks pass. (`node --check` could not be run in this sandbox — Node execution is blocked — so syntax was
  confirmed structurally: balanced delimiters, the exact existing node/edge object shape, and a grep-based
  source/target-vs-node-id audit.) Only the renamed PNG copies are committed; the `/tmp` frames are not.

## [2026-06-01] Live Workout Studio walkthrough — chronological screenshot UI test + a test-only HR demo seed

**Decision**: Added a demo/QA asset (branch `feat/live-workout-walkthrough-video`, prompt
`pdd/prompts/features/live-workout-studio/WALKTHROUGH.md`) that walks the whole Live Workout Studio
initiative (A1–B5) in story order and captures ordered screenshots for a video walkthrough. The headline
screen — the **B2 enriched summary (HR chart + avg/max/min + time-in-zone)** — only renders when a session
has a non-empty `hrSeries`, which the simulator never produces (no live HR source). So a **test-only demo
seed** plants the data that makes it render.

**Concrete, non-obvious choices made:**
- **`StudioDemoSeed` lives behind a new launch arg `-uiTestSeedStudioDemo`** (`Features/WorkoutTracker/
  StudioDemoSeed.swift`), a **sibling of `-uiTestFreshStore`** that it **implies** — `SnappetApp.init()`
  builds the in-memory container for it (determinism) and calls `seedIfRequested(into:)` once, before any
  UI appears. The guard returns immediately without the arg → **ZERO production impact** (a normal launch
  hits neither arg). The ONLY app-target edit is that one `init()` branch; everything else is test code +
  the seed type in the feature folder. Idempotent (keyed on a fixed `routineID`).
- **The seed is DATA ONLY (no Photos)**: it inserts one **completed** `WorkoutSession` (three logged
  exercises with completed sets) carrying a **deterministic synthetic `hrSeries`** — a warm-up ramp → five
  sine-driven work/recovery oscillations → cool-down, ~120–175 bpm over ~30 min, one `HRPoint` every 3 s,
  **no randomness** so the chart/stats are pixel-identical every run. This is enough for the B2 HR section
  (chart + avg 146 / max 172 / min 120 + a Z2–Z5 time-in-zone bar) to RENDER on the sim. Tagged media /
  clip editor / highlight reel still need real video and stay device-only (the seed doesn't fake them).
- **Walkthrough navigation reuses the suite's UI-testable conventions** (segmented-control + Button rows;
  `WorkoutWalkthroughTests` pattern: `snap("NN-name")` via `XCTAttachment(screenshot:)`, `.keepAlways`).
  The **History → session-detail** row is the suite's one value-based `NavigationLink` (decisions.md
  2026-05-31) — XCUITest CAN activate it here (the prior limitation was a plain `Button` not firing, not
  the NavigationLink), so the test opens the *seeded* session through it with identifier/label/first-row
  fallbacks, asserting the B2 `hrChart` / "Heart rate" section then snaps it.
- **The A3 HR-source-picker entry is a `.buttonStyle(.plain)` row**: a plain `.tap()` on its identifier
  didn't always present the sheet, so `openHRSourcePicker()` retries via the row label then a
  normalized-coordinate tap — robust, never flakes. Confirmed the sheet (Apple Watch row + "Scanning for
  bands…") then renders.
- **The frames are throwaway** (exported to `/tmp/studio-walkthrough-frames/frame-NNN.png` via
  `xcresulttool export attachments` + the manifest's `suggestedHumanReadableName`) and are **NOT committed**
  — only the test + seed + this note + the WALKTHROUGH prompt are.

**Verified (this environment, Xcode/SDK 26.5, iPhone 17 Pro iOS 26.4 sim)**: `xcodegen generate`; the
`Snappet` scheme TEST BUILD SUCCEEDED (app + watch + widgets + both test targets).
`LiveWorkoutStudioWalkthroughTests` → **PASS** (1/1), capturing 12 ordered frames — suite home, app library,
workout dashboard, routines, routine detail (Start bar), the player (A2 overall-timer header + A4
no-source overlay), after-finish dashboard, History (the just-finished session + the seeded Studio Demo),
the **B2 HR summary** (chart + 146/172/120 + zone bar), the B1 media section + disabled B4 "Generate
highlight", Settings, and the A3 HR-source picker sheet. All PNGs uniform **1206 × 2622** (single sim) →
stitchable. The existing **`WorkoutWalkthroughTests` stays green** (62 s, 1/1). `HighlightEngine` source
untouched (no platform import added).
**Rendered vs skipped**: every planned step rendered EXCEPT `07-rest-screen` — the driven starter routine
reached **Finish** without the player surfacing a rest-countdown screen in the snapshot window (rest is the
prompt's optional "if reached" step), so it's gracefully absent rather than a fake. Device-only surfaces
(a real bpm in the overlay, media thumbnails, the clip editor, an actual reel) show their honest simulator
state (no-source / empty / disabled), not staged data — the same honesty bar as A1–B5.

## [2026-06-01] B5 — share + save generated videos to Photos (the video-studio finale)

**Decision.** Implemented prompt B5 (`pdd/prompts/features/live-workout-studio/B5-share-and-save.md`,
branch `feat/live-workout-share-save`). Every generated/edited video — the **B3 edited clip** and the
**B4 highlight reel** — can now be **shared** (system share sheet) or **saved to the Photos library**, all
on-device (the user's "all the videos generated could be sharable or downloadable to local/Photos",
RESEARCH §3.6). This is reuse + wiring on top of B3/B4; **no engine change** (`git diff ios/HighlightEngine`
empty, grep-clean of platform imports).

**Concrete, non-obvious choices made:**
- **`Services/MediaLibraryService.swift`** (stateless `Sendable`): `saveVideoToPhotos(_ url:) async throws`
  requests **add-only** authorization (`PHPhotoLibrary.requestAuthorization(for: .addOnly)`) — the
  **narrowest** grant that lets the app write a new asset without read access to the whole library, and
  deliberately **distinct** from the **read-write** `PhotoLibraryService` uses for B1 discovery. The save is
  the async `PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.forAsset().addResource(with:
  .video, fileURL: url, options: nil) }` overload — **no continuation needed** (the async API already bridges
  the callback, unlike B1's `PHImageManager`/A1's WCSession callbacks). Typed `SaveError: LocalizedError`
  (`.denied` routes the user to Settings; `.failed(msg)` wraps a change-block failure). `.limited` is treated
  as savable (add-only `.limited` can still add).
- **Generalized `ShareSheet`** — moved out of `Features/Reel/ReelView.swift` (where it was top-level but
  conceptually private to the reel app) into **`Features/Shell/ShareSheet.swift`**, so the flagship reel app
  AND the WorkoutTracker studio (B3 editor + B4 reel) share **one** `UIActivityViewController` wrapper. No
  second bridge written (the spec's "don't duplicate" constraint). The flagship's call site is unchanged
  (same type name, same target).
- **Pure `ExportShareState`** (`Features/WorkoutTracker/ExportShareState.swift`): an `Equatable` value-type
  state machine (`idle → exporting → exported(URL) → saving(URL) → saved(URL)`, plus `failed(String)`) with a
  reducer, so the transitions, the **carried export URL**, and the `isBusy`/`exportedURL` accessors are
  **unit-tested in `SnappetTests` with no AVFoundation/PhotoKit/UIKit** (9 cases) — the device-only
  export/save/share I/O is not, but the state logic that drives both producers' UI is (the same "isolate the
  pure logic" discipline as `ClipEditGeometry`/`WorkoutHRStats`). The rendered file `URL` is carried through
  `.exported`/`.saving`/`.saved` so **share + save reuse the single render** (export once, then share and/or
  save that same file). `beginningSave()`/`saveSucceeded()` are guarded to no-op without a prior export.
- **Two thin wire-ins, I/O through the services:**
  - **B3 clip editor** — `ClipEditorViewModel.export()` snapshots the `@Model` into `EditPlan` on the
    `@MainActor` and calls `VideoStudio.export` (the same composition the preview already uses); `saveToPhotos()`
    calls `MediaLibraryService`. A new "Export" `ControlCard` in `ClipEditorView`: Export → Share + Save to
    Photos with progress + a `saved` checkmark. **A subsequent edit invalidates the export** — `commit()`
    resets `exportState` to `.idle` (unless busy) since the prior render no longer matches the edit.
  - **B4 highlight** — `SessionHighlightViewModel` now **keeps `lastPlan`** from `generate()` (the VM already
    built a `ReelPlan` to preview) so `export()` re-renders the **same** reel via `ReelExporter.export`
    (no reel-stitch reimplementation); `saveToPhotos()` calls `MediaLibraryService`. A new Export/Share/Save
    section in `SessionHighlightView`, gated on `canExport` (plan present + state `.ready`); re-generating
    resets the export.
- **Privacy.** `NSPhotoLibraryAddUsageDescription` is present in the app Info.plist (it predates B5, from the
  first working version) and **accurate** ("Snappet saves your finished highlight reel back to your library")
  — confirmed, not re-added. `PrivacyInfo.xcprivacy` stays accurate: saving to the user's **own** library is
  on-device, so **no** `NSPrivacyCollectedDataTypes` entry is added (Apple's "collected" = transmitted off
  device; nothing leaves). The existing manifest comment already covers "written back to the user's own
  library entirely ON-DEVICE".
- **No new `@Model`** → `SnappetSchema.models` unchanged.

**Verified (this environment, Xcode/SDK 26.5).** `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**. `SnappetWatch`
(watchOS 26.5 sim, Apple Watch Series 11) → **BUILD SUCCEEDED**. `SnappetTests` → **122/122 pass** (incl. the
9 new `ExportShareStateTests`: full idle→saved flow, URL carried through every post-export state, save
guarded without an export, `isBusy` gates, failure + re-export recovery, re-export supersedes a prior file).
`HighlightEngine` → **18/18**, source unchanged (`git diff ios/HighlightEngine` empty, grep-clean of platform
imports). `SnappetUITests/WorkoutWalkthroughTests` → **green** (the sim session has no media/video, so
"Generate highlight" stays disabled and no clip opens the editor — the share/save affordances never render in
the walkthrough, and the summary flow is unbroken).
**Device-pending (NOT verified by this build/tests).** The actual **Photos save** (the add-only auth prompt +
`performChanges` writing a `.video` asset into the user's library) and the **share-sheet round-trip** need a
**real rendered video on a device**: the sim has no Photos/video, so `VideoStudio`/`ReelExporter` resolve no
`AVAsset` and produce nothing to save — so neither producer reaches `.exported` in the sim. A clean build +
the pure state-machine tests prove the **service shape + the wiring + the state logic + Info.plist**, NOT a
verified Photos save or share (same honesty bar as A1–B4).

## [2026-06-01] B4 — engine-driven highlight generation (the WorkoutTracker ↔ HighlightEngine bridge)

**Decision.** Connect the set-logger to the flagship algorithm by feeding a finished session's data
into the **EXISTING** `HighlightEngine`, with no engine change. A new **pure** bridge —
`Features/WorkoutTracker/SessionHighlightInput.swift` (an `enum` of static mappers + a plain-value
`Clip` struct; **no SwiftData/AVFoundation/Photos**) — maps a `WorkoutSession` to an engine `Workout`:

- **HR**: `hrSeries` (`HRPoint`) → `[HRSample]`, **1:1** on the same `startedAt`-relative timeline (`t`/`bpm`).
- **Media**: each tagged `SessionMedia` → `MediaItem` (`id = localIdentifier`, `startOffset = offsetSec`
  clamped ≥ 0). A **video** → `.video` with `durationSec`; a video with no resolvable duration falls back
  to a small `defaultVideoDuration` (6 s) and, when even that is unavailable, is **skipped gracefully**
  (a windowless clip the engine can't use). A **photo** → `.photo` with duration `0` (Ken-Burns still,
  already handled by `ReelExporter`/`PhotoClipRenderer`).
- **Activity**: routine `SportTag` (stronger) → then the dominant `ExerciseCategory` → the engine's coarse
  `Activity`, defaulting to `.strength` (generic gym). Targets the engine's `Activity` (not
  `HKWorkoutActivityType`) so the engine stays platform-free — this is the **engine-Activity twin** of
  the live path's `WorkoutActivityMapping` (which maps *up* to HealthKit types).

**Generation + render (reuse, not reimplement).** `SessionHighlightViewModel` (`@MainActor @Observable`)
snapshots the `@Model`s into plain `[HRPoint]`/`[Clip]` on the `@MainActor`, runs the **existing**
`app.engine.selector.select(workout:config: .preset(for:))` → `[Highlight]`, then `app.reelPlan(…pinnedIds:)`
→ `ReelPlan`, then **reuses `ReelExporter.makeComposition`** to build an `AVPlayer` preview (the same
composition export uses — no reel-stitch reimplementation). The non-Sendable `@Model` never crosses into
the engine/exporter.

**Selected clips → `pinnedIds` (budget-exempt).** The user's selected **clip** ids become the planner's
pins (the 2026-05-30 pin decision). Because `ReelPlanner` pins by **highlight** id, the view model expands
each selected clip id into the highlight ids whose `mediaItemId` is that clip — so a hand-picked clip is
always kept, budget-exempt. The **pure bridge** (`pinnedIds(forSelected:)`) emits the selected clip ids
verbatim (the unit-tested contract); the clip→highlight expansion is app composition state in the VM.

**UI.** A **"Generate highlight"** button in `SessionDetailView`'s media section, **enabled only when the
session has a tagged video**, opens `SessionHighlightView` — a **sheet** owning its own `NavigationStack`
(modules must not nest one) with a clip-selection list (default = all videos), a **Generate** action, and
an inline `VideoPlayer` preview. B5 adds share/save.

**B3 `ClipEdit`s are NOT applied to the reel segments (deferred).** B4 generates from the **raw** tagged
clips; per-segment edit integration (applying a clip's trim/crop/overlays to its reel slot) is a B5/later
concern — it would require threading per-segment `EditPlan`s through a composition the engine-driven
`ReelExporter` doesn't currently take, and the gate "after B3" (export cost) is unmeasured. Recorded here
so it isn't mistaken for an oversight.

**No new `@Model`** (the inputs already exist: B2 `hrSeries`, B1 `SessionMedia`) → `SnappetSchema.models`
unchanged. `git diff ios/HighlightEngine` is empty — the engine is reused verbatim.

**Verified vs device-pending.** Verified: app + watch schemes build (iPhone 17 Pro / Apple Watch Series 11
sims, `-destination` only); `SnappetTests` green incl. the new `SessionHighlightInputTests` (HR 1:1, media
kind/offset/duration incl. default-when-nil + skip-when-windowless + photos, activity mapping, selection →
`pinnedIds`, and an end-to-end bridge→selector→planner pin-survival check); `HighlightEngine` 18/18 with an
**empty** `ios/HighlightEngine` diff; `WorkoutWalkthroughTests` green (the sim session has no media/HR, so
"Generate highlight" is disabled — it can't run, doesn't crash the summary). **Device-pending**: the actual
**rendered highlight reel** — the sim has no Photos/video, so `ReelExporter` has nothing real to stitch. A
clean build is **not** a verified rendered reel.

## [2026-06-01] B3 — non-destructive CapCut-style on-device clip editor (WorkoutTracker)

**Post-review fix (2026-06-01, same branch)**: review found the time-gated text overlay used a
`CABasicAnimation(opacity)` with `fillMode: .forwards`, which holds the overlay **visible after its
`endSec`** instead of hiding it. Replaced with a `CAKeyframeAnimation` over the whole clip
(`values [0,0,1,1,0,0]` at `keyTimes [0, s, s, e, e, 1]`, `beginTime = AVCoreAnimationBeginTimeAtZero`)
so a text overlay is visible **only** within `[startSec, endSec]` and disappears after. (Whole-clip text —
the common case — is unaffected: it skips the animation and stays at full opacity.) Review otherwise
confirmed the geometry is sound: the CALayer **Y-flip** is correct (`layerPoint`), the crop transform
order `preferred.concatenating(crop)` applies orientation then crop correctly, the `EditPlan` Sendable
snapshot is the right Swift-6 boundary, and the PHAsset→AVAsset continuation single-resumes
(`.highQualityFormat`). Re-verified: app + watch BUILD SUCCEEDED, SnappetTests 97/97, HighlightEngine
18/18, WorkoutWalkthroughTests green. The overlay-timing fix is device-pending visually (no video on the
sim) — the keyframe approach is the standard `AVVideoCompositionCoreAnimationTool` pattern.

**Decision**: Implemented prompt B3 (`pdd/prompts/features/live-workout-studio/B3-clip-editor.md`,
branch `feat/live-workout-clip-editor`). A tagged **video** in a session's `SessionDetailView` B1 gallery now
opens a **non-destructive, fully on-device clip editor** — the user's "individually adjust the split/crop,
text overlay and all the basic CapCut/edit features" (RESEARCH.md §3.5). Edit state is **data, not baked
pixels**; nothing renders until export, so editing is instant + reversible. Builds on the existing
`ReelExporter` AVFoundation stitch.

**Concrete, non-obvious choices made:**
- **Non-destructive `@Model ClipEdit`** (`Features/WorkoutTracker/ClipEdit.swift`), keyed to its source
  `SessionMedia` by `sessionMediaID: UUID` (a **foreign key**, NOT a `@Relationship` — the suite convention,
  matching `SessionMedia.sessionID`), with the PHAsset `localIdentifier` **denormalized** so `VideoStudio`
  resolves the source without a second fetch. Holds the edit list: `trimStart`/`trimEnd` (split = two
  `ClipEdit`s with adjacent trims + `splitOrder`); a normalized crop rect (`cropX/Y/Width/Height`) + an
  `OutputAspect` (9:16 / 1:1 / 16:9 / original); `speed` (0.25–4×); `textOverlays: [TextOverlay]` (an inline
  `Codable` composite — `string`, normalized-center `CGPoint`, `fontSize`, `colorHex`, `startSec`/`endSec` —
  like `WorkoutSession.exercises`/`hrSeries`, **not** a child `@Model`); `mutedOriginalAudio` + optional
  `musicTrackName`. **One central edit**: `ClipEdit.self` appended to the single `SnappetSchema.models` line
  (additive → SwiftData lightweight migration, same precedent as B1's `SessionMedia`).
- **All geometry/timing math isolated into `ClipEditGeometry`** (`Features/WorkoutTracker/`,
  Foundation+CoreGraphics only — value types, **no AVFoundation/SwiftUI**), so trim→`TimeWindow`
  (clamp to `[0, assetDuration]`, force `start<end`, collapse a degenerate/inverted range to a tiny min
  slice), speed→scaled output duration (`sourceDuration / clampedSpeed`), normalized crop-rect→
  `CGAffineTransform` (aspect-fill the cropped region into `renderSize`, sanitized so a degenerate rect can't
  NaN), normalized position→`CALayer` point (**y-flipped** to CALayer's bottom-left origin), output
  `renderSize` per aspect (canvas longer edge = source longer edge, rounded to **even** dims — H.264
  requires even W/H), and split→two **adjacent, non-overlapping** windows (`a.end == b.start`, both ≥
  minDuration) are **unit-tested in `SnappetTests` with no device/AVFoundation** (23 cases) — the same
  testability discipline that keeps `HighlightEngine` platform-free (grep-confirmed: the engine gained no
  platform import, `git diff` shows its source unchanged). The `renderSize` per aspect is the
  **mixed-orientation normalization** — a portrait + a landscape source both render into one canvas — which
  **closes the gap deferred since 2026-05-31** (Photo-Ken-Burns / video-only reels never unified orientation).
- **`VideoStudio` service** (`Services/VideoStudio.swift`, stateless `Sendable`): one
  `makeComposition(for: EditPlan) async throws -> sending (AVMutableComposition, AVVideoComposition?)` reused
  for **both** preview (wrap in `AVPlayer`) and export — mirroring how `ReelExporter` shares one composition
  (P3). Trim → a source `CMTimeRange`; speed → `scaleTimeRange` on the inserted video (and audio) range;
  crop/aspect/orientation → `AVMutableVideoComposition.renderSize` + a single
  `AVMutableVideoCompositionLayerInstruction.setTransform` that **concatenates the track's
  `preferredTransform` (orientation) with the crop transform**; text overlays → a `CALayer` tree
  (`CATextLayer`s, time-gated by an opacity `CABasicAnimation`) composited via
  `AVVideoCompositionCoreAnimationTool`. **Reuses `ReelExporter`'s PHAsset→`AVAsset` resolve + the
  `Box<T>: @unchecked Sendable` + async `export(to:as:)` patterns** rather than duplicating them
  (`isNetworkAccessAllowed = false` — on-device).
- **Swift-6 actor crossing**: a `ClipEdit` is a `@MainActor`-confined, non-Sendable SwiftData `@Model`, so it
  must NOT cross into `VideoStudio`'s nonisolated build path. Resolved by snapshotting it into a `Sendable`
  value `EditPlan` (a plain struct, `@MainActor init(_ ClipEdit)`) **on the caller's actor** — the same
  "engine/service takes a plain value, not the model" discipline as `ReelExporter` taking a `ReelPlan`. The
  freshly-built composition crosses back with `sending`.
- **Editor UI** (`ClipEditorView.swift`) is a **sheet** (`.sheet(item: $editingClip)` from
  `SessionDetailView`) so it owns its own `NavigationStack` — **NOT** nested in the module (which rides the
  App Library's stack). Inline `VideoPlayer` over the live composition + control cards: trim sliders +
  Split, an `OutputAspect` segmented picker + a centered zoom-crop slider, a speed slider + 0.5/1/2× presets,
  a text-overlay list (add/edit/remove via a sub-sheet editing string/size/position/color), and a mute
  toggle. **All logic in `ClipEditorViewModel`** (`@MainActor @Observable`): owns the `ClipEdit`, rebuilds
  the `AVPlayer` preview off `VideoStudio` after every edit (with a `buildToken` so a newer edit supersedes
  an in-flight build), and persists; the view is thin (conventions.md). **Split** inserts a sibling
  `ClipEdit` (second half) via an `insert` closure and keeps the first half on the current edit.
  Only **videos** open the editor (photos aren't clip-editable); the editor reuses/creates the primary
  (lowest-`splitOrder`) `ClipEdit` for that source.

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**. `SnappetWatch`
(watchOS 26.5 sim) → **BUILD SUCCEEDED**. `SnappetTests` → **97/97 pass** (74 prior + 23 new
`ClipEditGeometry`: trim clamp/order/inverted/zero-asset, speed double/half/clamp, split adjacency +
exhaustiveness + too-short→nil, renderSize per aspect + even-dims + degenerate-source, full-frame &
center crop transforms + degenerate→finite, sanitized crop rect, y-flipped layer point + clamping).
`HighlightEngine` → **18/18**, source unchanged (grep-clean). `WorkoutWalkthroughTests` → **green** (the sim
has no Photos/video, so no clip opens the editor in the walkthrough — the gallery/summary flow is unbroken).
**Device-pending (NOT verified by this build/tests)**: the actual **rendered output** — the cropped,
text-overlaid, speed-ramped video, the live `AVPlayer` preview, and the mixed-orientation `renderSize`
normalizing a real portrait+landscape pair — needs **real video assets on a device** (the simulator has no
Photos/video, so `VideoStudio` resolves no `AVAsset` and the editor shows its no-source preview state). A
clean build + the pure-math unit tests prove the **model + composition-building + the geometry + the editor
UI shape**, NOT a verified rendered export (same honesty bar as A1–B2). **Export time + memory profiling**
of a multi-clip + overlay export is a device gate (PLAN "after B3").

## [2026-06-01] B2 — enriched post-workout summary (HR chart + band stats + media gallery) (WorkoutTracker)

**Decision**: Implemented prompt B2 (`pdd/prompts/features/live-workout-studio/B2-enriched-summary.md`,
branch `feat/live-workout-summary`). A finished WorkoutTracker session's `SessionDetailView` now shows,
above the B1 tagged-media gallery, a **live HR chart** + **band stats** (avg/max/min HR + time-in-zone),
so a completed workout presents the user's "detailed fitness band data along with tagged videos"
(RESEARCH.md §3.4). Consumes A1's live HR buffer + B1's gallery.

**Concrete, non-obvious choices made:**
- **Persist the HR series as an ADDITIVE Codable composite, not a new `@Model`** (`WorkoutModels.swift`):
  added `var hrSeries: [HRPoint] = []` to `WorkoutSession`, where `HRPoint { t: Double; bpm: Double }` is a
  small `Codable`/`Hashable`/`Sendable` value type stored inline like `exercises`. A default-`[]` additive
  property triggers SwiftData's **lightweight migration** with **`SnappetSchema.models` UNCHANGED** —
  exactly the **Journal `tags: [String] = []` precedent** (decisions.md 2026-05-31). No versioned schema
  plan, no migration stage. The HR bytes are tiny (1 Hz, `t`+`bpm` doubles) so an inline composite (always
  loaded with the session, like its sets) is right — no FK-keyed child rows needed here, unlike B1's
  `SessionMedia` (which references on-device Photos assets that must NOT enter the store).
- **Flush point: `finishWorkout(_:saved:)`, on a saved finish, BEFORE `stop()`** (`WorkoutTrackerModule.swift`):
  `session.hrSeries = WorkoutHRStats.points(from: app.liveWorkout.samples)` runs before
  `app.liveWorkout.stop()` (which stops both sources). The coordinator's `samples` are engine `HRSample`s
  **already rebased onto the `WorkoutSession.startedAt` timeline** by A1, so the flush is a straight
  field-for-field map (`HRSample.t/bpm → HRPoint.t/bpm`), isolated in `WorkoutHRStats.points(from:)` so
  it's unit-tested. Empty buffer (no live source — the sim, or a phone-only workout) → empty `hrSeries` →
  the summary's HR section hides cleanly. A **discard** keeps no series (the session is deleted).
- **Pure stats helper `WorkoutHRStats`** (`Features/WorkoutTracker/WorkoutHRStats.swift`): a value type
  with `make(from: [HRPoint], maxHR:) -> WorkoutHRStats?` computing avg/max/min + per-zone dwell seconds,
  plus the `HRSample → HRPoint` map. It lives in the app (not `HighlightEngine`) because time-in-zone
  reuses the app's `HeartRateZone` (which vends a SwiftUI `Color`), but its **logic is platform-free**, so
  it's unit-tested in `SnappetTests` with no device (mirrors keeping the engine platform-free; grep-confirms
  no platform import added to the engine, and `git diff` shows the engine source unchanged). Returns `nil`
  for an **empty** series (so the view hides the whole section); a **single-sample** series yields
  avg=max=min and **zero dwell** (one point has no following interval). Time-in-zone uses **left-edge
  attribution**: each sample owns the interval until the next, so dwell sums to the series span and the
  last sample contributes nothing — a deliberate, tested convention.
- **Reuse, don't reimplement**: the chart line feeds the points through
  `HighlightEngine.HeartRateSeries.make(...)` (resample→smooth, 5 s window) for a clean line rather than a
  jagged raw plot — the engine is **called**, never modified. Time-in-zone reuses `HeartRateZone.forBpm`
  (default max HR 190, the A4 fixed constant — no user HR profile yet; `maxHR` is a parameter so a future
  profile drops in with zero zone-math change). The zone bar/legend reuse `HeartRateZone.color`/`pillLabel`.
- **Thin view** (`SessionDetailView.swift`): a `HeartRateSummarySection` (`private struct`) rendered only
  when `WorkoutHRStats.make` is non-nil, composing a `HeartRateChart` + an avg/max/min row + a `ZoneBar`
  (each a small `private struct`); no HR math in the view. The B1 `SessionMediaSection` is unchanged and
  stays below. The chart/zone bar carry `accessibilityIdentifier`s (`hrChart`, `hrZoneBar`) for future
  assertions. Per-exercise HR overlay was **skipped** (the optional nice-to-have) — not needed for the
  core chart+stats+gallery and not cheap enough to justify here.
- **No new `@Model`** → `SnappetSchema.models` unchanged.

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**. `SnappetWatch`
(watchOS 26.5 sim) → **BUILD SUCCEEDED**. `SnappetTests` → **74/74 pass** (62 prior + 12 new
`WorkoutHRStats`: avg/max/min, order-independence, time-in-zone left-edge bucketing + custom-maxHR shift,
`orderedZoneSeconds` low→high, empty→nil, single-sample→zero-dwell, the `HRSample→HRPoint` map + empty +
round-trip). `HighlightEngine` → **18/18**, source unchanged (grep-clean, `git diff` empty).
`WorkoutWalkthroughTests` → **green** (the sim finishes with an empty `hrSeries`, so the HR section hides
and the gallery/stats absence doesn't break the flow).
**Device-pending (NOT verified by this build/tests)**: the chart's actual **visual** with a **real
live-HR series** — the smoothed bpm line, the avg/max/min over real data, and the time-in-zone bar
filling — needs a device with a live HR source (Apple Watch or BLE band) finishing a session, because the
simulator has no HR source so it persists an empty `hrSeries` and the chart hides. A clean sim build +
synthetic-data unit tests prove the **math + the shape**, NOT a verified live-HR chart (the same honesty
bar as A1–A4 / B1). Also device-pending: that the additive `hrSeries` migrates an existing on-device store
without data loss (lightweight migration is exercised only by the fresh-store sim run here).

## [2026-06-01] B1 — session media tagging (photos/videos shot during a workout) (WorkoutTracker)

**Decision**: Implemented prompt B1 (`pdd/prompts/features/live-workout-studio/B1-session-media-tagging.md`,
branch `feat/live-workout-session-media`). A WorkoutTracker session can now collect the photos/videos taken
during it — auto-discovered by capture-time window and/or added by hand — stored as session-scoped tags and
shown in `SessionDetailView`. This is the video-studio data foundation B2/B3/B4 consume (RESEARCH.md §3.4,
verdict GO).

**Concrete, non-obvious choices made:**
- **`SessionMedia` shape + FK-not-relationship** (`Features/WorkoutTracker/SessionMedia.swift`): `id`,
  `sessionID: UUID` (a `WorkoutSession.id` **foreign key**, NOT a SwiftData `@Relationship`),
  `localIdentifier` (PHAsset id), `kindRaw` (photo/video as a string), `offsetSec` (capture time relative to
  `startedAt`, **clamped ≥ 0** in `init`), `durationSec: Double?` (videos), `addedManually: Bool`,
  `createdAt`. The FK-not-relationship choice matches the rest of WorkoutTracker (`Routine`/`WorkoutSession`
  key on `UUID`) so the gallery loads with a clean per-session `#Predicate<SessionMedia> { $0.sessionID ==
  sid }` — the suite's per-parent query convention. The asset **bytes never enter the store**: a row holds
  only the `localIdentifier` + offset; Photos keeps the media (on-device only).
- **One central edit**: appended `SessionMedia.self` to the single `SnappetSchema.models` line in
  `Core/SnappetCore.swift` (additive, no migration).
- **±90 s pad reused from `PhotoLibraryService`**: `SessionMediaService.padSec = 90`, the same grace padding
  the flagship Reels app uses for clock skew/drift between the recording device and the workout clock. (The
  TZ-normalization caveat flagged in `project.md` for the post-hoc path applies equally here — unconfirmed
  until measured on a device.)
- **Pure mapping isolated for testability**: `SessionMediaService` exposes static `window`/`isInWindow`/
  `offset`/`candidates(from:)` that take plain tuples — **no PhotoKit type crosses that boundary** — so the
  in-window predicate (incl. ±pad boundaries, inclusive), the clamped `creationDate → offset` math, and
  dedupe-by-`localIdentifier` are unit-tested in `SnappetTests/SessionMediaMappingTests.swift` (8 cases)
  with no device. (Mirrors keeping `HighlightEngine` platform-free; this lives in the app since it wraps
  PhotoKit, but its logic is device-free — grep-confirmed no platform import added to the engine.)
- **Auto-discovery trigger point**: `SessionDetailView`'s gallery section fires auto-discovery **once on
  first appear, silently** (only if full access is already granted — value-first, never prompts on appear),
  **plus** an explicit "Find media from this workout" button that *does* request access value-first. Manual
  add is the "Add photos/videos" PHPicker button (`addedManually = true`); remove is a long-press context
  menu. Re-running discovery is safe (deduped by `localIdentifier`).
- **`.limited`-access handling**: a `.limited` grant can't scan the library by time window, so
  `discover(...)` throws `.denied` unless **fully** `.authorized`; the UI routes `.limited` to the PHPicker
  (the suite-wide limited-access fallback). Manual picks bypass the window filter (the user chose them) but
  are still offset-aligned + deduped.
- **Thumbnails**: `PHImageManager` with `deliveryMode = .highQualityFormat` (a single final callback, so the
  `withCheckedContinuation` bridge resumes exactly once) and `isNetworkAccessAllowed = false` (on-device
  only). Missing assets (e.g. on the simulator) render a placeholder.

**Device-pending (NOT verified by this build/tests)**: live PHAsset auto-discovery surfacing real clips,
the `.limited`/`.authorized` permission prompts, and rendered thumbnails — the simulator has no Photos
library. Verified here: the `@Model` + service + UI + the pure mapping (app + watch sim build, 8 new
mapping tests + the 56 existing `SnappetTests`, `WorkoutWalkthroughTests`, `HighlightEngine` 18/18). A clean
build is **not** verified Photos discovery. Open gate (PLAN.md): on a device, does discovery surface clips
*during* an active session or only after the Camera app finalizes them? If real-time tagging fails →
in-app `AVCaptureSession` capture (B1b).

## [2026-06-01] A4 — live-metrics overlay UI (HR zone + overall timer + rest timer) (WorkoutTracker)

**Decision**: Implemented prompt A4 (`pdd/prompts/features/live-workout-studio/A4-live-overlay-ui.md`,
branch `feat/live-workout-overlay`). Replaced A1's temporary `liveMetricsDebugRow` in `WorkoutPlayerView`
with a polished **live-metrics overlay** that composes, at a glance: the **live HR** (bpm + zone
color/label + source name), the **overall workout timer** (A2's `overallTimerHeader`), and — on the rest
screen — the **rest countdown**, plus a graceful **no-source** state. This is the user's "overlay fitness
data along with current and overall workout timer" ask (RESEARCH.md §3.2).

**Concrete, non-obvious choices made:**
- **`HeartRateZone` is a pure value type** (`Features/WorkoutTracker/HeartRateZone.swift`, `enum: Int`,
  `Sendable`/`Equatable`) — the only SwiftUI surface is `var color: Color` (itself a value type), so the
  bpm→zone mapping is **unit-testable in `SnappetTests` with no device** (mirrors keeping `HighlightEngine`
  platform-free, but this lives in the app since it returns a SwiftUI `Color`; the engine stays untouched,
  grep-confirmed no platform import). `forBpm(_:maxHR:)` is the single mapping point; the view does no zone
  math.
- **Default max HR = 190, a fixed constant (not `220 − age`)** — and *why*: the suite has **no user age /
  HR profile yet**, so a personalized max isn't computable. 190 is a reasonable adult ceiling that gives
  the overlay meaningful **relative** zone color without pretending to be a training prescription. The
  zones are the common 5-zone %-of-max model (recovery <60% / easy 60–70 / aerobic 70–80 / threshold
  80–90 / max ≥90), lower-bound inclusive. `maxHR` is a parameter, so when a profile lands (a later
  prompt) the call site passes a real max with **zero** change to the zone math.
- **A `.none` zone** (rawValue 0) for nil / no-data, distinct from "a real but very low bpm": `forBpm`
  returns `.none` for `nil`, non-positive bpm, **and** non-positive `maxHR` (a degenerate max can't yield a
  meaningful zone → no-data, not a crash). `.none` renders the inert secondary-gray pill, never a fake
  "Z1", so a missing watch / band reads as missing.
- **The overlay composes the two timers via existing pieces, not a re-implementation**: `overallTimerHeader`
  (A2, the self-updating `Text(timerInterval:)` pinned via `.safeAreaInset(.top)`) is unchanged; the new
  `liveMetricsOverlay` (the HR pill) is placed at the top of **both** the exercise `ScrollView` and the
  rest screen (so HR stays visible while resting, alongside the rest countdown circle). No new timer loop,
  no Live-Activity regression — the existing `.onChange` pushes are untouched.
- **`LiveHRPill` is a thin file-private view** handed an already-computed bpm + `HeartRateZone` + source
  name + the no-source text — **no business logic in the view** (conventions.md "views are thin"). With a
  sample: ❤️ (zone-tinted, `.pulse`) + bpm (zone color) + `pillLabel` ("Z3 · Aerobic") chip + `displayName`.
  Without one: the source-aware status (reusing A1/A3's `liveStatusText` / `MetricsSourceState`, e.g. "Open
  the workout on your watch" / "Connecting…" / "No watch metrics on this device"). The pill reads live data
  **only** through `app.liveWorkout` (the coordinator) — never `watch` / `ble` directly.
- **Accessibility**: the overlay carries `accessibilityIdentifier("liveMetricsOverlay")` (an
  `accessibilityElement(children: .ignore)` with a composed label/value) so the walkthrough can assert it.
  No new `@Model` → `SnappetSchema.models` unchanged.

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**, 0 warnings from
these changes. `SnappetWatch` (watchOS 26.5 sim) → **BUILD SUCCEEDED** (A1/A2/A3 unbroken). `SnappetTests`
→ **56/56 pass** (48 prior + 8 new `HeartRateZone`: nil/no-data, non-positive bpm + non-positive maxHR,
default-190 boundary table, custom-maxHR boundary shift, labels / `pillLabel`, distinct rawValues).
`HighlightEngine` → **18/18**, source unchanged (no platform import). `WorkoutWalkthroughTests` → **green**,
including the new `liveMetricsOverlay` assertion (it resolves as an `Other` element in the player).
**Device-pending (NOT verified)**: the overlay's **live visual** — the zone colors filling in, the ❤️ pulse,
and a real bpm rendering — needs a device with an HR source (Apple Watch or a BLE band). The sim has no
watch/HR, so the walkthrough asserts only the **no-source** state; a clean sim build + the no-source render
+ the pure zone tests prove the **shape**, not a live-HR rendering (same honesty bar as A1/A2/A3).

---

## [2026-06-01] A3 — MetricsSource abstraction + generic BLE heart-rate band (WorkoutTracker)

**Decision**: Implemented prompt A3 (`pdd/prompts/features/live-workout-studio/A3-…md`,
branch `feat/live-workout-metrics-source`). The live-metrics layer is now behind a pluggable
**`MetricsSource`** protocol so live HR can come from **either** the Apple Watch (A1) **or** a generic
**BLE heart-rate band** (chest straps / Polar / Garmin / any device exposing the standard Heart Rate
Service), with band identification + a picker. This realizes the A1 doc-comment promise (the surface was
shaped to become a protocol with a BLE conformer without call-site churn) and the RESEARCH.md §3.3
decision (non-Apple bands connect on-device via the BLE Heart Rate Profile — never a cloud API).

**Concrete, non-obvious choices made:**
- **`MetricsSource` protocol** (`Services/MetricsSource.swift`, `@MainActor`, `AnyObject`) mirrors the
  `HighlightSelector` pluggability (decisions.md 2026-05-30): `latestHR`, `energy`, `samples` (the engine
  `HRSample` buffer), a source-agnostic `state: MetricsSourceState`
  (`.unavailable/.idle/.connecting/.connected/.streaming`), `isReachable`, `displayName`,
  `start(for:sport:category:)`, `stop()`. The app talks only to this — HR transport is invisible to the
  player / Live Activity / overlay. `HighlightEngine` stays platform-free (grep-confirmed: no
  HealthKit/CoreBluetooth/WatchConnectivity import in the package); live HR is plain `HRSample`s at the
  `Services` boundary, exactly like the post-hoc path.
- **`isWatchReachable → isReachable` + `connectionState → MetricsSourceState` migration**: A1's
  `LiveWorkoutService` became `AppleWatchMetricsSource` with **byte-for-byte identical** WCSession /
  buffering / offset behavior (the A1 offset + mapping + round-trip tests pass unchanged, only the type
  name updated). The watch-specific `isWatchReachable` was renamed to the protocol's `isReachable` (the
  one call-site change the A1 review flagged); the watch's `ConnectionState` is **kept internal** (the
  resume/replace lifecycle in `WorkoutHomeView` is genuinely watch-specific) and **mapped** onto
  `MetricsSourceState` via a computed `state` (`.workoutRunning` → `.streaming` once a sample arrives,
  else `.connected`; `.active` → `.connecting` when reachable; `.unsupported` → `.unavailable`).
- **BLE parsing isolated into a pure static func** `BLEHeartRateMetricsSource.parseHeartRate(_:)` so it is
  unit-testable with no device/band: byte 0 = flags, **bit 0** selects UInt8 (1 byte) vs little-endian
  UInt16 (2 bytes) BPM; optional sensor-contact (bits 1–2) / energy-expended (bit 3) / RR (bit 4) fields
  are **ignored** (only BPM needed); an empty or too-short buffer (e.g. flags say UInt16 but one value
  byte) returns `nil` so a malformed packet can't poison the buffer. **`energy = 0`** — the Heart Rate
  Profile has no calorie field. Unlike the watch (which relays its own monotonic `t`), a BLE measurement
  has no timestamp, so its `sessionOffset` uses **wall-clock elapsed** since `session.startedAt`, clamped
  ≥ 0. The central scans `0x180D`, exposes a deduped `[BLEDevice]` (by `CBPeripheral.identifier`, a plain
  value type so the picker/tests don't import CoreBluetooth), connects a chosen one, discovers `0x180D` →
  `0x2A37`, and subscribes for ~1 Hz notifications.
- **Swift-6 CoreBluetooth concurrency**: `CBCentralManagerDelegate`/`CBPeripheralDelegate` callbacks are
  `nonisolated` (they arrive on CB's queue) and hop to `@MainActor` via `Task { @MainActor in … }` before
  mutating observable state — mirroring the `WCSessionDelegate` pattern. The static `CBUUID` constants and
  `parseHeartRate`/`sessionOffset`/`resolve` are marked `nonisolated` so the off-actor callbacks (and the
  pure tests) can reach them; the non-Sendable `CBPeripheral`/`CBCentralManager` are carried into the
  MainActor hop via `nonisolated(unsafe) let` (the documented escape hatch — they're confined to CB's
  queue and CB tolerates `connect` from any queue). Bluetooth permission is **deferred**: the
  `CBCentralManager` is created lazily on `prepare()` (when the picker opens), not at app launch.
- **`LiveMetricsCoordinator` keeps the `AppModel.liveWorkout` property NAME** (so A2/A4 call sites don't
  churn) and is itself a `MetricsSource`: it holds both concrete sources, tracks a user `selectedSource`
  + the discovered-BLE list, and **forwards** the whole protocol surface to the active source. `stop()`
  stops **both** sources so a mid-session source switch never strands a transport. Selection is a pure,
  unit-tested rule `resolve(selected:watchUsable:hasBLEDevice:)`: an explicit pick wins; else prefer the
  watch when usable (paired + app installed); else BLE if a band was chosen; else default to the watch
  (its `.unavailable` drives the UI's "no source" message — A1 behavior preserved). A small
  `connectionState` shim forwards to the watch source so the watch-specific resume/replace guard in
  `WorkoutHomeView` is unchanged.
- **Picker UI** (`HeartRateSourcePicker`) is presented as a **sheet** from `WorkoutSettingsView`'s new
  "Live metrics" section — a sheet may carry its own `NavigationStack`, so the no-nested-stack rule for
  the module is honored. It lists Apple Watch + scanned bands (rows have `accessibilityIdentifier`s:
  `hrSourceAppleWatch`, `hrSourceBLEDevice`, plus `openHeartRateSource`); scanning starts on appear (the
  one-time Bluetooth prompt) and stops on disappear. The player's status text became source-aware (BLE
  states vs the watch wording).
- **No new `@Model`** → `SnappetSchema.models` unchanged. `NSBluetoothAlwaysUsageDescription` added to the
  app Info.plist.

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate`; `Snappet` iOS scheme built for the
iPhone 17 Pro sim (`-destination` only, embedded watch + widget) → **BUILD SUCCEEDED**, 0 warnings from
these changes. `SnappetWatch` (watchOS 26.5 sim) → **BUILD SUCCEEDED** (A1 unbroken). `SnappetTests` →
**46/46 pass** (the 28 prior + 18 new: HR-measurement parser UInt8/UInt16 with/without sensor-contact &
energy fields + malformed/short → nil, BLE wall-clock offset, BLE ingest/energy/state, and the
source-selection rule + coordinator forwarding). `HighlightEngine` → **18/18**, source unchanged.
`WorkoutWalkthroughTests` → **green** (the `MetricsSourceState` change didn't alter the walkthrough's
asserted text; the overall-timer assertion still passes).
**Device-pending (NOT verified)**: a **real BLE band connect + live HR stream** — the `0x180D` scan,
`0x2A37` subscription, parse-to-`HRSample`, and the picker's connect flow — only run on a device with a
physical heart-rate band. A sim build proves the shape + the pure parser, **not** a live stream (the same
honesty bar as A1's WCSession relay). Battery/latency of a sustained BLE notify stream is also a device check.

**Post-review hardening (2026-06-01, same branch)**: review fixes applied before merge: (1) the resume
guard in `WorkoutHomeView` used the watch-specific `connectionState != .workoutRunning`, which is **always
true for a BLE session** (BLE never sets `.workoutRunning`) → every resume restarted metrics and **cleared
the BLE HR buffer**; added a source-agnostic `LiveMetricsCoordinator.isSessionActive` (set in `start`,
cleared in `stop`) and the guard now reads `!isSessionActive`; (2) `BLEHeartRateMetricsSource.connect`
now disconnects the previously-connected band before connecting a new one (else two peripherals stream
into `ingest` at once) and early-returns on a double-tap of the already-connected band (no `.streaming`→
`.connecting` downgrade); (3) `stop()` resets state from **any** active state incl. `.connecting` (a
workout ended mid-connect no longer strands "Connecting…") and clears the peripheral ref; (4) `startScan()`
clears the stale `discovered` list and no longer double-invokes the scan. The "duplicate device on rapid
discover" flag was **refuted** (the `didDiscover` Tasks hop to the serialized `@MainActor`, so the
`contains` check isn't racy). Added 2 tests (flags-only UInt16 buffer → nil; `isSessionActive` start/stop);
SnappetTests 46→48. **Known limitation (documented, not fixed)**: switching the HR source *mid-session*
doesn't auto-start the newly-selected source, and watch-usability isn't `@Observable` (a watch pairing
mid-workout won't re-resolve the active source) — both are unusual mid-session interactions, deferred.
Re-verified: app + watch BUILD SUCCEEDED, SnappetTests 48/48, HighlightEngine 18/18 (engine import-clean),
WorkoutWalkthroughTests green.

---

## [2026-06-01] A2 — overall workout timer + background Live Activity (WorkoutTracker)

**Decision**: Implemented prompt A2 (`pdd/prompts/features/live-workout-studio/A2-…md`,
branch `feat/live-workout-overall-timer`). A running WorkoutTracker session now has (1) an **overall
workout timer** in the player and (2) a **Live Activity** (Lock Screen + Dynamic Island) showing the
overall timer + live HR + current exercise/set — solving the user's "routine can't run in background" +
"no overall timer" asks (RESEARCH.md §3.2) and making live HR visible without the app foregrounded.

**Concrete, non-obvious choices made:**
- **Overall timer = wall-clock `Text(timerInterval:)`, no background CPU.** The player header renders
  `Text(timerInterval: session.startedAt...distantFuture, countsDown: false)` so SwiftUI/the OS ticks it
  off the wall clock — correct across backgrounding *by construction*, the same end-`Date` philosophy the
  rest timer already uses. It runs alongside the per-set rest circle, labelled "Total" vs the rest timer.
  It carries `accessibilityIdentifier("overallWorkoutTimer")` + an `.accessibilityValue` from the pure
  `WorkoutLiveSnapshot.elapsedString` so the walkthrough can assert it deterministically. No per-second
  state, no timer loop for the overall clock — only the *live HR* needs the watch session.
- **New Widget Extension target `SnappetWidgets`** in `project.yml` (`type: app-extension`,
  `NSExtensionPointIdentifier = com.apple.widgetkit-extension`, iOS 18 deployment, `SKIP_INSTALL=YES`,
  bundle id `com.snappet.app.widgets`), **embedded** in the phone app like the watch target, and added to
  the `Snappet` scheme's build targets. Added `NSSupportsLiveActivities = YES` to the app Info.plist.
- **One shared `ActivityAttributes` contract** (`Shared/WorkoutActivityAttributes.swift`, compiled into
  *both* the app and the widget extension via the `Shared/` path) — same can't-drift pattern as
  `LiveWorkoutMessage`. Static `routineName`; `ContentState { startedAt: Date; hrBpm: Int?;
  exerciseName: String; setProgress: String }`. The Live Activity renders the overall timer with
  `Text(timerInterval: state.startedAt…)` (OS-ticked, no pushed per-second updates). `ContentState` is
  `Codable, Hashable, **Sendable**` — the `Sendable` is load-bearing so `Activity<…>` is Sendable.
- **`LiveActivityController` service** (`Services/`, `@MainActor @Observable`, guarded
  `#if canImport(ActivityKit)`): `start(routineName:startedAt:…)`, `update(_:)`/`update(hrBpm:…)`, `end()`.
  Every entry point **no-ops** where ActivityKit can't be imported, the OS is < iOS 16.1, or
  `ActivityAuthorizationInfo().areActivitiesEnabled == false`; `start` ends any prior activity first so a
  resume never strands an orphan. Holds the activity as `Any?` + a typed `@available(iOS 16.1)` computed
  accessor so the type isn't referenced below its availability floor.
- **Swift-6 send of the activity into a detached async update**: `Activity` is documented thread-safe &
  `Sendable`, but the local picks up a main-actor tag from the `@MainActor` getter, so `Task { await
  activity.update(...) }` tripped region isolation ("sending main-actor-isolated value to a nonisolated
  method"). Resolved with `nonisolated(unsafe) let act = activity` immediately before the `Task` — the
  documented escape hatch for a value that's genuinely safe off-actor. (Marking `ContentState: Sendable`
  was necessary but not sufficient on its own.)
- **Lifecycle co-located with the existing session lifecycle** in `WorkoutHomeView`: `start` the activity
  in `startLiveMetrics` (so every start/replace path covers it) + on `resume` (the activity lives on the
  phone independently of the watch, so it's (re)started even on a warm resume after a cold relaunch);
  `end()` in `finishWorkout` alongside `liveWorkout.stop()`. The player pushes `update`s via `.onChange`
  on phase / exerciseIndex / setIndex / `liveWorkout.latestHR`, mapping a pure `WorkoutLiveSnapshot`
  (platform-free, in `Features/WorkoutTracker/`) → `ContentState`. The snapshot is the single source of
  truth both the in-player timer and the activity read, and is what the unit tests exercise.
- **No new `@Model`** → `SnappetSchema.models` unchanged. `HighlightEngine` untouched (no platform import;
  `grep` confirms none added).

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate` defines app + watch + **SnappetWidgets**
targets. `Snappet` iOS scheme builds for the iPhone 17 Pro sim (with the embedded widget extension +
watch) → **BUILD SUCCEEDED**, 0 warnings from these changes (the widget `.appex` builds and embeds).
`SnappetWatch` builds for the watchOS 26.5 sim → **BUILD SUCCEEDED** (A1 unbroken). `SnappetTests` →
**24/24 pass** (the 15 existing + 9 new: elapsed-time formatting, snapshot field carry-through, and the
`ContentState` field-mapping + Codable round-trip). `HighlightEngine` → **18/18**, source unchanged.
`WorkoutWalkthroughTests` → **green**, including the new `overallWorkoutTimer` assertion.
**Device-pending (NOT verified)**: the actual Live Activity **rendering** — the Lock Screen banner and
the Dynamic Island compact/minimal/expanded regions — and the live HR appearing there, only truly run on
a device (Live Activities need a real Lock Screen / Dynamic Island; the sim build proves the *shape*, not
the on-device activity). Update-budget behavior under a real workout is also a device check.

**Post-review hardening (2026-06-01, same branch)**: review fixes applied before merge: (1) **HR update
storm** — the player fired an ActivityKit `update` on every ~1 Hz HR sample (would exhaust the update
budget and lag the Lock Screen); added a pure, unit-tested `WorkoutLiveSnapshot.shouldPush` throttle —
structural changes (exercise/set text) push immediately, HR-only changes are rate-limited to ≥2 s — and
`LiveActivityController.update(_:)` now consults it via stored `lastSnapshot`/`lastPushedAt`; (2) **warm
resume no longer end+recreates** a Live Activity that's already showing (new `isRunning` guard);
(3) `startLiveActivity` seeds a real `"Set 1 of N"` so the Lock Screen isn't blank if backgrounded before
the player appears. The "set-number off-by-one during rest" flag was **refuted** (SwiftUI applies all
`@State` mutations before `.onChange` fires, so the snapshot reads the settled `phase`). Added 4 throttle
unit tests (SnappetTests 24→28). Re-verified: app + watch BUILD SUCCEEDED, SnappetTests 28/28,
HighlightEngine 18/18, WorkoutWalkthroughTests green.

---

## [2026-06-01] A1 — watchOS companion + live HR relay implemented (WorkoutTracker gains a live path)

**Decision**: Implemented prompt A1 (`pdd/prompts/features/live-workout-studio/A1-…md`,
branch `feat/live-workout-watchos-companion`). WorkoutTracker now has a **live metrics source**:
a new **watchOS companion target** (`ios/App/SnappetWatch/`) runs an `HKWorkoutSession` +
`HKLiveWorkoutBuilder` and relays live HR/energy to the phone over `WCSession`; the phone starts the
matching `HKWorkoutActivityType` on the watch from the routine. This **supersedes the v1
post-hoc-only / no-watchOS deferral for WorkoutTracker only** — the flagship Reels app's
`HealthKitService` (post-hoc) is unchanged and untouched.

**Concrete, non-obvious choices made:**
- **WCSession message shape** — one shared `LiveWorkoutMessage` enum (in `ios/App/Shared/`, compiled
  into *both* the phone and watch targets via `project.yml` so the wire can't drift). Three messages,
  discriminated by a `kind` string key, encoded as plist dicts: `start(activityType: UInt)` (the
  `HKWorkoutActivityType.rawValue`), `stop`, and `metrics(hrBpm, energyKcal, t)`. Sent via
  `sendMessage` when reachable, falling back to `transferUserInfo` so a start/stop/sample isn't
  dropped while the counterpart is briefly unreachable.
- **Activity mapping table** (`WorkoutActivityMapping`, the inverse of `HealthKitService.map`):
  `SportTag` wins first — `.climbing → .climbing`, `.calisthenics → .functionalStrengthTraining`,
  `.general` falls through to the routine's **dominant `ExerciseCategory`**: `strength/powerlifting →
  .traditionalStrengthTraining`, `cardio → .running`, `plyometrics → .jumpRope`, `stretching →
  .flexibility`, `olympic/strongman → .functionalStrengthTraining`. Final fallback (no sport, no
  category) is `.traditionalStrengthTraining` (a gym routine's sensible default; the spec's `.other`
  is reachable only via an unmapped type). Dominant-category tie-break is deterministic by rawValue.
- **HR buffer attaches to `WorkoutSession`** via `LiveWorkoutService.sessionOffset(...)`: incoming
  watch samples carry `t` since the *watch* session start; the phone re-bases each onto the
  `WorkoutSession.startedAt` timeline (engine convention: `HRSample.t` = seconds since session start),
  preferring the watch's monotonic clock but flooring to wall-clock-elapsed if it's wildly ahead, and
  clamping ≥ 0. Buffer lives on the service (not persisted yet) for B2 to flush. Lifecycle is owned by
  `WorkoutHomeView` (`start(for:)` on session create/replace, `stop()` in `finishWorkout`), matching
  where the session lifecycle already lives — not the player.
- **Pluggability for A3**: `LiveWorkoutService`'s public surface (`connectionState`, `latestHR`,
  `energy`, `isWatchReachable`, `start(for:)`, `stop()`, `samples`) is shaped to become a
  `MetricsSource` protocol with a `BLEHeartRateSource` conformer with **no call-site change**,
  mirroring the `HighlightSelector` pluggability pattern. `HighlightEngine` is untouched — live HR
  becomes plain `HRSample` value types at the `Services` boundary.
- **Watch target config**: `WKBackgroundModes = [workout-processing]` (keeps HR flowing wrist-down /
  phone-pocketed), HealthKit + background-delivery entitlements, `WKCompanionAppBundleIdentifier =
  com.snappet.app`, bundle id `com.snappet.app.watchkitapp`, embedded in the phone app. Added a
  `SnappetTests` app unit-test target (separate from the platform-free `HighlightEngineTests`) for the
  pure pieces.
- **Build gotcha recorded**: building the iOS scheme with `-sdk iphonesimulator` forces that SDK onto
  the embedded **watch** target and breaks it ("HKLiveWorkoutBuilder only available in iOS 26"). Build
  the `Snappet` scheme with **`-destination` only** (no `-sdk`) so each target picks its own SDK. The
  `WorkoutWatchManager` must subclass `NSObject` (HK delegates require it).

**Verified (this environment, Xcode/SDK 26.5)**: `xcodegen generate` produces both an iOS app and a
watchOS app target. `SnappetWatch` builds for the watchOS 26.5 simulator → **BUILD SUCCEEDED**, 0
warnings. The `Snappet` iOS scheme (with the embedded watch target) builds for the iPhone 17 Pro sim →
**BUILD SUCCEEDED**, 0 warnings from these changes. `SnappetTests` → **15/15 pass**
(`WorkoutActivityMapping` + the HR-buffer offset math + message round-trip). `HighlightEngine` →
**18/18 pass**, source unchanged.
**Device-pending (NOT verified — the PLAN's "after A1" decision gate)**: the actual live relay — watch
starts the mapped `HKWorkoutSession`, HR streams to the phone within ~3 s, keeps updating with the
phone backgrounded, and battery cost — only runs on a **paired physical Apple Watch + iPhone**. A
simulator build proves the shape, not the stream.

**Post-review hardening (2026-06-01, same branch)**: a multi-angle review surfaced six fixes, applied
before merge: (1) watch `start()` sets a synchronous `starting` flag so a 2nd start during the async
auth await can't spawn a duplicate `HKWorkoutSession`; (2) `replaceActiveAndStart` now `stop()`s the old
watch session first (else the watch's `!isRunning` guard silently drops the new start); (3) all resume
paths (dashboard banner, "Resume current workout", re-tapping the same routine) route through a `resume()`
that restarts live metrics when the service isn't already running — fixing no-HR after a cold relaunch;
(4) the phone only promotes to `.workoutRunning` when a paired watch with the app installed exists
(`isPaired && isWatchAppInstalled`), so the overlay doesn't strand at "Waiting for heart rate…" with no
watch; (5) `LiveWorkoutMessage` metrics decode now requires every field (no `?? 0`) so a malformed
message drops instead of poisoning the buffer with phantom 0-bpm samples; (6) `.cardio → .mixedCardio`
(generic cardio isn't necessarily running) + removed dead `hrUnit`/`kcalUnit`. The "inverted tie-break"
flag was **refuted** (the comparator is deterministic, which is its only contract). `WorkoutWalkthroughTests`
gained `-uiTestFreshStore` (it was the lone UI test without it — a leftover active session was triggering
the start-conflict dialog). Verified: iOS + watchOS BUILD SUCCEEDED, `SnappetTests` 15/15, `HighlightEngine`
18/18, `WorkoutWalkthroughTests` + `SuiteSmokeTests` green (walkthrough green on two consecutive runs).

---

## [2026-06-01] Live Workout Capture + Video Studio initiative — reopens the watchOS/BLE/in-app-capture deferrals (for WorkoutTracker only)

**Decision**: Scoped a new initiative (research + plan, branch `plan/live-workout-video-studio`, GitHub
issue #15) that turns **WorkoutTracker** from a foreground-only set logger into a live, instrumented,
media-rich workout with an on-device video studio. Direction chosen with the user (2026-06-01):
(1) **Apple Watch companion first** — a new watchOS target running `HKWorkoutSession`/`HKLiveWorkoutBuilder`
with a `WCSession` relay is the only supported way to get live HR + background execution + "start the
right workout on the watch"; (2) **unify** — finishing a WorkoutTracker session feeds the existing
**`HighlightEngine`/`ReelPlanner`** (HR + tagged clips + manual selection) to generate highlights, with
**no engine change**; (3) **full CapCut-style editor** on `AVMutableVideoComposition` +
`AVVideoCompositionCoreAnimationTool`. Two parallel tracks (A: live capture A1–A4; B: studio B1–B5) in
`pdd/prompts/features/live-workout-studio/PLAN.md`; feasibility in that folder's `RESEARCH.md`.
**Why**: the selector/engine were kept platform-free and pluggable *specifically* so a live path could be
added without a rewrite — this is that day. Live HR becomes plain `HRSample`s at the `Services` boundary,
so `HighlightEngine` stays platform-free; all new platform I/O is a `Services/` type; a `MetricsSource`
protocol (Apple Watch → BLE → post-hoc HealthKit) mirrors the `HighlightSelector` pluggability.
**Supersedes (scoped to WorkoutTracker, NOT the flagship Reels app)**: the v1 calls *"reads COMPLETED
workouts, not a live watchOS session"* (2026-05-30) and *"out of scope for v1: watchOS live capture,
generic BLE bands, in-app capture"* (`PLAN-ios-to-shippable.md`). This initiative sits **on top of** a
shipped v1 and does not block it.
**Rules out (for now)**: **Fitbit live / Google Fit on iOS** — no real-time API, cloud-only, violates the
on-device-only constraint (`RESEARCH.md` §3.3); a non-Apple band is only ever a *post-hoc HealthKit*
source if its app writes to Health, or a *live BLE* source (`0x180D`) via CoreBluetooth in Phase 2.
Health Connect belongs to the Android target. **Status**: research + plan only — no implementation code
yet; A1 (watchOS companion) is authored and ready to run.

---

## [2026-05-31] Pomodoro settings persist via @AppStorage in the view, applied to the engine

**Decision**: Focus/break lengths are stored as `@AppStorage("pomodoro.focusMinutes"/".breakMinutes")`
in `PomodoroRootView` (and bound straight into the settings sheet); the view pushes them into the
`@Observable PomodoroTimer` via a new `applyDurations(focusMinutes:breakMinutes:)` on appear and on
change. The 7-day focus chart (`PomodoroFocusChart` + `PomodoroStats.last7Days`) renders on both the
root and atop History, fed by a single `@Query` over the last 7 days. A `UINotificationFeedbackGenerator`
fires in `PomodoroTimer.completePhase` (UIKit guarded by `#if canImport(UIKit)` to keep the type buildable
off-device). **Why**: `@Observable` classes can't host the `@AppStorage` property wrapper, so persistence
lives in the view (the one SwiftUI place it works) and the timer stays a plain engine that's told its
durations. One shared 7-day query avoids a second round-trip. **Rules out**: persisting the timer object
itself; a new `@Model` for history (it reads existing `PomodoroSession` rows); a nested `NavigationStack`
(History is reached via `navigationDestination(for: PomodoroRoute.self)` on the suite's stack).

---

Product-level decisions (separate repo, etc.) live in the web repo's
`decisions.md`; this file is native-implementation-specific.

---

## [2026-05-31] Button-driven, UI-testable navigation via a shared SuiteRouter

**Decision**: Replaced the modules' value-based `NavigationLink(value:)` list rows with plain `Button`s
that push onto a shared `NavigationPath` owned by a new `@Observable SuiteRouter` (injected via
`.environment` at the App Library, which now uses `NavigationStack(path:)` and pushes modules by a
`ModuleRoute` value). Every interactive row got an `accessibilityIdentifier`. Added a `SnappetUITests`
target with a workout walkthrough + an all-modules smoke test.
**Why**: XCUITest cannot activate SwiftUI `List` `NavigationLink` rows in this app — they expose as
`Cell → StaticText` with no button trait, so no tap (cell / text / identifier / coordinate) navigates,
which made every detail screen un-automatable. `Button`s are real, hittable controls; a spike proved the
end-to-end chain (card → row → detail → player → finish) is now drivable and screenshot-verified.
**Also**: session detail pushes a lightweight `SessionRoute(id:)`, never the `WorkoutSession` model — the
model type is the player `fullScreenCover(item:)`, and pushing it onto the path while that cover exists
wedges the push.
**Rules out**: relying on value-based NavigationLink rows for testable navigation; modules owning their
own `NavigationStack` (they still ride the App Library's, now path-based).
**Known limitation**: the **History → session-detail** row is the one row left as a value-based
`NavigationLink` — a `Button` there provably never fired its action on tap (a narrow SwiftUI/List quirk,
confirmed by logging vs a working control). It works for users but isn't XCUITest-tappable; kept rather
than shipping a dead Button.
**Verified**: `xcodebuild` iPhone 17 Pro sim BUILD SUCCEEDED; `SnappetUITests` both tests green
(`WorkoutWalkthroughTests`, `SuiteSmokeTests`). Shipped as a stacked PR on top of #6/#7.

## [2026-05-31] Workout tracker UX: fix start/finish transitions without a module-owned NavigationStack (#5)

**Decision**: A deep UX review (issue #5) found the workout player + start-conflict dialog were presented from `WorkoutHomeView` while a pushed `RoutineDetailView` sat on top — making presentation fragile and dropping the user back on the routine's prescription page after a workout. Rather than give the module its own `NavigationStack`/`NavigationPath` (banned — modules ride the App Library's stack), the routine detail now **pops itself (`@Environment(\.dismiss)`) before calling `start()`**, so the cover/dialog present from the home (top of stack) and finishing lands on the home; `finishWorkout` switches to the **Dashboard** on a saved finish. The Routines list's previously-dead `start` closure is wired to a swipe + context-menu "Start". `RoutineDetailView` hides the suite tab bar (`.toolbar(.hidden, for: .tabBar)`) so its bottom Start bar doesn't stack on it. Separately (branch `fix/workout-player-session`), the live player never persists a **zero-set** session (auto-discard), and the rest timer is driven off a target **end `Date`** so backgrounding doesn't make it drift.
**Why**: keeps the no-nested-NavigationStack contract intact while fixing the actual transition bugs; `dismiss()`-then-start is the idiomatic way for a pushed child to hand presentation back to its host.
**Rules out**: a module-owned navigation stack/path; saving empty workouts; a wall-clock-naive rest timer.
**Deferred** (issue #5 "Low"): icon-only segmented section labels, disambiguating the two "Workout*" app names, and flattening the triple-stacked routine-editor sheets.
**Shipped on**: branches `fix/workout-nav-and-transitions` + `fix/workout-player-session`.
**Verified**: `xcodebuild` for the iPhone 17 Pro sim → **BUILD SUCCEEDED** (both branches merged); no new warnings from these changes. The transition *feel* (pop-then-present, tab-bar hide, rest-timer foreground correction) still needs a sim/device run.

## [2026-05-31] Pivot to the Snappet daily-app SUITE — shared store + module registry + dashboard (P9)

**Decision**: Expanded from a single workout app to the **daily-app suite** thesis (#60 §D): a `TabView`
shell (Home dashboard + App Library), an on-device **SwiftData** shared store (**Snappet Core**), and a
pluggable **module registry**. Built 6 mini-apps alongside the existing Workout module — Pomodoro,
Habits, Journal (productivity); Tip, Split Expenses, Budget (finance) — via parallel agents.
**Architecture / contract** (so the suite stays pluggable):
- `SnappetCore` (`Core/SnappetCore.swift`) wraps the shared `ModelContext` and exposes
  `log(module:action:summary:metric:)`. Every mini-app logs usage there; the **Home dashboard**
  (`@Query` over `UsageRecord` + Swift Charts) aggregates *historical sub-app usage* across the suite.
  The App Library logs an `open` event centrally, so every module gets baseline tracking for free.
- A mini-app = a self-contained `Features/<App>/` folder vending `AppModule` (`Core/AppModule.swift`)
  with `id/title/subtitle/systemImage/tint/category/destination`. `ModuleRegistry.all` lists them;
  `SnappetSchema.models` lists every `@Model` (the one central place new persistence types are added).
- Modules are **pushed into the App Library's `NavigationStack`** → they must NOT nest their own.
- Permissions are **per-module**, not global: the suite opens instantly; the Workout module primes
  Health/Photos on first entry (the old global onboarding gate was removed).
**Persistence**: SwiftData. `@Model` types: `UsageRecord`, `PomodoroSession`, `Habit`+`HabitCompletion`,
`JournalEntry`, `ExpenseGroup`+`ExpenseRecord`, `BudgetCategory`+`BudgetTransaction`. Mini-apps key
relations by `UUID` foreign keys (not `@Relationship`) for clean per-parent `#Predicate` queries.
**Verified**: full `xcodebuild` for the simulator → **BUILD SUCCEEDED** (foundation + all 7 modules),
app installs + launches, Home dashboard renders. Device run + each app's real-data behavior still pending.

## [2026-05-31] Photos rendered as Ken-Burns clips instead of being dropped (P8)

**Decision**: `ReelExporter` previously filtered to `kind == .video` and silently dropped every photo
highlight (a photo-only workout exported nothing). Added `PhotoClipRenderer` (`AVAssetWriter` +
pixel-buffer adaptor) that renders each photo into a short H.264 **Ken-Burns** clip (slow 1.0→1.1 zoom
+ gentle pan), and `makeComposition` now iterates `plan.segments` **in order**, inserting video ranges
and rendered photo clips alike (photos are silent). Fixes preview + export together (both use
`makeComposition`).
**Why**: the engine/planner already select photo highlights and reserve `photoStill` seconds — only the
exporter ignored them. Rendering-to-clip keeps the composition's track-insertion model uniform (no
`AVVideoCompositionCoreAnimationTool` special-casing).
**Choices/limitations**: photo clips render at a fixed **1080×1920 portrait** canvas; mixed-orientation
normalization across video + photo segments (a unifying `AVVideoComposition`/`renderSize`) is **not**
done — pre-existing for video-only reels too, deferred. A failed photo render is skipped, never fails
the reel.
**Verified**: app type-checks (Swift 6, 0/0); full `xcodebuild` for the simulator → SUCCEEDED with
`PhotoClipRenderer.swift` compiled; app installs + launches. The actual Ken-Burns *visual* needs a
device/sim run with real photos.

## [2026-05-31] App now BUILDS + RUNS on the iOS simulator (not just type-checks); fixed Info.plist bundle keys

**Decision / milestone**: With Xcode 26.5 + iOS 26.3/26.4 simulator runtimes now present, ran a full
`xcodebuild` (compile **and link**) for `iphonesimulator` → **BUILD SUCCEEDED**, then `simctl install`
+ `launch` on an iPhone 17 (iOS 26.4) sim → the **value-first onboarding screen renders** and the app
stays alive (no crash). This supersedes the earlier "type-check only" verification ceiling.
**Bug fixed (build couldn't catch it; install did)**: `Info.plist` was missing `CFBundleIdentifier`,
`CFBundleExecutable`, `CFBundlePackageType`, etc. Because `GENERATE_INFOPLIST_FILE: NO`, Xcode injects
nothing, so the built `.app` had no bundle ID and `simctl install` failed ("Missing bundle ID"). Added
the core bundle keys (as `$(PRODUCT_BUNDLE_IDENTIFIER)` etc.) + orientations + `LSRequiresIPhoneOS`.
**Build invocation that works here** (the generic destination wants iOS 26.5 which isn't installed):
`xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=<booted-sim-udid>' CODE_SIGNING_ALLOWED=NO build`.
**Still device-only**: HealthKit has no Apple Watch *workouts* in the simulator and Photos has no
real media, so the end-to-end reel flow (real workout → auto-found media → reel) still needs a device
(P1 / `RUNBOOK-device.md`). The `Snappet.xcodeproj` is generated by XcodeGen and gitignored.

## [2026-05-31] Value-first onboarding + JIT permissions; `.limited` Photos → manual picker (P2)

**Decision**: First launch shows an `OnboardingView` that explains the value before requesting
anything; Health + Photos are requested only on the explicit "Connect" tap (`AppModel.completeOnboarding`).
Onboarding is gated on a persisted `snappet.hasOnboarded` flag (HealthKit read-auth status isn't
queryable). `.limited` Photo access (or an empty auto-discovery) routes to a `PHPicker` manual picker
(`MediaPicker`) → `PhotoLibraryService.media(forIdentifiers:)`.
**Why**: #60 §C (value-first, JIT). Also fixed a latent bug — `requestAccess()` was never called, so
Photos auth was never requested and the reel flow would always throw `.denied`.
**Rules out**: silent permission prompts on appear; assuming full-library scan under `.limited`.
**Verified**: app type-checks vs iOS 18; permission UX itself needs a device.

## [2026-05-31] In-app reel preview reuses the composition — no export round-trip (P3)

**Decision**: `ReelExporter.makeComposition(for:) async throws -> sending AVMutableComposition` is
shared by preview and export. `ReelViewModel` wraps it in an `AVPlayer` for an inline `VideoPlayer`;
edits (pin/remove/reorder/restore) invalidate the preview so the next build reflects them.
**Why**: an `AVMutableComposition` *is* an `AVAsset`, so the exact cut is previewable without exporting.
`sending` lets the freshly-built composition cross from the nonisolated exporter to the `@MainActor` VM
under Swift 6 isolation.
**Rules out**: exporting just to preview. Photo-only reels can't preview yet (degrade gracefully).

## [2026-05-31] Ship prep: privacy manifest declares NO data collection (on-device) (P7)

**Decision**: Ship `PrivacyInfo.xcprivacy` with `NSPrivacyTracking=false` and empty
`NSPrivacyCollectedDataTypes` — the app has no backend and transmits nothing; Health/Photos are read,
processed, and written back entirely on-device, so there is no *collected* (off-device) data to
declare. Declared the two required-reason APIs actually used: file timestamps (C617.1 — app's own temp
files via `FeedbackStore`/`ReelExporter`) and UserDefaults (CA92.1 — the onboarding flag). App icon
scaffolded as a single 1024×1024 asset-catalog slot (`ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`);
the actual `AppIcon.png` art + TestFlight upload are deferred (no signing/art in this environment).
Display name pinned in Info.plist + `INFOPLIST_KEY_CFBundleDisplayName`.
**Rules out**: declaring data collection we don't do; shipping without a privacy manifest.

## [2026-05-31] P1 device build is the user's step — runbook authored, not executed

**Decision**: Added `pdd/prompts/features/01-ios-device-build-and-run.md` + `ios/App/RUNBOOK-device.md`.
P1 (first device run + first `highlight-feedback.jsonl`) is **not completable headless** — it needs the
user's Mac + paired Apple Watch with real workouts + a physical iPhone (HealthKit/Photos are device-only).
**Rules out**: claiming on-device runtime is verified. It is the one remaining unproven layer; the
runbook is the path to proving it.

## [2026-05-30] Pin/order are app composition state, NOT fields on the engine `Highlight` (P4)

**Decision**: Finishing the feedback loop (prompt `04-engine-finish-feedback-loop.md`) added **pin /
reorder / restore** to the reel editor. Pin and manual order are passed *into*
`ReelPlanner.plan(highlights:media:pinnedIds:order:)` as composition inputs — they are **not** stored
on the `Highlight` struct. The PLAN's earlier wording ("add `pinned` to `Highlight`") is superseded by
this cleaner split.
**Why**: `Highlight` is the algorithm's *output*; the engine never pins or reorders. Keeping edit
state out of the output type preserves "engine produces, app composes," keeps `Highlight` immutable,
and leaves every existing call site/test unchanged (the new planner args default to empty/nil). Pinned
highlights are **budget-exempt** (always included, even over `targetDuration`) because a pin is an
explicit user choice; the canonical `Highlight.pinned` field maps from the app's `pinnedIds` when the
on-device store is eventually built.
**Training data**: pin emits `.pinned` (strong positive), reorder emits `.reordered` — previously
modeled but never fired. The loop now captures them. Verified: engine pin/order logic is unit-tested
(18 tests pass); the UI wiring type-checks vs iOS 18 but is **not** device-run yet.
**Deferred (tracked for P4b/Phase 2)**: `added` (adding a moment the engine missed) — needs a
media/time picker UI; and **pins-survive-regenerate** — regenerate re-runs the engine with fresh ids,
so pins are per-generation for now.
**Rules out**: mutating engine output to carry UI state; treating a type-check as a device run.

## [2026-05-30] PDD initialized in this repo

**Decision**: Add a local `pdd/` layer (context + prompts + evals) to `snappet-mobile`, mirroring the
web repo's structure. The web repo stays the *product brain* (research #60, cross-platform PLAN,
canonical Snappet Core schema); this layer holds the **iOS-implementation** context and the prompt
chain that drives the code here.
**Why**: the codebase had outrun its written context (a working MVP, a finished spike) with no local
PDD scaffolding. Future prompts need iOS-specific conventions and a reality-based project snapshot
without round-tripping to the web repo every time.
**Rules out**: duplicating/forking the canonical schema or research here — we *reference* and mirror
only the parts already implemented; the source of truth stays in the web repo.

## [2026-05-30] v1 reads COMPLETED workouts from HealthKit (post-hoc), not a live watchOS session

**Decision**: The MVP reads already-synced `HKWorkout` + its HR series after the fact, rather than
running a live `HKWorkoutSession`/`HKLiveWorkoutBuilder` on a watchOS companion.
**Why**: the post-workout series is the *authoritative* HR the research recommends for highlight
detection (#60 §3), and it makes v1 runnable **today** against the user's existing Apple Watch
workouts — no watch app to build/install. Live in-session capture is a later phase (0d / Phase 2).
**Rules out**: live in-session HR UI and below-iOS-26 live relay *for v1*. Don't add a watchOS target
to ship the MVP.

## [2026-05-30] Algorithm lives in a platform-free SPM package (`HighlightEngine`)

**Decision**: All selection/scoring/planning logic is a pure-Swift package with zero platform
dependencies; the app talks to it only through plain value types.
**Why**: testability (`swift test`, no device), portability (reuse on watchOS, later Android via port
or shared spec), and a single swap point for the algorithm. The spike concluded the real winner is
probably a *fusion*, so the selector must be pluggable from day one.
**Rules out**: importing HealthKit/AVFoundation/UIKit into the engine; hardwiring HR-only selection.

## [2026-05-30] Selector is a protocol; HR-only is just today's default

**Decision**: `HighlightSelector` is a protocol (`score(at:…)` + a shared `select` pipeline doing
candidate-enumeration / NMS / padding / high-low split). Implementations: `HRHighlightSelector`
(default), `SceneHighlightSelector` (stub, returns 0 until a real vision pipeline exists),
`FusionSelector` (weighted blend, `hrLeaning` = 0.7 HR / 0.3 scene).
**Why**: the Phase-0a spike predicts a fusion beats HR-alone on real data (`RESULTS.md`). Shipping the
fusion path as real-but-inert means the day a vision selector exists, the upgrade is one line in
`AppModel.engine` — no UI/pipeline change.
**Rules out**: baking HR assumptions into the pipeline; a fusion that can't reduce to HR-only (a test
guards that it does when the scene signal is 0).

## [2026-05-30] Ship a best-guess engine now to harvest training data (the feedback loop)

**Decision**: Every reel logs what the engine proposed vs what the user kept/removed/regenerated/
exported, as JSONL on device (`FeedbackStore` → `highlight-feedback.jsonl`), attributed by selector
name + `HighlightConfig.fingerprint`.
**Why**: the spike is NEEDS-REAL-DATA; replaying real feedback offline is how we tune `HighlightConfig`,
learn the HR-vs-content weighting, and turn the synthetic verdict into a data-driven GO. Using the app
produces the dataset that optimizes the app.
**Rules out**: tuning the config from intuition; sending feedback off device (stays local; export only
with consent).
**Open**: the edit UI only fires `shown/kept/removed/regenerated/exported`. The stronger signals
(`pinned`, `added`, `reordered`) are modeled but not yet wired — closing that gap is a Phase-1 finish task.

## [2026-05-30] Auto-find media by capture-time window, with a ±90 s padding guess

**Decision**: `PhotoLibraryService` fetches `PHAsset`s whose `creationDate` falls within the workout
interval ± 90 s, mapping each to a workout-relative offset.
**Why**: "minimize manual work" is the core magic (#60 §A) — the app finds your clips, you don't pick
them. The 90 s grace pads for clock drift between the camera and the HR source.
**Rules out**: a manual-first picker as the default path (it's the *fallback* for `.limited` access).
**Open / unvalidated**: the 90 s number and the whole-clip-vs-clip-internal mapping are a guess until
the **Phase-0b time-sync spike** (`42-native-00b…`) measures real drift. Treat as provisional.

## [2026-05-30] Reel export is on-device AVFoundation; photos are skipped in v0.1

**Decision**: `ReelExporter` turns the platform-free `ReelPlan` into an `AVMutableComposition` and
exports `.mp4` via the modern async `AVAssetExportSession.export(to:as:)`. Video segments only;
photo highlights are dropped from the stitch.
**Why**: fully on-device (privacy, no backend); videos are the core of a reel. The async export API
avoids a continuation/data-race under Swift 6.
**Rules out**: any server-side rendering.
**Open**: photo highlights need a Ken-Burns still render (`photoStill` seconds) — deferred from v0.1.

## [2026-05-30] "Type-checks" ≠ "runs" — be precise about verification

**Decision**: We state exactly what's proven: `HighlightEngine` builds + 14 tests pass; the whole app
**type-checks** against the iOS 18 SDK (Swift 6, 0 warnings). A full `xcodebuild` link/bundle and a
device run are **not** done in this environment (no simulator runtime; HealthKit/Photos need a device).
**Why**: a type-check caught the real `Sendable`/`AVAssetExportSession` bugs, but it does not prove
runtime behavior. Overclaiming "verified" would mislead.
**Rules out**: reporting device-only features as working off a type-check. Next real verification =
`xcodegen generate && open` on a Mac with a device/simulator runtime.

## [2026-05-31] Workout tracker is a separate suite app, not the "Workout" id

**Decision**: The web suite's `workout` app (gym/strength tracker) ships as a new
`Features/WorkoutTracker/` module with id `workout-log`, title "Workout" — alongside, not replacing,
the flagship "Workout Reels" (id `workout`). Catalog (873 exercises, Free Exercise DB) is **bundled**
as a resource and loaded offline; remote exercise photos are **dropped** in favour of category SF
Symbols. Routine/session exercise lists are stored as Codable composites on the `@Model` (loaded and
edited whole) rather than SwiftData relationships. A **top segmented control** drives the 5 sections.
**Why**: the two apps are genuinely different products (HR reels vs. set logging); reusing the id
would collide. Bundling keeps the app on-device-only (no catalog fetch); photos are large + remote
and add little on a phone. Composite storage matches the web app's single-object shape and keeps the
top-level schema simple. A bottom tab bar would collide with the suite's own Home/Apps tab bar.
**Rules out**: a network-fetched catalog; per-set SwiftData relationship rows; a nested bottom TabView.
**Verified**: `xcodebuild` BUILD SUCCEEDED (iPhone 17 Pro sim); app installs + launches into the
module; dashboard renders with the 15 starters seeded; Browse decodes all 873 exercises. This module
has **no device-only dependencies** (no HealthKit/Photos), so the sim run exercises it for real —
unlike Workout Reels. Engine tests unchanged (18/18).

## [2026-05-31] Journal tags via additive SwiftData migration

**Decision**: Add `var tags: [String] = []` to the existing `JournalEntry` `@Model` rather than a
new tag entity or relationship. Tags are normalized at the boundary (`JournalEntry.normalizeTags`:
trim, lowercase, drop empties, de-dupe preserving order). `SnappetSchema.models` is **unchanged**
(the type is already registered — only a stored property is added). Search filters live in a
`filteredEntries` computed property on `JournalRootView` (title/body/any-tag, case-insensitive) via
`.searchable`; the editor commits chips on comma/return and shows removable chips.
**Why**: an additive property with a default triggers SwiftData's **lightweight migration**, so
pre-existing entries (no tags) load without wiping the store — no versioned `SchemaMigrationPlan`
needed. A `[String]` on the model is simpler than a tag entity for free-form, per-entry labels and
keeps `#Predicate`/in-memory filtering trivial. The editor stays a pushed destination (not a nested
`NavigationStack`).
**Rules out**: a destructive migration; a separate Tag `@Model`/relationship; editing existing
`JournalEntry` fields or `SnappetSchema.models`.
**Verified**: `xcodegen generate` + `xcodebuild build-for-testing` (iPhone 17 Pro sim, Swift 6) →
`** TEST BUILD SUCCEEDED **`, 0 Journal warnings. `JournalUITests` compiles. The tag+search flow is
asserted in UI tests but not yet executed on the sim in this pass (build-for-testing only).

## [2026-05-31] Budget `MonthScope` generalised to an arbitrary selected month

**Decision**: `MonthScope` changed from a stateless `enum` of `static` helpers pinned to `.now`
(current calendar month) into a small `Equatable`/`Sendable` value type anchored on a `Date`'s month:
`MonthScope(anchor:)` with instance `contains(_:)`, `start`/`end`, `previous()`/`next()`, `isCurrent`,
and a `label`. The current month is just `MonthScope()`. `BudgetRootView` holds the selected month in
`@State` and a prev/next header steps it, so the summary tiles, per-category progress, and the
spend-by-category donut all reflect the chosen month (backdated transactions appear when you step
back). "Next" is disabled once `isCurrent`. Per-category transactions are a **pushed** screen
(`BudgetCategoryTransactionsView`) where a row opens `AddTransactionView` in edit mode (optional
`transaction:`); the 6-month bar chart lives in `BudgetTrendsView` with aggregation in a pure
`SpendTrend.monthlyTotals` helper. No new `@Model` (reuses `BudgetCategory`/`BudgetTransaction`);
category delete still cascades its transactions by `categoryID`.
**Why**: the data already spans months (transactions carry a backdated `date`) — only the UI was
pinned to "now". A value type makes month stepping a one-liner and keeps the scope testable.
**Rules out**: the old `MonthScope.contains(_:now:)` static call sites (all migrated).
**Verified**: `xcodebuild build-for-testing` (iPhone 17 Pro sim) — TEST BUILD SUCCEEDED; new
`BudgetUITests` compiles into the UI-test bundle. (Live run deferred to the merge pass.)

## [2026-05-31] Split Expenses: manual settlements as a flagged ExpenseRecord

**Decision**: A manual settlement ("X paid Y back") is stored as a normal `ExpenseRecord` with a new
additive flag `var isSettlement: Bool = false` (lightweight migration via the default), `payer = X`,
`participants = [Y]` (the lone recipient), and `amount`. It is **not** split: the balance math in
`SettleUp.balances` treats `isSettlement` records as a direct transfer — `+amount` to the payer's net,
`-amount` to the recipient's net — so recording a settlement equal to a suggested transfer drives that
pair's balances to zero and the greedy plan converges. Editing reuses the existing sheets:
`NewExpenseSheet`/`NewGroupSheet` take an optional model and update it in place; new
`RecordSettlementSheet` inserts the settlement. **Why**: a flagged record keeps one flat model and one
fetch/predicate path, needs no schema/`SnappetSchema.models` change, and feeds the same balance pass —
no second store, no parallel ledger. **Rules out**: a separate `Settlement` @Model; mutating the
greedy algorithm (kept as-is). Dropping a participant who appears on a record warns before saving but
is allowed (past entries keep their names). **Verified**: `xcodebuild build-for-testing` TEST BUILD
SUCCEEDED (iPhone 17 Pro sim, 0 warnings); `ExpenseUITests` compiles. Live run deferred to the merge pass.

## 2026-05-31 — Tip gains persistence (first `@Model`) + editable presets & round-up

**Decision**: Tip — previously `@AppStorage`-only — gets its first persisted model,
`TipCalculation` (`bill`, `tipPct`, `people`, `tipAmount`, `total`, `date`) in
`Features/Tip/TipModels.swift`, registered as one appended line in `SnappetSchema.models`. Each
committed calculation (bill-field commit) both logs a `UsageRecord` (unchanged) and inserts a
`TipCalculation`; `TipHistoryView` lists them newest-first with swipe-delete + clear-all, pushed onto
the shared `SuiteRouter` path (no nested `NavigationStack`). The four preset percentages move from a
hard-coded array to four `@AppStorage` keys (`tip.preset.0…3`), edited via a sheet of steppers. A
`tip.roundUp` toggle rounds the grand total up to the nearest whole currency unit and back-computes
the effective tip so the per-person split stays consistent. **Why**: Tip was the only mini-app
without history; storing a flat snapshot per calc matches the suite's other flat `@Model`s and keeps
per-app `#Predicate` queries trivial. Four discrete `@AppStorage` keys avoid comma-decoding and bind
each stepper directly. **Rules out**: comma-encoded preset string; SwiftData relationships;
recomputing per-person from raw (pre-round-up) total. **Verified**: `xcodebuild build-for-testing`
TEST BUILD SUCCEEDED (iPhone 17 Pro sim); `TipUITests` compiles (history + preset-edit flow).

## 2026-06-03 — Kilter "Connect board" UX: timeout watchdog + name-based discovery (fix "stuck connecting")

**Decision**: `KilterBoardController` (iOS + Android mirror) gets three changes that together fix the
board getting wedged on "Connecting…". **(1) Discover by name, not service UUID.** Aurora-family
boards (Kilter/Tension/…) advertise a local name but generally do **not** put their primary service
UUID in the advertisement, so the old `scanForPeripherals(withServices:)` / `ScanFilter.setServiceUuid`
never produced a `didDiscover` and the scan ran forever. We now scan unfiltered and match in a pure,
unit-tested predicate `isLikelyBoard(name:advertisedServiceUUIDs:)` (name contains kilter/aurora/
tension/grasshopper/decoy/soill, or the advertised services contain our UUID). **(2) Timeout
watchdog.** CoreBluetooth's `connect(_:)` (and Android's `connectGatt`) never time out, so a missing,
asleep, or wrong-GATT board hung the UI silently. A 12 s watchdog (Swift `Task`/`Task.sleep`; Android
`Handler.postDelayed`) covers scan, connect, **and** service/characteristic discovery — on expiry it
tears down the half-open connection and moves to `.failed(message)`. **(3) Distinct states + escape
hatch.** Added `bluetoothOff` and `unauthorized` (was all folded into `unsupported`, which hid the
whole section) and a `failed(String)` message; added `cancel()` so an in-flight attempt always has a
Cancel affordance. The detail view now shows a spinner + Cancel while busy, a message + "Try again" on
failure, an "Open Settings" deep link when permission is denied, and a Bluetooth-off note —
`unsupported` (no radio / simulator) still hides the section. **Why**: the radio API gives no
completion guarantee, so the controller must own its own deadlines and the UI must always offer a way
out. Keeping discovery a pure function lets it run in `SnappetTests` (`KilterBoardMatchTests`) with no
radio. **Rules out**: filtering the scan by service UUID; a single `unsupported` catch-all; trapping
the user with no cancel. **Verified**: pure matcher unit-tested (iOS `KilterBoardMatchTests`). The
live BLE path stays **device-unverified** per the repo's device-only rule — `xcodebuild`/Gradle build
+ on-board validation deferred to a macOS/Android run (this change was authored on Linux/cloud).

## 2026-06-05 — All development goes through the PDD layer (standing process decision)

**Decision**: Every change to Snappet Mobile — features, fixes, spikes — is driven through this
repo's **Prompt-Driven Development** layer (`pdd/`), per the user's standing instruction. Concretely:
author/commit a feature prompt from `pdd/prompts/templates/feature-prompt.md` (one prompt = one job =
one PR) **before/with** the implementation; keep `pdd/context/` (project / conventions / decisions /
schema) true to reality in the same change; and record any non-obvious choice in this file the same
day. The committed prompt is part of the codebase and ships alongside the output it produced. **Why**:
the prompt is the spec and the review surface; without it, intent and rationale drift out of the repo.
**Rules out**: landing code with no committed prompt; deferring the decisions/context update to "later".
Also mirrored as a standing instruction in `CLAUDE.md`.

## 2026-06-05 — Kilter Board UX pass: adopt system-connected board, swipe-to-browse, QR climb share

**Decision**: Three user-reported UX gaps in the Kilter mini-app, all authored under the PDD prompt
`pdd/prompts/features/kilter-board/UX-connection-swipe-qr.md`.
**(1) Connection — adopt a system-connected board.** `KilterBoardController.connect()` now runs
`beginConnect()`, which first tries `retrieveConnectedPeripherals(withServices:[serviceUUID])` and, if a
board is already connected at the **system** level (paired in Settings, or held by the official
Aurora/Kilter app), connects to it directly via a shared `connect(to:)`; only if none is found does it
fall back to the name-matched scan. Such a board has **stopped advertising**, so the scan-only path
could never re-discover it — the reported "won't connect, but it connects in the Kilter app" case, after
which our flow never reached `.connected` and so never offered illumination. **(2) Auto-light.** When a
board is connected, the detail view illuminates the on-screen holds automatically — on connect
(`.onChange(of:board.isConnected)`) and on each swipe (end of `load()`) — keeping the manual "Light up
this climb" button for a re-send. **(3) Swipe-to-browse.** `KilterClimbDetailView` takes the browsed
list's ordered uuids (`siblings`, passed from `KilterRootView` at push time — no `NavigationPath`
bloat) and tracks a `currentUUID`; a horizontal `DragGesture` + chevrons + a "n / total" pill move
through it, reloading via `.task(id:)` without growing the nav stack. **(4) QR share.** A pure
`KilterClimbLink` codec (`snappet://kilter/climb/<uuid>?angle=<n>`) backs `KilterShareView` (CoreImage
QR + `ShareLink`) and `KilterScannerView` (`AVCaptureMetadataOutput`, reached from the catalog's More
menu); a scanned link pushes the climb. **Offline by design** — both phones ship the same read-only
catalog, so a `climb_uuid` resolves locally with no account/network. **Scope (with user)**: in-app
scanner **only** this pass — no `snappet://` URL scheme / `onOpenURL` cross-app deep link yet.
**Why**: `retrieveConnectedPeripherals` is the canonical CoreBluetooth fix for "another app/Settings
holds the peripheral"; keeping the share payload a pure value type keeps the camera/CoreImage edges
thin and the codec unit-testable. **Rules out**: a scan-only connect path; carrying the sibling list
inside the route value; a networked share. **Verified**: `KilterDeepLinkTests` covers the codec
round-trip + foreign-code rejection (no device). The BLE adopt path and the camera path stay
**device-unverified** per the device-only rule — `xcodebuild` + a real board/camera run is deferred to
macOS (authored on Linux/cloud). Android mirror is a follow-up.

## 2026-06-05 — Kilter rich session: HR + per-climb timing + media reel + Live Activity (workout parity)

**Decision**: Bring the WorkoutTracker's live-session toolkit to a Kilter board session, in one PR
(prompt `pdd/prompts/features/18-ios-kilter-rich-session.md`), by **reusing** rather than rebuilding.
**(1) Decouple the metrics layer.** The sources only read `startedAt` + an `HKWorkoutActivityType` from a
`WorkoutSession`, so I lifted those into a tiny `LiveMetricsContext` and changed the `MetricsSource`
protocol's `start(for:)` → `start(_:)`. `LiveMetricsCoordinator` keeps a `start(for:sport:category:)`
**convenience overload** (building the context via `WorkoutActivityMapping`), so the two workout call
sites — and the existing test — don't churn; the only internal change is the coordinator forwarding
`active.start(context)`. `MetricsSource.swift`/`LiveMetricsCoordinator.swift` gain `import HealthKit`
(`HKWorkoutActivityType` is a plain enum) — the engine stays platform-free. **(2) Separate Live Activity
contract.** A new `KilterActivityAttributes` (board + current-climb/grade/count/angle/HR) rather than
overloading the exercise/set-shaped `WorkoutActivityAttributes`, with a dedicated
`KilterLiveActivityController` + `KilterLiveActivity` widget, so the workout activity path is untouched.
**(3) Reuse `SessionMedia`.** It's already keyed on a bare `UUID`; Kilter rows set `sessionID =
KilterSession.id` and one new optional `assignedClimbUUID` (clip→climb), with the workout-only
exercise/set fields left nil. **(4) Additive models, no new tables.** `KilterSession.hrSeries` is the same
inlined `[HRPoint]` composite the workout uses (reused, not redefined); `KilterLogEntry` gains
`startedAt`/`endedAt`/`attemptTimestamps`; all defaulted → SwiftData lightweight migration,
`SnappetSchema.models` unchanged. **(5) Pure cores.** `KilterSessionStats` (timing/rest/pyramid/sends-per-
hour over plain-value `KilterClimbLog`s), `KilterWorkoutBuilder` + `KilterMediaAssignment`
(`KilterSession`+media → `HighlightEngine.Workout(.climbing)`, clip-offset→climb window), and
`KilterLiveSnapshot.shouldPush` are all device-free and unit-tested. The reel reuses
`engine.generate(for:)` (which auto-selects the `.climbing` preset by `workout.activity`) + `ReelExporter`.
**Why**: the coupling was shallow and the toolkit already on-device; the cheapest correct path was a
seam (`LiveMetricsContext`) + reuse, not a parallel stack. **Rules out**: a Kilter-specific HR transport;
a `KilterSessionMedia` model; overloading `WorkoutActivityAttributes`; widening `WorkoutSession` into a
polymorphic session. **Verified**: `xcodebuild test` green (266 tests incl. the new
`KilterSessionStatsTests` / `KilterWorkoutBuilderTests` / `KilterLiveSnapshotTests` + a `LiveMetricsContext`
rebase test); `HighlightEngine` `swift test` unchanged (18). **Device-unverified** per the device-only
rule: the live HR stream (watch + BLE band), the Live Activity rendering, board connect auto-session-open,
and Photos auto-discovery + reel export — deferred to a real board + watch/HR band on macOS.

## 2026-06-05 — Kilter session media: per-climb galleries, full-length uncapped reels, studio parity

**Decision**: Three user-requested follow-ups on the Kilter rich session, again by **reuse, not rebuild**.
**(1) Full-length, uncapped reels — for *both* workout and Kilter (user's call).** Added
`HighlightConfig.fullClips` (default `false`, so the 18 existing engine tests are untouched) + a
`.fullLength()` copy-helper; when set, `HighlightSelector.select` still uses HR to pick *which* media to
feature (NMS + `maxHighlights`) but emits each as a **full-length** clip (`clipStart = media.startOffset`,
`clipEnd = media.endOffset`) and **collapses repeated moments within one media** to a single segment (so a
video with several peaks yields one full clip, not duplicates). `ReelPlanner.targetDuration` became
`Double?` — `nil` = no length cap. `AppModel.engine` now uses `ReelPlanner(targetDuration: nil)`, and the
single reel call site (`ReelViewModel.generate`) passes `.preset(for: activity).fullLength()`. So the user's
"no length limit" applies everywhere through two app-layer knobs; the engine defaults (and their tests) are
unchanged. **(2) Per-climb media galleries.** `KilterSessionDetailView`'s timeline now renders a horizontal
strip of each climb's clips (filtered by `SessionMedia.assignedClimbUUID`, deduped to the climb's first
timeline row) + an "Unassigned" strip, reusing the already-public `SessionMediaThumb`. A "Move to climb…"
menu reassigns a clip (`assignedClimbUUID` + `assignmentSource`), mirroring the workout reassign. Grouping is
a pure generic helper `KilterMediaGrouping` (unit-tested). **(3) Full editing parity.** The workout
components are domain-agnostic, so Kilter reuses them as-is: tapping a clip opens `ClipEditorView(media:)`
(trim/speed/crop/text/HR-overlay/mute); "Open studio" find-or-creates a `StudioProject(sessionID:
kilterSession.id, …)` and presents `StudioEditorView`; and the reel now goes through the **shared**
`ReelView` (pin/remove/reorder/preview/export) instead of a one-shot export. To make `ReelView` source-
agnostic, `ReelViewModel`'s hard `WorkoutSummary` dependency became a small `ReelSource { id, activity,
title, start, makeWorkout(model, manualMedia) }` — `makeWorkout` takes the `AppModel` as a *parameter* so a
source can be built in a `View.init` (no environment yet); `ReelView(summary:)`/`ReelViewModel(summary:)`
stay as back-compat shims (workout call sites unchanged), and Kilter passes `.kilterSession(session, media:)`.
**Why**: every editor/reel surface is keyed by `SessionMedia`/`StudioProject`/`Highlight[]` with no workout
coupling, so a source seam + reuse beats a parallel Kilter studio. **Rules out**: a Kilter-only reel config
(user chose "both"); duplicating the reel/clip/studio UI; trimming clips by default. **Verified**:
`HighlightEngine` `swift test` 21/21 (3 new: full-clip dedupe + full-length window + nil-budget keeps-all);
`xcodebuild test` 267/267 (new `KilterMediaGrouping` + `ReelSource` coverage); clean build of app + widget +
watch. **Device-unverified**: the clip-editor/studio/reel *render + export* on real footage (needs a device
with clips); the per-climb gallery wiring is type-checked + the grouping is unit-tested.

**Self-review hardening (same day, high-effort multi-agent review of the diff).** Fixed: **(a)** logging
now keeps **one `KilterLogEntry` per climb per session** — repeated logs (attempts, then a send) accumulate
onto a single row (total tries + timestamps; a send is sticky) instead of inserting duplicate rows that
double-counted the climb in the stats/timeline. **(b)** `beginClimb` re-arms when a prior send disarmed the
active climb (and `log` re-arms too), so time-on-climb isn't lost on a re-log. **(c)** `KilterSessionManager`
gained a `didStartMetrics` guard so `end()` only flushes/stops the HR source **it** started — a Kilter
session that opened while a WorkoutTracker workout was running can no longer steal that workout's HR buffer or
stop its source; and `metricsSourceRaw` is now stamped at end **from actually-captured samples** (and shown
as "via Apple Watch / Heart-rate band" in the summary) instead of a misleading default. **(d)** the Kilter
`ReelSource` honors the limited-Photos "Select clips" picks (was a dead no-op) and snapshots Sendable values
(not the `@Model`) to satisfy Swift-6 isolation. **(e)** reused `WorkoutLiveSnapshot.elapsedString` instead
of a duplicate duration formatter. Deferred (noted, not blocking): the `KilterLiveActivityController` /
`KilterActivityAttributes` / `KilterLiveActivity` trio duplicates the workout Live-Activity stack — a generic
parameterized over the attributes type would collapse it, but the split keeps the flagship path untouched.

## 2026-06-05 — Kilter clip editing: per-clip / per-climb scope (shared project), Climb panel

**Decision**: Give Kilter per-clip and per-climb editing scopes **without** a second project or a separate
single-clip editor — one session `StudioProject` + a **visibility filter** is the whole mechanism.
`StudioEditorViewModel` gained `visibleClipMediaIDs: Set<UUID>?` (default `nil` = workout's whole-project
behavior, so the studio is untouched); a pure `StudioGeometry.filterByMedia(_:to:)` restricts the *display,
timeline, preview, and export* to the clips backed by those `SessionMedia.id`s, while the **edit path is
left alone** — `StudioProjectEditor` still mutates the full `snapshot.clips` by clip id. That asymmetry is
the point: a per-clip trim writes to the shared project, so it reappears in "Edit all" and the session-wide
studio automatically (one source of truth). Preview/export read a `scopedSnapshot` (a filtered value copy of
the snapshot), so **`StudioComposer` and `StudioTimelineView` need no changes** — they render whatever the
VM hands them; transitions whose `afterClipID` points at a hidden clip are simply never matched among the
filtered neighbors (graceful; the 1-clip scope has none). Entry points unify in `KilterSessionDetailView`
through one `ClipStudioPresentation` → a single `fullScreenCover`: tap a clip → `{clip.id}` + its climb;
"Edit all · N" (only when a climb has ≥2 video clips) → that climb's clip ids + climb; bottom "Open studio"
→ `nil` scope, no climb. The new `KilterClipStudio` wraps the scoped `StudioEditorView` with a floating
"Climb ✎" button (shown only when a single climb is known) presenting `KilterClimbPanel`, which resolves the
in-session `KilterLogEntry` (the same `(sessionId, climbUUID)` fetch `existingSessionEntry` uses) + the
catalog climb, shows read-only name/grade/board, and write-through-edits angle / result+tries / a new
`note`, plus per-clip "Move clip to another climb" (`assignedClimbUUID`). **`KilterLogEntry.note: String? =
nil`** is additive/defaulted → lightweight migration (the `attemptTimestamps`/`startedAt` precedent),
`SnappetSchema.models` unchanged. **Why**: scoping as a filtered *view* over a shared model keeps edits in
one place and reuses the entire studio + the foundation's `openStudio` reconcile, instead of forking a
per-clip `ClipEdit` editor or copying clips between projects. **Rules out**: a separate single-clip project;
threading a filter through the composer/timeline (the scoped-snapshot copy makes that unnecessary); a Climb
panel coupled to studio-internal selection (the climb is known from the entry point). **Verified**:
`xcodebuild test` — new `StudioGeometryTests.filterByMedia*` (nil passes through, set keeps only matching
`sessionMediaID`, orphan clips excluded, single-clip scope) + `KilterLogEntryTests` (`note` default/round-
trip/mutate); "Edit all" grouping already covered by `KilterWorkoutBuilderTests`. `HighlightEngine` `swift
test` unchanged. **Device-unverified** per the device-only rule: the scoped preview/export render on real
footage and the Climb-panel edits' on-screen feel — deferred to a device with clips.

**Self-review hardening (same day).** Two follow-ups from reviewing the scope filter: **(a)** the studio's
clip **reorder** is made scope-correct — `moveSelected` was indexing the *scoped* visible list while
`StudioProjectEditor.moveClip` reindexes the *full* project, so a reorder in a scoped editor (with hidden
clips before the window) would have mis-ordered the shared session order. A pure
`StudioGeometry.reorderDestination(id:by:visible:full:)` maps a visible-subset move to the full-list index
(swap with the adjacent *visible* neighbor, hidden clips undisturbed; unscoped it's the plain `index+delta`),
unit-tested. The reorder UI is currently dormant, so this is a latent-bug fix, not a behavior change. **(b)**
An **unassigned** single clip can now be tagged to a climb from inside the scoped editor: `KilterClimbPanel`'s
`climbUUID` became optional (nil ⇒ an "Assign clip to a climb" action only), and `KilterClipStudio` shows the
floating button for any per-clip scope and resolves the climb **live** from the clip's `assignedClimbUUID`
(reading the `@Model` clip) — so assigning upgrades the button/panel to the full Climb panel in place,
without reopening. Previously an unassigned clip's only reassignment path was the gallery long-press menu.

## 2026-06-05 — Studio overlays & grids: climb-name overlay, overlay timeline, per-axis PiP grids; split grade filter (P21)

Four editor/browse improvements (prompt `21-ios-studio-overlays-grids.md`), built on the existing overlay
seams rather than new infrastructure. **(1) Grade filter split** — the Kilter browse bar's one "Grade" chip
(a From+To `Menu`) became **two independent chips** (`kilter.minGrade` / `kilter.maxGrade`) over the same
`gradeScale`, with `.onChange` coupling (set Min above Max ⇒ Max follows, and vice-versa). No model/query
change: state stayed `@AppStorage minGrade/maxGrade` and `KilterCatalog.list` already min/max-swaps. **(2)
Climb-name overlay** reuses **one** `OverlayItem` with a new `Kind.climbName` (not a separate config like
`HROverlayConfig`) — deliberately, so the new overlay timeline + the existing opacity keyframes/drag apply to
it for free; it renders like text but as a lower-third chip (export: `StudioOverlays.climbNameLayer` = a
`CATextLayer` on a rounded background container, time-gated by the same `applyVisibility`; preview: a
`.climbName` chip case). The caption is built by a **pure** `KilterClimbCaption.caption(name·grade·angle[·
by setter])` and the text stays freely editable ("Edit text"); a "Show setter" toggle re-derives it. Climb
metadata is resolved **without the SQLite catalog** for name/grade/angle — from the persisted
`KilterLogEntry` keyed by `(sessionId, climbUUID)` (the clip → `SessionMedia.assignedClimbUUID` lookup) — and
only the **setter** touches `KilterCatalog.shared.climb(uuid)` (nil on the simulator ⇒ caption simply omits
it). **(3) Overlay timeline** — every overlay already had `[startSec, endSec]`, so duration control is a
second lane in `StudioTimelineView` (`OverlayBar`: high-priority body-drag to move the whole window keeping
its length, edge handles to trim) sharing the clip lane's `pps`/offset, committing once on drag-end via the
pure `StudioProjectEditor.setOverlayTimeRange` (clamped, min 0.2s); selection is shared with the bottom
overlay controls. **(4) PiP grids** — PiP went from a single uniform `scale` to optional **per-axis**
`OverlayItem.normalizedWidth/Height` (a `pipSize` accessor falling back to `scale` when nil, so old
snapshots decode and render **unchanged**), enabling true split-screen cells and free corner resize. A new
`ClipEditGeometry.pipRect(center:size:canvas:)` overload (the `scale` one delegates to it) feeds both the
preview frame and `StudioComposer.insertPiPTrack`. A **pure** `StudioGridLayout` provides collage `Preset`
cells (1×2 / 2×1 / 2×2 / 1×3 / 3×1) and `snap(center:size:)` → alignment guides (rule-of-thirds / centre /
edges); `StudioOverlayCanvas` gains corner-resize handles (opposite corner fixed) + live guide drawing, and
a "Grid" tool sheet exposes the presets + a snap toggle. **Why**: extending `OverlayItem` (one new kind, two
optional fields) keeps the timeline/keyframe/undo machinery uniform across text/climb-name/PiP and avoids a
parallel config type or a forked editor; per-axis size is the minimal model change that satisfies both
"split-screen grids" and "corner resize". **Rules out**: a dedicated `ClimbNameOverlayConfig`; baking the
caption into a fixed string (it stays editable); a normalized `CGRect` field on `OverlayItem` (two optional
scalars decode more cleanly for SwiftData lightweight migration). **Verified**: new pure unit tests —
`KilterClimbCaptionTests` (setter on/off/missing, empty name/grade/zero-angle), `StudioGridLayoutTests`
(preset cells tile the canvas, `frames(count:)` caps at capacity, snap within/outside threshold + edge
snap), `ClipEditGeometryTests` (per-axis `pipRect`), `StudioProjectEditorTests`
(`setOverlayContent`/`setOverlayTimeRange`/`setOverlayFrame`/`applyPiPGrid`). **Device-unverified** per the
device-only rule: the climb-name **export** layer, PiP collage/corner-resize on real footage, and the
overlay-lane gesture feel — deferred to a device with clips + a logged Kilter session.

## 2026-06-05 — Studio overlay/PiP follow-up: live-resize, text sizing, base-video collage cell, flicker fix (P21)

Device pass on P21 surfaced four issues; fixes built on the same seams. **(1) Text/climb-name couldn't be
resized** — the export AND preview already honoured `OverlayItem.scale` for font size, but no control ever
set it for the Core-Animation kinds (handles were `.video`-only). Fix: a **Size slider** in the overlay
controls bar + **pinch-to-scale** on the canvas (`TextOverlayChip`), both → `setOverlayScale`, which is now
overlay-aware in the VM (text = `editOverlaysOnly`, no player rebuild) and whose clamp **widened `0.1…1` →
`0.2…6`** so text can grow past 1× (the old clamp was sized for a PiP frame fraction; PiP sizing moved to the
per-axis `setOverlayFrame` in P21, so widening is safe). **(2) PiP frame "didn't match the bounding box"** —
corner-resize only wrote the model on drag-END (`commitResize(ended:false)` updated only the snap guides), so
the white outline + the composited PiP stayed put while the handle moved, then jumped on release. Fix: a
shared **`ResizableFrame`** view (used by BOTH the PiP cell and the new base-video cell) tracks the gesture
**live** via `liveResize` state — the outline and all four handles recompute from the in-progress
corner/pinch each frame; the model is still written once on end. Handles dropped their local `.offset` (the
parent repositions them from the live frame, so the dragged dot sits under the finger). **(3) "Very
flickery"** — every PiP edit ran `rebuildPreview`, which tore down the whole `AVPlayer` AND re-resolved every
PHAsset→AVAsset through `PHImageManager` (slow/async) → a black flash + reload per nudge. Fix: an **actor
`AssetCache`** in `StudioComposer` memoizes resolution for the session, and `rebuildPreview` now **reuses the
player** (`replaceCurrentItem`) instead of constructing a new `AVPlayer` (no layer detach/reattach), keeps
playing across a live edit, and a **generation token** drops a stale rebuild whose async composition returns
after a newer one. **(4) Couldn't resize the original video** — the main track always aspect-filled the full
canvas. Added an optional **`StudioProject.baseFrame: StudioFrameRect?`** (normalized centre+size, nil =
legacy full-frame, migration-safe additive `@Model` property like `hrOverlay`); the composer's new
`mainClipTransform` aspect-fills the main track into that sub-rect (same flipped-Y / `pipRect` convention as a
PiP, so base + PiP cells align; the canvas `background` shows behind it) on **both** the single-track and
transition paths. On the canvas it's a draggable "Main" `ResizableFrame`; the **Grid tool** gained a "Resize
the main video" toggle (`toggleBaseFrame`, default = a centred half-cell) and the Grid button is no longer
PiP-gated. **Why a frame on the project, not a per-clip field or a `.baseVideo` overlay kind**: framing is a
canvas-level layout (all clips share it), and a new overlay kind would ripple through every overlay switch +
the export tool; one optional struct is the minimal, migration-safe change and reuses the PiP geometry.
**Rules out**: per-clip base frames; crop-WITH-base-frame (a framed main track ignores per-clip crop — a
follow-up); base video as a grid-preset cell (presets stay PiP-only). **Verified**: builds clean + full suite
green on the simulator (298 unit tests) — `setBaseFrame`/`clearBaseFrame` clamp+toggle, `StudioFrameRect.isFull`,
the widened `setOverlayScale` clamp. **Device-unverified** (device-only rule): the actual flicker-free feel,
base-frame **export** on real footage, and pinch/Size sizing of the climb-name in the rendered file.

## 2026-06-05 — PiP/base placement: top-left render space + aspect-FIT + source-aspect default (P21)

A device screenshot showed the composited PiP **offset down** from its editor outline AND **wider than
the frame**. Root-caused to two composer bugs in `insertPiPTrack` / `mainClipTransform`. **(1) Wrong Y
origin** — the PiP frame flipped Y (`1 - normalizedY`) assuming the `AVMutableVideoCompositionLayer
Instruction` render space is bottom-left (the convention the Core-Animation OVERLAY tool genuinely uses,
`layerPoint`). But the layer-INSTRUCTION space is **top-left** — proven by the device-verified
`cropTransform` (clip-editor zoom-crop), which targets the same space and does NOT flip. The flip pushed
the PiP down by `(1−2y)·H`, matching the screenshot. Fix: drop the flip, place against `ov.position`
directly (top-left), so the composited PiP lands exactly where the SwiftUI outline shows it. **(2)
Overflow** — `fillTransform` aspect-FILLS (cover), but a layer instruction can't clip its track to a
sub-rect, so the excess spills past the frame onto the rest of the canvas. Fix: a new
`ClipEditGeometry.fitTransform` (aspect-FIT / contain) keeps the whole source inside its frame; PiP and
base both use it. **(3) Square default** — a new PiP defaulted to a `0.4×0.4` (canvas-aspect) frame, so a
non-9:16 source letterboxed inside it (looks misaligned). Fix: `addPiP` sizes the frame to the source's
oriented aspect (`StudioComposer.sourceAspect`, resolved on appear into `sourceAspects`), so
`pipSize.w/pipSize.h = sourceAspect / canvasAspect` and the aspect-fit PiP fills its frame. **Why top-left,
not bottom-left**: the two render spaces (layer-instruction vs the Core-Animation overlay tree) genuinely
differ; the original code conflated them. Matching `cropTransform` (verified) is the reliable tiebreak.
**Why fit, not fill+crop**: precise per-PiP cropping needs a mask layer (custom `AVVideoCompositing`),
deferred; fit is the no-overflow, no-mask choice. **Rules out**: a bottom-left flip for PiP/base; aspect-
fill without a clip; a fixed square PiP default. **Follow-up**: when a user resizes a PiP frame to an
aspect ≠ its source, the video fits within (a small letterbox) — drawing the outline at the exact fitted
rect (needs the source aspect in the canvas) is a further polish. **Verified**: builds clean, full suite
green incl. a new `fitTransform` containment test. **Device-unverified**: that the PiP/base now sit exactly
under the outline in preview AND export.

## 2026-06-07 — Kilter board: size on the climb page, size-accurate render, color-blind hold shapes

Three board-design improvements on the climb screen, one PR (iOS + Android mirrored;
`FEAT-board-size-render-and-colorblind-shapes`). **(1) Board size beside Layout** — the physical
board-size preference (`kilter.productSizeId`, added by `FIX-board-size-led-mapping`) was only reachable
in Settings and the inline "wrong holds?" escape hatch. It's now an inline **Size chip** on the browse
filter bar (iOS `KilterRootView`, Android `KilterRoot`), shown only when the layout offers >1 size,
bound to the same cached key, **seeded to the layout default on appear and reset when the layout
changes** (the guard Settings already used, lifted into a `syncBoardSize()` / `LaunchedEffect(layoutId)`
so the chip and Settings can't disagree). **(2) The render now tracks the size.** Previously
`boardGeometry(forLayout:)` took the extent + grid from the **whole layout's** hole set and `holds()`
normalized to that same extent, so *every* size of a layout drew an identical schematic — size only
changed which LEDs lit. New `renderHoles(forLayout:sizeId:)` computes the render basis from the holes
**wired for the selected `product_size`** (the `leds` table's hole keys ∩ the layout's placements — that
set *is* the physical board's holes, so a 7×10 ≈ 225 holes reads shorter than a 12×14 ≈ 527). Both
`boardGeometry(forLayout:sizeId:)` and `holds(for:sizeId:)` normalize to that one basis, so the grid +
aspect + lit holds reshape **together**; a hold above a smaller board clamps onto its top edge. `sizeId
0` (the default, for any legacy caller) and a size with no `leds` rows fall back to the whole layout, so
older/hand-rolled catalogs degrade rather than crash. The detail screen recomputes geometry+holds when
the size changes (moved to a top-level `onChange` so it still fires with no board / on the simulator,
where the BLE-gated section is unmounted). **(3) Color-blind hold shapes.** Every lit hold was a circle,
so the route was unreadable without separating the role *hues*. A pure `KilterHoldShape.forRole` now
maps the four roles to the canonical grayscale-distinguishable set — **start = triangle, hand = circle,
finish = square, foot = diamond** — drawn (stroked unlit / filled+glow lit) by `KilterBoardView` /
`KilterBoard` via a shared `holdPath`; colors are kept (shape is a *redundant* channel), the grid dots
stay faint circles, and the detail legend draws the shapes (one `holdPath`, so board + legend can't
drift). **Why the LED hole-set, not `product_sizes.edge_*`:** the real Aurora `product_sizes` carries
explicit visible-rectangle edges that would crop pixel-perfectly, but they aren't in the synthetic
fixture (only `id/name/description`) and adding them would churn all four fixture mirrors' positional
inserts; the `leds` hole-set is authoritative, already loaded for LED mapping, present in fixture + real
catalog, and ≈ the visible rectangle. A future catalog that exposes the edges can swap the basis behind
`renderHoles`. **Why no real board photos:** the user asked to "find Kilter layout photos per
size/layout," but the board backgrounds (`product_sizes_layouts_sets.image_filename`) are copyrighted
Aurora CDN assets and the repo ships **no** Aurora data (#42) — committing them is a licensing + policy
violation — so the schematic was made size-accurate instead (decided with the user). **Why always-on
shapes (not a toggle):** shape is strictly more information with no downside for sighted users (decided
with the user). **Fixture:** the two existing sizes are both "5 x 5" and wire all 25 holes, so they
can't *prove* size-accurate geometry — added a third **5×3 "Test Mini"** size wiring only the bottom
three rows (holes 1–15) to all four mirrors (`build_test_fixture.py` + the regenerated
`kilter-fixture.sqlite3` + Swift/Kotlin `KilterCatalogFixture`); the `[1,2] → [1,2,3]` size assertions
moved with it. **Rules out:** bundling/scraping copyrighted board photos; an on-device photo-fetch path
(network — out of scope, contradicts on-device-only); a size toggle for shapes; `product_sizes.edge_*`
cropping (not in the fixture); per-platform shape mismatch (one `forRole` + one `holdPath` each side,
unit-pinned). **Verified (off-device):** new `KilterHoldShape` mapping test (start→triangle … four
distinct shapes) on both platforms; new `boardGeometry`/`holds` size test (full = 25 holes / aspect 1.0,
mini = 15 / aspect 2.0, sizeId 0 + foreign size → whole layout, a top hold clamps to y 0); the prior
LED-address + `led_color` test stays green; the regenerated binary fixture validates (4 climbs).
**Device-unverified** (visual judgments): that the size-coded schematic + role shapes actually read
better for a color-blind climber on a real screen, and that the absence of a real board photo is
acceptable.

## 2026-06-07 — Kilter: "No matching" tag (climbs.is_nomatch) + a board-size download filter

Two more Kilter additions, iOS + Android mirrored. **(1) Matching rule on the climb screen.** The climb
screen never showed whether a climb forbids **matching hands** on a hold (the Kilter "No matching"
setter rule). We **grounded this in the real downloaded data** (the user's instinct after an earlier
wrong guess): inspecting the 165 MB `kilter.sqlite3` showed a dedicated `climbs.is_nomatch` boolean —
73,864 of 344,504 climbs flagged, and **all** of them also carry "No matching"/"no match" in their
free-text `description` (the column is the precomputed version of the setter note; the `hsm` column is
unrelated — a bitmask). So `KilterClimb` now reads `is_nomatch` (added `description` too), and the detail
screen shows an amber `hand.raised.slash` **"No matching"** chip (else a quiet "Matching") — always on,
so the rule is never ambiguous, mirroring the official app's icon. A pure
`kilterDescriptionForbidsMatching` is the **fallback** for catalogs that predate the column — it matches
the setter note at a **word boundary** (`(^|[^a-z])no[ -]?match(ing)?([^a-z]|$)`) so it reproduces
`is_nomatch` for the standard phrasings without firing inside ordinary words ("piano matched", "casino
match", "no matches found"); the column is authoritative when present. Unit-tested (incl. those
false-positive cases). A review caught the original bare-`contains("no match")` substring leak. **(2) Board-size
download filter.** The user's Board Explorer gained a size filter; we mirror its `buildConditions`
exactly: a size is a box `[edge_left, edge_right, edge_bottom, edge_top]` from `product_sizes` (the real
table carries these edges, e.g. 7×10 = `[28,116,36,156]`, 12×14 = `[0,144,0,180]`), and a climb fits
when `c.edge_left >= ? AND c.edge_right <= ? AND c.edge_bottom >= ? AND c.edge_top <= ?`. `CatalogFilter`
gained `sizeId`/`sizeBox`; `KilterBoardSize` now carries its `box`; the download sheet adds a **Board
size** picker. **[SUPERSEDED the same day — see "Kilter download: board-first" below: the picker now reads
from an EMBEDDED known-Kilter board table and works on a first download; the next paragraph describes the
original, replaced approach.]** **Why the picker reads sizes from the INSTALLED catalog (and hides on a
first-ever download):** pre-download the board's sizes aren't known — the ~80 MB file isn't fetched yet and
the host manifest carries no sizes — and embedding Aurora size ids/boxes would duplicate Aurora data (#42).
Once a catalog exists, its `product_sizes.edge_*` supply the picker + the chosen box; the box is bound
straight into the trim's WHERE. **Why a dedicated column over description-parsing for `is_nomatch`:** the column is
authoritative and cheap; parsing free text is a heuristic — so prefer the column, parse only as a
fallback. **Why both newer columns are PRAGMA-guarded:** `climbs.is_nomatch` and `product_sizes.edge_*`
are absent from older/hand-rolled catalogs (and the validator doesn't require them); detect once on open
and degrade (matching-allowed default / nil box / no size filter) rather than throw. **Fixture:** added
`is_nomatch` (Bravo = no-match, with a "No matching" description) and `product_sizes.edge_*` boxes (sizes
1/2 a tall 0…24 box, size 3 a short top-12 box) across all four mirrors. **Rules out:** an in-app
"fits-your-board" tag (that was a misread of "match" — it means hand-matching, not board fit);
embedding static Kilter sizes for the download picker *(reversed the same day — see "board-first" below;
the static table is now the chosen approach)*; using `hsm` for the match rule. **Verified (off-device):**
new tests — `is_nomatch` read + size-box read (installed reader), the size-fit download filter (tall box
keeps all 4 climbs, short box keeps none → `noCatalogData`), and the pure description detector — on both
platforms; regenerated binary fixture validates. **Device-unverified** (visual judgment): the match chip
+ size-filter UX on a real screen.

## 2026-06-07 — Kilter download: board-first, end-user-friendly (layout + size are the only filters)

The in-app catalog download was a 12-field power-user form (board, layout toggles, angle, grade min/max,
ascents, quality, setter, name, benchmark, listed, single-frame, board size, cap, host) — overwhelming
for someone who just wants climbs for their board. Reshaped around the **one thing an end user knows:
which board do you have.** The download sheet (`KilterCatalogDownloadSheet`, iOS + Android) is now: **Your
board** = a single **layout** pick (Original / Homewall) + a **size** pick; **How many climbs** = a simple
cap (Most popular N / Everything); Download; host URL tucked under **Advanced**. **Layout + size are the
only download filters** — they define your physical board. Everything else (angle / grade / quality /
ascents / setter / name / benchmark) moved to **browse-time** (those controls already exist in the
catalog list + Filters sheet); `listedOnly`/`singleFrameOnly` stay on as silent mobile defaults. The
`CatalogFilter` struct is unchanged (still carries the browse-style fields) — `buildFilter` just stops
*setting* them, so they keep their no-op defaults and the explorer-parity `conditions()` is untouched.
**Why size needs a static table:** the size picker must work on a **first** download, when no catalog is
installed and the ~80 MB file isn't fetched — so the well-known Kilter board sizes (layout → sizes with
their `product_sizes.edge_*` fit boxes) are embedded as `KilterCatalogOptions.boards`, pulled from the
**real** Aurora data (re-inspected the 165 MB dataset: Original 7×10…16×12, Homewall 7×10/8×12/10×10/
10×12; Homewall ships each size under several LED-kit ids → keep one per physical box). This is board
**dimensions** — structural reference like the hardcoded layout ids — **not** climb data, so it's
consistent with #42 (we still ship no climb catalog). The chosen size's box drives the trim
(`c.edge_* ⊆ box`); picking a smaller board really does install fewer climbs. **Why a layout single-pick
(not the old multi-toggle):** a physical board is one layout; "your board" is one choice. **Why keep a
cap:** layout 1 alone has ~228k listed climbs — without a cap the installed file is huge; the cap is a
data-size control, not a climbing filter, so it's framed as "how many climbs." **Rules out:** exposing
the climbing filters at download (they're browse-time); reading sizes from the installed catalog for the
picker (doesn't exist on a first download — the prior approach, now replaced by the static table);
multi-layout downloads. **Verified:** iOS `BUILD SUCCEEDED`, Android `compileDebugKotlin` SUCCESSFUL; no
UI test references the removed controls. **Device-unverified** (visual/UX judgment): that the board-first
flow actually reads as simpler on a real screen.

## 2026-06-07 — Kilter browse: live "N climbs" count + Clear (search feedback)

The catalog browse gave no feedback on how a search/filter narrowed the catalog. Added a **live count
bar** under the filter chips (iOS `KilterRootView`, Android `KilterRoot`): "N climbs" updating with the
filter + search, plus a **Clear** action when a search / Saved / Filters-sheet extra is active (it
resets those but keeps the board/angle/grade context the user set). **Why a dedicated `count(filter)`
(not `list().count`):** the browse `list` is capped (LIMIT 500) for render cost, so its size understates
the true match count; `count` runs the same WHERE as `list` (one `climb_stats` row per climb at the
angle → `COUNT(*)`) with no limit/sort, giving the real number. Saved-mode count is just the filtered
favorites' size (already the full set). **Rules out:** counting via `list().count` (capped); a separate
count query path that could drift from `list`'s WHERE (kept them mirrored). **Verified:** new
`testCountReflectsFilterAndSearch` (iOS) / `countReflectsFilterAndSearch` (Android) over the fixture —
count = 4 at 40°, 2 at 25°, 1 for "Bravo"/grade≥22, and equals the uncapped list size; both platforms
build. **Device-unverified**: the live-update feel on a real screen.

## 2026-06-08 — Feature-rich band data, Phase 1: sensor-contact gating + redline/strain + per-climb effort

Made the fitness-band data we **already capture** richer, without new BLE characteristics, a user HR
profile, or cloud (the on-device-only stance from 2026-06-01 stands). Three bpm-only wins:

**Sensor-contact gating.** The `0x2A37` packet already carries a sensor-contact flag we were
discarding. Added `BLEHeartRateMetricsSource.parseMeasurement` (returns bpm + `contact: Bool?`) and
`contactStatus(flags:)`, keeping `parseHeartRate` as a bpm-only **shim** so the existing parser tests
and any callers stay green (additive, no churn). **The bit decode is the load-bearing subtlety:**
Bluetooth SIG flags **bit 2 (`0x04`) = contact SUPPORTED**, **bit 1 (`0x02`) = contact STATUS** — two
independent bits, *not* a 2-bit enum. We gate on support first (unsupported → `nil`/"unknown", never a
false alarm), then read status. A naive 2-bit decode mis-fires on real straps that set status without
support — and the pre-existing `0x0E` fixture (both bits set) would not have caught it (a planning
adversarial-review catch). `ingest` now **drops** a no-contact reading (off-skin bpm is garbage):
don't append, keep the last good `latestHR`, raise `isContactLost`; the live HR pills show an "adjust
strap" hint. `isContactLost: Bool?` is on `MetricsSource` with a `nil` protocol-extension default, so
only the BLE band implements it and the **watch path stays `nil`**. **Trade-off:** while contact is
lost `latestHR` is frozen, so the Live-Activity `onChange(of: latestHR)` push won't fire — acceptable,
and the orange affordance explains the staleness.

**Redline + strain.** `WorkoutHRStats` gained pure `redlineSeconds` (Z4+Z5 dwell), `redlineFraction`
(guarded to `0`, never NaN), and `edwardsTRIMP` (Σ minutes-in-zone × zone-number) — the figures that
characterize a bursty climbing session. **Anchored to the fixed `defaultMaxHR` (190) until a user HR
profile lands, so these are within-user *trend* numbers, not cross-user or clinical** (Edwards TRIMP
was validated for steady aerobic work; intermittent max-effort climbing inflates it).

**Per-climb effort + recovery.** New pure engine helper `ClimbEffort` (HighlightEngine, swift-test'd)
scores one climb's HR window: peak bpm, peak %HRR (**only** with a real `maxBpm` bound → `nil` today,
the honest bpm-only state), HR rise, time-to-peak, HRR60/30 recovery. **Verified fact:**
`KilterBoardController.climbWindows` ends each window at `endedAt` with **no** `hrLagSec` extension and
also feeds media auto-assignment — so it is left untouched; the HR window is computed separately in
`KilterSessionStats` (from each log's own timestamps) and its **end extended by `HighlightConfig.hrLagSec`**
so the post-effort spike that lands just after `endedAt` is captured. A **zero-lag negative-control
test** guards this (with lag 0 the spike is missed). Effort lives as flat optional fields on
`KilterSessionStats.TimelineItem` (keeps Equatable/Sendable auto-synthesis; not persisted, so no
SwiftData migration). The UI (Redline/Strain tiles + per-climb effort badge / recovery dot) is
additive and gated, so HR-less and watch-path sessions render exactly as before.

**Rules out (this PR):** RR-intervals / HRV, energy parsing, battery/device-info reads, and a user HR
profile — all later phases of the roadmap; vendor SDKs / cloud (Whoop/Body-Battery/Polar-PMD) remain
out (brand lock-in + cloud, contra the on-device-generic-BLE stance). **Verified off-device:**
`swift test` (ClimbEffort math incl. the lag-extension control) + the XCTest suite (contact decode &
ingest-drop, redline/TRIMP, per-climb effort). **Device-unverified** (no band/HR in the simulator):
the live "adjust strap" affordance + sample pause on a real strap toggling on/off-skin, and the live
per-climb HR spike on a board.

**Parity addendum — per-set effort in WorkoutTracker (same PR).** Extended the per-climb effort to the
workout logger so both apps reach parity. `ClimbEffort` is now generic ("a burn" = one HR window) and
the effort badge is a **shared `HREffortBadge`** view used by both the Kilter per-climb timeline and
the WorkoutTracker per-set tiles (Kilter's inline badge refactored onto it — one source of truth). New
pure `WorkoutHRStats.setEfforts(for:sessionStart:hr:…)` scores every completed set. **The window
derivation is the design decision, because a workout `SetLog` has only a single `completedAt`
(no start/duration window like a Kilter climb), and Quick/freeform sessions log all three `SetKind`s:**
window **end** = `completedAt + hrLagSec` for every kind; window **start** is per-kind — `.duration`
(timed hold) uses `completedAt − durationSec` (the known work interval), while `.repsWeight` and
`.climbAttempt` (no recorded duration) use a lookback to the **previous chronological** set's
completion (HR doesn't reset across exercises), **capped at 120 s** so the first set or a long rest
can't balloon the window past the real effort. `maxHR`/`restHR` aren't on `WorkoutSession`, so per-set
`peakHRR` is `nil` today (bpm-only) — it lights up when the user-HR-profile phase lands, same as Kilter.
**Caveat:** for short inter-set rests the HRR recovery reads into the *next* set's window, so the
recovery dot is an advisory within-session heuristic, not a clean clinical HRR. **Verified off-device:**
new `WorkoutHRStatsTests.setEfforts` cases (per-`SetKind` window, the capped previous-set lookback, the
incomplete-set + no-HR guards, bpm-only vs %HRR) + full XCTest suite green.

---

## 2026-06-08 — Fitness-band richness **Phase 2**: on-device user HR profile (the keystone)

**Context:** roadmap Phase 2 (`pdd/prompts/features/fitness-band-richness/ROADMAP.md`, prompt
`25-ios-user-hr-profile.md`). Phase 1 left `%HRR`/effort anchored to a hardcoded
`HeartRateZone.defaultMaxHR = 190`; Kilter could already personalize (`KilterSession.maxHR/restHR`),
WorkoutTracker could not (no such fields). This closes the gap in **both** apps.

**What shipped.** A small, app-agnostic `UserHRProfile` (age / resting / max-override / weight /
`BiologicalSex`) + `UserProfileStore` (JSON in `UserDefaults`) on `AppModel`, edited in a new
`UserHRProfileView` reached from Settings, with HealthKit prefill (`HealthKitService.profilePrefill`,
blank-fields-only merge). `WorkoutSession` gained `maxHR`/`restHR`/`metricsSourceRaw`/`kcalEstimate`
(additive Optionals → lightweight migration, mirroring `KilterSession`, which gained `kcalEstimate`);
both are stamped on session end from the shared store. Summaries, the per-set/per-climb
`HREffortBadge`, live pill, Live Activity, **watch face**, and **widget** all tint off the resolved
max HR now.

**Decisions worth recording:**
- **Max-HR formula = Tanaka `208 − 0.7·age`**, not the older `220 − age` — current physiological
  standard, more accurate across ages. An explicit measured override always wins.
- **Honest gating is structural, not cosmetic.** `resolvedMaxHR` is `nil` until the user supplies an
  age or a max override, and sessions store that `nil` — so with no profile, `%HRR`/effort/zones are
  byte-for-byte the Phase-1 bpm-only behavior, identically in both apps. We never store a phantom
  `190`.
- **Calories (Keytel) are BLE-only.** New pure engine helper `EnergyExpenditure` (Keytel et al. 2005
  HR→kcal/min + a left-edge-dwell series integrator, platform-free, `swift test`'d) fills the band's
  hardcoded `energy = 0`. Gated on `metricsSourceRaw == ble` + a complete profile (age + weight +
  male/female sex); the Apple-Watch path measures real active energy on the wrist, so we never
  override it with an estimate (watch sessions show no estimate). Labelled "kcal est." so it never
  reads as measured.
- **The profile reaches off-device processes as a wire field, not a shared store.** The watch + widget
  can't read the phone's `UserDefaults`, so the resolved `maxHR` rides `LiveMetricsContext` →
  `LiveWorkoutMessage.start(maxHR:)` (watch face zone) and a new static attribute on **both**
  `WorkoutActivityAttributes` / `KilterActivityAttributes` (widget zone). All optional / back-compat.

**Verified off-device:** `swift test` (`EnergyExpenditureTests`) + the XCTest suite
(`UserHRProfileTests` for the resolution precedence / energy gating / Keytel pass-through / prefill
merge; `WorkoutHRStatsTests` already covers per-set %HRR lighting up with bounds; `LiveWorkoutTests`
round-trips the `maxHR` start field). **Device-unverified** (no band/HR/watch in the simulator): the
live personalized zone tints on the watch + widget, and a non-zero BLE calorie estimate end-to-end.

---

## 2026-06-08 — Fitness-band richness **Phase 3**: RR-intervals → on-device HRV (device-gated)

**Context:** roadmap Phase 3 (prompt `26-ios-rr-intervals-hrv.md`), stacked on Phase 2. The band
already sends RR-intervals (beat-to-beat timing) in the same `0x2A37` packet we parse for bpm — and
we discarded them.

**What shipped.** `parseMeasurement` now decodes RR (flags bit 4), correctly **skipping the
Energy-Expended field** (bit 3) that precedes it, and converting the spec's 1/1024-second units to ms;
a truncated tail yields only whole intervals. RR threads as an **optional** `rrIntervalsMs` on
`HRSample` (engine) and `HRPoint` (persisted) — additive Optionals, no migration (old blobs decode
`nil`). New pure engine `HRVMetrics` (sibling to `ClimbEffort`) computes RMSSD/SDNN/pNN50 over a
window's RR. A shared `HRVBadge` (sibling to `HREffortBadge`) renders per-rest HRV between climbs
(Kilter `TimelineItem.restHRV`) **and** between sets (`WorkoutHRStats.setRestHRV`).

**Decisions worth recording:**
- **Honest device gating via a pure name/model classifier (`rrTrusted`), default-deny.** RR is
  trustworthy only from chest straps; optical wrist/arm sensors emit synthetic or no genuine RR. We
  classify off the peripheral **name** (works immediately, no extra round-trip) and refine with the
  Device-Info `0x180A` / Model-Number `0x2A24` read. **Unknown / unnamed → not trusted** → RR is
  dropped at `ingest` → HRV cleanly degrades to the Phase-1 bpm-only effort/recovery. The optical
  blacklist is checked **before** the chest-strap whitelist, so "TICKR FIT" (Wahoo's optical armband)
  is rejected before the "tickr" substring would match. The Apple-Watch path carries no RR by
  construction → symmetric degrade in both apps.
- **RR outlier filter in the engine.** `HRVMetrics` drops RR outside ~[300, 2000] ms (≈30–200 bpm) and
  needs ≥ a small minimum of survivors, so a dropped/merged/ectopic beat can't dominate RMSSD; under
  the minimum → `.empty` (badge hidden).
- **Rest-window definition for HRV.** Kilter: the `restBefore` gap `[prevClimbEnd, thisClimbStart]`.
  WorkoutTracker: `[prevSet.completedAt, thisSet work start]` — a `.duration` hold excludes its known
  work (`completedAt − durationSec`); `.repsWeight`/`.climbAttempt` (no recorded work start) take the
  whole inter-set gap as rest (most of it is). First set / zero gap → `.empty`.

**Verified off-device:** `swift test` (`HRVMetricsTests` — known-RR RMSSD/SDNN/pNN50, the min-interval
gate, the outlier filter, the window gather) + XCTest (`RRDecodeTests` RR+energy-skip+truncation,
`RRTrustTests` whitelist/blacklist/default-deny/TICKR-FIT + `ingest` drop-when-untrusted,
`RestHRVStatsTests` per-rest HRV in both apps). **Device-unverified** (no BLE/RR/strap in the
simulator): live RR capture off a real Polar H10, the `0x2A24` model read firing, and an optical band
showing no HRV.

---

## 2026-06-08 — Fitness-band richness **Phase 4**: recovery-ready nudge + effort-aligned selector

**Context:** roadmap Phase 4 (prompt `27-ios-recovery-nudge-effort-selector.md`), stacked on Phases
2 + 3. The two "bigger bets" that turn the personalized HR profile (Phase 2) and HRV (Phase 3) into
in-the-moment and in-the-reel value.

**What shipped.**
1. **Live recovery-ready nudge.** New pure engine `RecoveryReadiness.evaluate(currentBpm:restBpm:
   maxBpm:rrReboundFraction:)` → `{ unknown | recovering | ready, fraction }`. Both live pills
   (`LiveHRPill`, `KilterHRPill`) show a "Recovered" chip; `recoveryReady` threads through both
   `…LiveSnapshot`s (counted structural in `shouldPush`), both Live-Activity `ContentState`s, the
   controllers, and the widget renderers; the **watch** computes it on-wrist (inline %HRR — the watch
   target doesn't link the engine) from `maxHR` + a new wired `restHR`.
2. **Effort-aligned highlight selector.** New pure engine `EffortAlignedSelector` (boosts injected
   `[ClosedRange<Double>]` windows) + `FusionSelector.effortAligned(windows:)`; `AppModel.engine(
   boosting:)` builds the fused engine. Kilter boosts **sent-climb** windows (`KilterSessionStats
   .sentClimbWindows` → `ReelSource.boostWindows` → `ReelViewModel`); WorkoutTracker boosts
   **peak-effort set** windows (`WorkoutHRStats.peakEffortWindows` → `SessionHighlightViewModel`).

**Decisions worth recording:**
- **Readiness gating is structural.** `.unknown` without both profile bounds → every surface hides
  the nudge, identically in both apps (no profile ⇒ no nudge). HRV rebound is an optional sharpener
  (eases the %HRR threshold up to +0.10), never required.
- **The watch computes readiness inline, not via the engine.** The watch target doesn't link
  `HighlightEngine`, so rather than add the dependency for a 3-line %HRR check, the watch derives
  `recoveryReady` from its own live bpm + the wired `maxHR`/`restHR` (mirrors the Phase-2 `maxHR`
  wire). One more optional `restHR` field on `LiveWorkoutMessage.start` / `LiveMetricsContext`.
- **The effort boost is gated by empty windows, not a flag.** `FusionSelector.effortAligned([])` makes
  the effort term 0 everywhere ⇒ pure HR ranking — so no profile / no sends / no scored sets ⇒ today's
  reels, unchanged. The HealthKit-summary WorkoutTracker reel path (no per-set data) boosts nothing;
  the peak-effort boost lives in the session-based `SessionHighlightViewModel` path.
- **Two reel paths, one selector.** Kilter routes through `model.engine(boosting:).generate`;
  WorkoutTracker's session reel routes through `app.engine(boosting:).selector.select` — both fed the
  same `EffortAlignedSelector` via the shared windows helpers.

**Verified off-device:** `swift test` (`RecoveryReadinessTests` — state thresholds, HRV easing,
fraction clamp; `EffortAlignedSelectorTests` — in/out-of-window boost, fusion raises in-window above
out-window, empty-windows ⇒ HR-only) + XCTest (`RecoveryNudgeSelectorTests` — sent-climb +
peak-effort window derivations). **Device-unverified** (no live HR / band / watch in the simulator):
the live "Recovered" nudge on the pills / Live Activity / widget / watch firing as HR drops, and a
real reel favoring sent-climb / peak-effort moments.

---

## 2026-06-08 — Configurable HR/fitness video-overlay builder (prompt 28)

**Context:** the clip's HR overlay was a single bpm chart + dot (live bpm preview-only). All the
metrics from Phases 2–4 (zones, %HRR, effort, redline/strain, HRV, calories, recovery) existed but
none could be placed on the video. The user asked to **select which numbers/charts show, mark each
live or static, and animate where applicable**, in a simple UI.

**What shipped (single-clip editor — the per-clip "HR overlay on captured video"):**
- `HROverlayMetric` (bpm/zone/hrr/avgHR/maxHR/redline/strain/hrv/calories/recovery) with
  `supportsLive`/`supportsAnimation` capabilities, and `HROverlayElement` (metric + live + animated +
  position/scale/colour). `HROverlayConfig` gained `showChart` (toggle the chart line independently)
  + `elements`.
- Pure `HROverlayValues` resolver (text + `#RRGGBB`): static clip aggregates, live-at-playhead
  readings, and the export **segments** (de-duped, time-tiled). `swift`-unit-tested.
- Render: `HROverlayElementsView` (SwiftUI preview, drag to place) + `StudioOverlays.hrElementLayers`
  (export burn-in: one opacity-keyframed badge per display segment). `ClipEditorView` builder UI
  (add/remove a metric, Live + Animate toggles disabled where N/A), context computed from the session
  + `UserHRProfile`.

**Decisions worth recording:**
- **The Core-Animation constraint splits live vs. export.** AVFoundation's animation tool can't
  redraw text per frame, so a **static** element is one fixed badge; an **animated live** element is
  rendered by the **opacity-keyframe trick** — one short pre-rendered badge per distinct value,
  cross-faded over its time window (the resolver's `segments`). A live-but-not-animated element burns
  in its clip-start reading; the preview always tracks the playhead. "Animate" is disabled for static
  aggregates ("if applicable").
- **Back-compat needed a custom `Codable` init.** Synthesized `Codable` throws on a missing key for
  non-optional fields, so adding `showChart`/`elements` would break **already-persisted**
  `HROverlayConfig` blobs (it's a SwiftData Codable composite). A hand-written `init(from:)` uses
  `decodeIfPresent` (→ `showChart=true`, `elements=[]`) so old projects load unchanged. (A reusable
  gotcha: defaulted struct properties do NOT round-trip through synthesized Codable.)
- **Colour is one source of truth.** Added `HeartRateZone.colorHex` (the system-colour hexes for
  `color`) so a burned-in badge tints identically to the SwiftUI pill; zone/%HRR/recovery use the
  semantic colour, other metrics use the user's swatch.
- **Computation lives where the data is.** The view model resolves elements → `ResolvedHROverlay`
  (Sendable) and hands them to the AVFoundation render across the actor boundary, keeping the
  device-only renderer dumb and the value logic unit-tested.

**Scope / follow-up:** shipped on the **single-clip editor** (`ClipEditorView`), the direct per-clip
overlay surface. The **multi-clip Studio** (`StudioComposer`/`StudioEditorView`) shares the model and
still renders its chart (back-compat), but its element **builder UI + export wiring** are a noted
follow-up (thread `[ResolvedHROverlay]` through `makeComposition`'s 3 `makeAnimationTool` sites).

**Verified off-device:** XCTest `HROverlayModelTests` (capabilities, live-forced-off for static,
back-compat decode) + `HROverlayValuesTests` (aggregates, calories/HRV gating, live tracking, segment
build/coalesce). **Device-pending:** the actual burned-in badges + animated-live cross-fade in an
exported `.mp4` (no Core-Animation export render in the simulator).

---

## 2026-06-08 — HR/fitness overlay builder: multi-clip Studio parity (follow-up to prompt 28)

Wired the configurable overlay builder (prompt 28) into the **multi-clip Studio**, the documented
follow-up after the single-clip editor shipped (PR #60). Same model + pure `HROverlayValues`
resolver — no new value logic.

- `StudioComposer`: threaded `hrElements: [ResolvedHROverlay]` through `makeComposition` → `assemble`
  → `assembleSingleTrack` / `assembleWithTransitions` → all **three** `makeAnimationTool` sites (the
  no-filter, filter, and transition export paths) + `export`. Default `[]` → no behaviour change
  for projects without elements.
- `StudioEditorViewModel`: `loadOverlayContext(profile:)` fetches the session (workout **or** Kilter)
  `maxHR`/`restHR` and computes the session-wide kcal + HRV; element management (add/remove/live/
  animate/showChart) mirrors `ClipEditorViewModel`; `export` resolves + passes `hrElements`.
- `StudioEditorView`: `StudioHRControls` is now the same builder (chart-line toggle + per-element
  Live/Animate rows + Add menu); the preview shows `HROverlayElementsView` badges. The Studio overlay
  spans the **whole session** HR (vs. the single clip's capture window) — the only behavioural
  difference from the per-clip editor.

**Verified off-device:** sim build green; the existing `HROverlayValuesTests`/`HROverlayModelTests`
cover the shared resolver. **Device-pending:** the burned-in badges in a multi-clip Studio export.

---

## 2026-06-09 — HR-on-video: never-missing, per-clip heart-rate windows (prompt 29)

Bug: "wrist band was connected and working but a tagged video is missing HR." A deep multi-agent
review traced 47 failure modes → 32 confirmed. The band *was* recording; the breakage was in how a
clip is matched to the session's HR series. Two root causes, both fixed:

- **The multi-clip Studio drew the WHOLE session, not each clip's moment** (regression shipped with the
  Studio parity work above, 2026-06-08). `StudioEditorViewModel` loaded the whole-session `hrSeries`
  and handed it un-sliced to `StudioComposer`, which mapped it across the *concatenated composition*
  timeline — so a clip filmed at minute 25 of a 30-min session showed the session-wide chart crammed
  to a chart edge and session-aggregate badges. The single-clip editor already slices per clip; the
  Studio never did, though `TimelineClip.sessionMediaID` can resolve each clip's `SessionMedia.offsetSec`.
- **The strict window filter dropped HR for edge/sparse/short clips.** The slice used a hard
  `t >= start && t <= start+span` with no bracketing → a clip before the band connected, a victory clip
  in the trailing ±90 s pad after HR stopped, or a short clip between sparse band samples → **0
  samples** → the chart (needs ≥2) and every badge silently vanished. ~12 findings reduced to this.

**Decisions:**

- **One pure slicer, `HRWindowSlicer`, is the single guarantee.** In-coverage: bracket the window with
  *interpolated* endpoints (so a gap between sparse samples still draws a correct line). Just outside
  coverage but within a **90 s tolerance** (the same ±90 s `SessionMediaService` discovery pad): clamp
  to a **flat last-known line** so legit edge clips never go blank. Beyond tolerance, or empty series:
  return `[]` (honest "no HR" — we don't pass off a reading minutes away as live). Non-empty ⇒ always
  ≥2 points. This kills the whole element-vanishes family with one helper. (Clamp-within-pad-else-honest
  was a deliberate product call over "always clamp": a cool-down clip 5 min later showing the final
  climbing HR as if live would mislead.)
- **Per-clip in the Studio, keyed on `SessionMedia.offsetSec`.** New pure `StudioHRPlacement` slices the
  session series per visible video clip (trim-adjusted window). `StudioComposer` threads `clipHRByID`
  through `makeComposition`/`assemble`/both assembly paths/`export` and `StudioOverlays` renders **one
  chart + element set per clip**, opacity-gated/animated to each clip's output slot (so only the
  current clip's HR shows). Slot math stays in the composer (it owns it); pure sample/badge resolution
  stays in the VM. The single-clip `VideoStudio` path is byte-for-byte unchanged — the slot params
  default to the whole timeline (no gate). The chart normalizes its own x-axis, so per-clip samples
  only need clip-local rebasing, not output-second scaling.
- **Active-session live fallback (`SessionHRSeries.forSession(_:in:liveSamples:)` + pure `LiveHRMerge`).**
  The non-Kilter workout path has no mid-session `syncLiveHR`, so a clip opened while the workout is
  live read an empty persisted series. Fallback: only when the session is still active, adopt the live
  coordinator buffer — **both** transports merged (not just the active one) so a mid-session HR-source
  switch doesn't drop the earlier transport's samples. Read-only; never persists.
- **Manual-pick offset hardening is subsumed by the slicer.** Out-of-window / future / nil-creationDate
  manual picks no longer lose HR silently: in-coverage → correct, near-edge → last-known, far-out →
  honest empty. No offset clamp added (would risk mis-tagging a genuine in-session manual pick).

**Out of scope (separate PRs) — persistence-time data loss, NOT slicing:** force-quit tail loss,
source-switch-at-*finish* (the flush reads only the active source's buffer), orphan-Kilter no-flush.
If `hrSeries` was never written there's nothing to slice; the live fallback only covers the in-editor
*active* case. Flagged, not fixed here.

**Verified off-device:** 441 unit tests green incl. new `HRWindowSlicerTests` / `LiveHRMergeTests` /
`StudioHRPlacementTests`. **Device-pending:** the per-clip Studio export burn-in (Core Animation
per-clip chart/badge layers; -11838-sensitive, can't render on the simulator) — record a session with
a band, film clips early/late/at-the-end, confirm each clip's exported overlay shows its own HR.

## 2026-06-09 — Create a new climb: identity, dedup, manual editor (PR 1 of 3)

The Kilter module became *authorable*: users can design a climb (manual editor now; the on-device
generator in PR 2) instead of only browsing the read-only catalog. Non-obvious choices:

- **Content-derived uuid, NOT a time-based one.** The brief asked for a "time-based uuid that's the
  same across devices for the same climb" — internally contradictory: a v1/v7 time UUID embeds the
  clock + a node, so two devices necessarily differ. Only a hash of the climb's content can be equal
  across devices. So a created climb's id is a **UUIDv5** (`KilterClimbIdentity`, CryptoKit SHA-1,
  fixed namespace) over the canonical `(layoutId, sorted holds)`. Creation time lives in a separate
  `createdAt` field — never folded into the id (that would break cross-device equality). Pinned with a
  golden-vector test so a refactor can't silently re-key every created climb.
- **Canonicalization = sorted `p<placement>r<role>` tokens**, layout-scoped (a placement id only means
  something within its layout — matches Aurora's own `layout_id`+`frames` identity). Order-independent,
  so it underpins both the uuid and duplicate detection.
- **Dedup is two-channel.** Catalog climbs keep Aurora's *random* uuids, so a draft that matches a
  *catalog* climb is caught by comparing canonical frames; *created* climbs are caught directly by the
  deterministic uuid. `KilterDuplicateChecker` indexes both per layout; built fresh at save time (one
  indexed SELECT — cheap, always current). On a hit the user gets Open existing / Save anyway / Keep
  editing.
- **Reuse via a `KilterClimb` adapter.** `KilterCreatedClimb.asClimb` shapes an authored climb as the
  read-only catalog value type, so it flows through the *existing* `KilterCatalog.holds(for:)` render,
  `KilterClimbDetailView`, BLE illumination and logging with no special-casing. The detail screen
  resolves a created climb by uuid and synthesizes a single-angle stat (created climbs have no catalog
  `climb_stats`). Authoring requires an installed catalog (for hole geometry) — consistent with the
  whole module.

**Verified off-device:** full `SnappetTests` suite green (458 tests, 0 failures, 2 pre-existing skips),
incl. new `KilterCreateClimbTests`. **Device-pending:** the end-to-end author → save → render → BLE
illuminate path on a real board (BLE can't run on the simulator, like prior Kilter work).

## 2026-06-09 — On-device climb generator: ONNX transformer (PR 2 of 3)

Wired the board-explorer's generator into the app (the ✨ Generate tab). Non-obvious choices:

- **Run the real ONNX model, via ONNX Runtime, not a reimplementation.** The explorer ships a quantized
  transformer (`model.q.onnx`); we run that exact artifact through `onnxruntime`
  (microsoft/onnxruntime-swift-package-manager, import `OnnxRuntimeBindings`) so on-device output matches
  the web tool. Considered Core ML (no third-party dep) but the int8-transformer conversion carries real
  divergence risk; ONNX Runtime runs the file unchanged.
- **Pure core behind a thin edge.** Everything except the tensor call is a pure Swift port
  (`KilterGeneratorMeta`/`KilterClimbGenerator`, decode `at`/`rt`/`st`/`nt`) depending only on a
  `KilterLogitsProviding` protocol — so the whole sampler is unit-tested with a stub session (no ONNX, no
  model file, no device). `KilterORTSession` is the *only* `import OnnxRuntimeBindings`; an `actor`
  (`KilterGeneratorRuntime`) isolates the non-Sendable session and returns only the Sendable result.
- **Model I/O, learned from the bundle:** int64 `tokens` `[1, block]` left-packed + `pad`-filled; `logits`
  `[1, block, vocab]` read at the last real token's position. Prompt
  `[BOS, SIZE, ANGLE, GRADE, MATCH|NOMATCH]`; candidates masked to `sizeMasks[sizeId]` minus used
  placements; EOS gated on minHolds+start+finish; missing start/finish repaired ⇒ valid by construction.
- **Lazy-download, not bundled.** `KilterGeneratorAssets` fetches model + meta from the existing host on
  first use (mirrors `HostedCatalogClient`), keeping the binary slim and the model updatable host-side.
- **Generated climbs reuse PR 1's save path** (shared `SavePayload` → dedup → content uuid →
  `KilterCreatedClimb`, `source = "generated"`, predicted grade recorded).

**Verified off-device:** full `SnappetTests` green (467 tests, 0 failures) incl. `KilterGeneratorTests`
(deterministic decode, start/finish guarantee, repair, no-dup-placement, mask honored, grade regression).
**Device-pending:** the real model download + an actual ONNX inference run on-device (the simulator
linked ORT fine, but inference timing/parity is worth confirming on hardware), and frames-parity spot
checks against the web explorer.

## 2026-06-09 — Create-a-climb polish: live BLE preview + frames export (PR 3 of 3)

Closed out the create-a-climb feature.

- **Live BLE preview reuses the whole render path.** `CreateClimbView` takes the shared
  `KilterBoardController` and lights the draft via `KilterCatalog.holds(for:)` + `illuminate` — auto on
  `onChange(of: assignments)` and after a generation, plus an explicit "Light on board" row that's hidden
  unless a board is connected. No new BLE code; the draft is shaped as a `KilterClimb` (same trick as the
  render/detail reuse).
- **Frames are the portable artifact.** A climb's `p<placement>r<role>` string is both the catalog's
  storage and the board-explorer's "Copy frames" format, so Copy/Share-frames (canonical form) is the
  natural export — added to both create tabs and to `KilterShareView` (so authored climbs, which have no
  shareable catalog uuid for the QR path, are still portable as text).

**Verified off-device:** full `SnappetTests` green (467). **Device-pending:** BLE lighting of the draft
on a real board and the clipboard/share sheet (both runtime/device-only). Closes the create-a-climb arc
(PRs 30→31→32); Android mirror still outstanding (iOS-lead).

## 2026-06-09 — Create a new climb: Android port (Kotlin / Compose)

Mirrored the full iOS create-a-climb arc (manual editor + ONNX generator + dedup + content identity + BLE
preview + frames export) onto Android. Non-obvious choices:

- **Cross-platform identity is exact, not approximate.** `KilterClimbIdentity` (Kotlin) computes the same
  UUIDv5 as iOS — same namespace, SHA-1 over `"<layoutId>:<sorted-frames>"`, version/variant bits — using
  `java.util.UUID` MSB/LSB → big-endian bytes (matching the iOS `uuid` tuple order). A **shared golden
  vector** (`d4e7b15e-…`) is asserted in both `KilterCreateClimbTest` (Kotlin) and `KilterCreateClimbTests`
  (Swift), so a climb authored on an iPhone and an Android phone collapses to one id.
- **Same pure-core / thin-edge split as iOS.** Identity, dedup, frames/validation, and the generator
  decode (`KilterClimbGenerator` over a `KilterLogitsProviding` interface) are Android-dependency-free →
  JVM unit-tested with a stub session (no ONNX, no model, no device). `KilterOrtSession`
  (`ai.onnxruntime`) is the only binary-dependent file.
- **Two new deps via the version catalog:** `onnxruntime-android` (generator runtime; Java OrtSession +
  `float[1][block][vocab]` logits, last-token slice) and `kotlinx-serialization-json` (so `meta.json`
  decode is JVM-testable). HTTP download is plain `HttpURLConnection` (no OkHttp added).
- **Room, not SwiftData.** `KilterCreatedClimb` is a Room `@Entity` (DB 3→4, `fallbackToDestructiveMigration`
  as the module already uses); `@Upsert` keyed by the content uuid mirrors iOS's unique-uuid upsert.
- **Reuse parity:** `KilterCreatedClimb.asClimb()` + `KilterDetailScreen` resolver + `KilterEditableBoard`
  on `KilterCatalog.placeableHolds` mirror the iOS reuse so created climbs flow through the existing
  render/detail/BLE/logging path.

**Verified off-device:** `:app:compileDebugKotlin` + `:app:assembleDebug` succeed; `:app:testDebugUnitTest`
green — `KilterCreateClimbTest` (14, incl. the iOS-matching golden vector) + `KilterGeneratorTest` (8).
**Device-pending (Android):** model download + on-device ONNX inference, BLE draft-lighting, clipboard/share
— all runtime/emulator-or-device only. Create-a-climb now exists on **both** platforms.

### 2026-06-09 addendum — Android create-climb: emulator UI tests + a real bug they caught

Added `KilterCreateUITest` (instrumented, runs on the emulator with the synthetic catalog fixture):
opening the editor, disabled-until-valid Save, draw→save→find-under-Mine, the duplicate-guard dialog
on re-save, and the ✨ Generate download prompt. **5/5 pass.**

The first run failed 4/5 and surfaced a genuine bug: `KilterEditableBoard`'s `pointerInput(placeable)`
captured a **stale** `onCycle` (the gesture isn't restarted when `assignments` change), so every tap
reset the climb to a single hold — multi-hold placement was silently broken on Android. Fixed by reading
the callback through `rememberUpdatedState`. iOS is unaffected (SwiftUI re-creates the gesture closure each
body eval, capturing the live binding).

**Infra note:** Gradle's `connectedDebugAndroidTest` wedges on this iCloud-synced Desktop (the daemon
hangs before installing the test APK). Workaround that runs cleanly: build the APKs, then
`adb install` + `adb shell am instrument` directly (bypassing Gradle's device orchestration).

## [2026-06-10] Android — primary actions promoted out of overflow menus; Download leads the Kilter first-run (#94)

**Decision**: the platform's differentiated create actions are now visible controls instead of kebab
items (prompt 42, the last Android Wave-1 item from the 2026-06 product review):

- `ModuleScaffold` gained an optional `floatingActionButton` slot (the app previously had **zero**
  FABs, which is why everything had landed in overflow menus).
- **Kilter browse**: "Create climb" is an extended FAB (`kilter.create` moved off the menu item);
  the More menu keeps start/end session, surprise me, settings. The Mine empty state now points at
  the FAB instead of teaching the menu path ("Tap More ▸ …").
- **Expense group detail**: "New expense" is an extended FAB, "New receipt" (the only entrance to
  receipt OCR) is a visible top-bar receipt icon, and "Settle up" is an inline button on its section
  header — which emptied the kebab, so the `expense.groupActions` menu is **gone**. Lists under FABs
  get 88 dp bottom content padding so the FAB never covers the last row. The settle button renders
  with the sections (i.e. only once the group has records) — settling an empty group is meaningless.

**Reversal recorded — "file-import primary" (Android first-run only).** The [2026-06-05/06] entries
kept "Import catalog file…" as the primary filled button on `KilterCatalogSyncScreen` as a deliberate
legal-posture signal. That buried the only path that works for most phone users behind a power-user
flow, and the helper copy referenced "the boardlib tool — see tools/kilter" — a git-repo artifact a
phone user cannot see or act on. Now **Download from Kilter leads** (filled, first) with Import as the
outlined secondary, and the repo-artifact sentence is deleted (the caption explains both paths in user
terms). Everything that actually carries the legal posture is **unchanged**: the Aurora ToU notice +
link before any fetch, the user-controlled host, no Aurora API, personal/sideload-only scope. iOS
emphasis is untouched (its first-run order is an iOS-tracker concern).

**Verified**: unit suite + the full 39-test instrumented suite green on the emulator
(`KilterCreateUITest` now drives the FAB, `ExpenseUITest` the FAB + inline settle,
`KilterUITest.emptyStateShowsCatalogSyncScreen` asserts both install buttons).

## [2026-06-10] Android — system back, rotation/process death, tab retention, workout resume (#86)

**Decision**: module-local `BackHandler` + `rememberSaveable`, **not** a NavHost migration (prompt 43,
first Android Wave-2 item). The issue offered two shapes; promoting every module's sub-screens into
the `library → module/{id}` NavHost graph would have rewritten all eight module roots. Instead each
multi-screen module root keeps its enum/id state and adds a `BackHandler(enabled = <in sub-screen>)`
that does exactly what its top-bar arrow does; at module root the handler is disabled so back falls
through to the NavHost (→ app grid). The #99 Today-home nav hoist builds on this later.

- **Tab retention**: `RootShell` wraps the `when (tab)` content in a `SaveableStateHolder` entry per
  tab — the NavHost back stack (savedState-backed) and every `rememberSaveable` below it now survive
  Today ↔ Apps. The bare `when` previously disposed the whole Apps subtree per switch.
- **Saveable promotion, not ViewModels**: screen/section enums (Serializable → autoSaver), selection
  ids, search text, filters, sheet booleans, and text drafts went straight to `rememberSaveable`.
  Object staging (`editing: Foo?`) became **id staging** + derive-from-flow, so process death restores
  by Room lookup and a deleted row self-heals to null. Three custom Savers: kilter hold assignments
  (`Map<Int, KilterAuthorRole>` ↔ `"id:roleName"` strings — pure codec, unit-tested), receipt line
  items (`ItemEdit` holds `MutableState` fields → flatten to strings), budget `MonthScope` (epoch-anchor
  Long).
- **The load-race gate** (the subtle bug): every module had `if (row == null) screen = ROOT` self-heal
  guards. Once `screen` is saveable, a restored sub-screen composes against `collectAsState(initial =
  emptyList())` **before Room's first emission** and instantly bounces to ROOT — rotation/tab-return
  would "work" but always land on the dashboard. Fix: `initial = null` + guard only when the flow has
  emitted (workout, budget; journal gates editor composition the same way). Expense/kilter derive
  rather than write, so they self-heal without the gate.
- **Workout resume policy**: an unfinished session (`finishedAt == null`) is only ever finalized by the
  user — resumed and finished, or explicitly discarded — never auto-deleted, never auto-finished. The
  dashboard banner (Resume / confirmed Discard) is the only surface; History stays finished-only. The
  live player was already persisting every completed set (`dao.updateSession` per set), so resume is
  pure UI — no schema change, store stays v4. Player back always routes through the End/Discard dialog
  (innermost-wins over the module root's handler).
- **Accepted residuals**: `BackupScreen.pendingImportText` (MB-scale JSON) deliberately not saveable —
  Bundle transaction limits; momentary confirm-dialog staging stays `remember`; BLE board/session
  controller objects still rebuild on rotation (device-phase; their *navigation context* restores);
  Pomodoro `focus`/`brk` stay `remember` — their initializers re-read SharedPreferences (the real
  source of truth), a Bundle copy could shadow it stale.

**Pre-merge adversarial review round** (3 lenses + per-finding skeptics; 5 confirmed, all fixed):
(1) the banner resume was **completion-blind** — it opened at the first non-skipped exercise, set 0,
and `completeSet()` unconditionally replaces the set at the current position, so tapping forward
would have silently overwritten real logged sets with target-prefilled values (and Skip would have
hidden a trained exercise from the stats). The player now starts at the **first incomplete set**
(`firstIncomplete`, also the out-of-range clamp fallback) and opens straight on the summary when
everything is logged. (2) The generated climb (`genResult`) was runtime-only although the prompt
required saving it — generation is stochastic, so the dropped result was unrecoverable. Frames +
predicted grade now survive via `GenResultSaver`; the preview holds re-derive from frames, and
`prepareModel` lands on READY when a result exists (also fixing the pre-existing
tab-switch-hides-result quirk). (3) Kilter catalog `search`/`sort`/`benchmarksOnly`/`minAscents`/
`minQuality` had missed the promotion — half-restored UI (the saveable sheet reopened over reset
values). (4) Journal now uses the same null-initial gate as workout/budget — no list flash while the
flow loads, and a deleted staged row resets `editorOpen` so back isn't absorbed as a no-op.
(5) Expense got the same gate — no false "No groups yet" flash; a deleted staged group self-heals
its id.

**Verified**: unit suite green (incl. new `KilterAssignmentsCodecTest`); instrumented suite green on
the emulator — 39-test baseline + new `NavRobustnessUITest` (back-pops-one-level, End-dialog-on-back,
recreate-preserves journal/create-climb drafts, recreate-mid-workout restores the player, tab-switch
retention, resume-banner resume + discard, resume-lands-on-first-incomplete-set). UI-test infra
gotcha recorded: `recreate()` while `TestHooks.freshInMemoryStore` is still true rebuilds an *empty*
store mid-test — `launchForRecreate()` pins the container after first launch.

## [2026-06-10] iOS — close the set-logging loop: cross-session prefill, edit completed sets, history search (#73)

**Decision shape** (prompt 45): three pure cores at thin edges, no schema change, no new screens.

- **Prefill source = the deciding session's *last* completed set, not its first.** Issue #73 says
  "the most recent completed SetLog" — that's what the user finished on (their working weight after
  in-session adjustments), so set 1 today starts there. The hint summarizes *all* of that session's
  completed sets ("Last time: 3×8 @ 60 kg"; mixed reps → "8/8/6"; mixed weights → a "55–60 kg"
  range; bodyweight omits weight). `LastSetLookup` is pure (sessions in, prefill+hint out), ignores
  active sessions and non-reps/weight kinds, aggregates duplicate `exerciseId` occurrences (the
  `WorkoutMath` freeform rule), and sorts by `completedAt` itself rather than trusting caller order.
  Precedence in `prefillInputs()`: current-session previous set → cross-session → routine target
  (the issue's "current-session sets still win").
- **Mixed-unit hint converts via kg rounded to one decimal** — otherwise 132 lb re-expressed in kg
  prints float noise ("59.874144…"). Same-unit weights (the overwhelming case) pass through raw.
- **Edit mode mutates ONLY `actualReps`/`actualWeight`.** `SessionSetEditing.apply` never adds,
  removes, or reorders sets and never touches `completedAt`/`weightUnit`/`kindRaw` — per-set media
  assignment and HR-effort lookups key on `(exercise UUID, set index)`, so a structural edit would
  silently re-tag clips/efforts to the wrong set. Duration/climb sets and never-completed sets stay
  read-only (the issue scopes editing to reps/weight). Input parsing is the **shared**
  `SetMeasure.parseReps/parseWeight` (extracted from the player's inline parsing), so the editor's
  sanity rules can't drift from the live player's.
- **Edit-mode plumbing via the drafts dictionary, not a mode flag.** The parent (`SessionDetailView`)
  owns `[Key: Draft]`; a tile renders edit fields exactly when a draft exists for its key — drafts
  are non-empty only between Edit and Save/Cancel, so no separate `editing` boolean threads through
  `SessionMediaSection`. Save rewrites `session.exercises` wholesale (value-array on the `@Model`)
  + `context.save()`; stats/charts recompute via `@Observable`/`@Query` observation. The SwiftData
  round-trip is locked by a unit test (in-memory container **held as a test property** — a
  `ModelContext` doesn't retain its container; letting it dealloc traps EXC_BREAKPOINT), proving
  `WorkoutMath` PR/volume change from the corrected *stored* values. Live re-render of an already
  pushed Dashboard/Progress screen is asserted by design (observation), not by an automated UI test.
- **History search/chips are the pure `HistorySearch`** (chip = exact `routineName`, query =
  case-insensitive substring, chips ordered most-recently-trained). Chips render in a top
  `safeAreaInset` only when history spans >1 routine name. The History row keeps its value-based
  `NavigationLink` (the documented Button-never-fires quirk) — untouched.
- **Accepted residuals**: the guided player still seeds `unit` from the *previous in-session set*
  before the cross-session unit (consistent with the old behavior); `FreeformPlayerView`'s
  LogSetSheet keeps its own inline parsing (same rules; consolidating it is incidental churn);
  no "sort" control on History — search + chips cover the issue's acceptance criteria.

**Pre-merge adversarial review round** (6 confirmed, all fixed): (1) sets completed *before* an
exercise was skipped count in `WorkoutMath` volume/PRs but were invisible and uneditable — rule:
skipped sets are **visible + editable + counted**; the detail view renders the completed tiles
under the "Skipped" caption and `drafts(for:)` drops its `!skipped` guard. `LastSetLookup` keeps
counting them too — consistent with `WorkoutMath`, and now fixable when wrong. (2) Edit mode was a
unit trap: the tile shows the preferred-unit conversion but the field showed the raw stored
value+unit, so "confirming" a kg-stored set while on lb relabeled kilos as pounds. Rule:
**WYSIWYG** — drafts seed the weight converted to the preferred unit (the hint's one-decimal
rounding) and Save writes the parsed weight **with** `weightUnit = preferred`; `apply` re-derives
the seeded drafts and skips untouched ones wholesale, so conversion rounding can never drift a set
the user didn't edit (bit-identical round trip locked by test). (3) Deleting the filtered routine's
last session hid the chip row and left History stuck on empty — `HistorySearch.effectiveRoutine
(filter:names:)` makes a stale filter inert, and the chip row stays visible while an effective
filter is on so it can always be toggled off. (4) The player's inline `lastTime(ex)` hint re-scanned
all history on every body render (~1 Hz under live HR) — now cached in `@State` by
`prefillInputs()`/`prefillEditing()` (one scan per set transition). (5) `formatWeight`'s
`Int(Double)` trapped past `Int.max` (a duplicate copy lived in the player) — `Int(exactly:)` with
a `String(value)` fallback, duplicate deleted; `parseWeight` rejects non-finite and ≥100 000 inputs.
(6) The compact "N×R" hint miscounted when reps-bearing and weight-only sets mixed ("2×8" for three
sets) — compact only when *every* set carries equal reps, else a per-set list with "–" placeholders
("8/–/8"); all-weight-only still omits reps.

**Verified**: `xcodegen generate` clean. The simulator suite (new `LastSetLookupTests`,
`SessionSetEditingTests`, `HistorySearchTests`, extended `SetMeasureTests` + the existing
walkthroughs) is run by the orchestrator — not from this worktree.

## [2026-06-10] iOS — flagship reel flow: recoverable dead ends + a real export payoff (#72)

**Decision**: every reel/workout dead end is now driven by a **pure policy layer**
(`Features/Reel/ReelFlowPolicy.swift` — copy, action sets, confirmation messages, export paths,
sweep selection, activity icons), rendered by one `RecoveryUnavailableView`. The views stay dumb;
the *choices* are unit-tested in `ReelFlowPolicyTests` (prompt 44, first iOS Wave-2 item).

- **`.exportFailed` is a new `ReelViewModel.State`, not `.error`.** A failed export leaves
  pins/removals/order untouched in the VM, so the failure surface offers *Retry export* (re-runs
  `export()` with the same curation) and *Back to my edit* (`.ready`). `.error` stays the
  build-failure state and gained *Try again*.
- **Denied-state remedy honors the verifier caveat.** `PHPickerViewController` presents without
  permission, but `media(forIdentifiers:)` resolves through `PHAsset.fetchAssets`, which returns
  nothing under full denial — so the denied empty state offers **Open Settings + Try again only**,
  never "Select clips" (asserted in `testDeniedEmptyNeverOffersSelectClips`). `generate()` maps
  `PhotoError.denied` → `.empty`; the spec is picked off a **live** `currentStatus` read so
  returning from Settings is reflected immediately. `.restricted` maps to `.denied` (same surface).
- **Health copy is truthful about invisibility.** HealthKit read denial isn't queryable, so the
  empty workout list says permission *may* be the cause and offers Refresh (explicit button — the
  overlay swallows pull-to-refresh) + Open Settings. The old "track a workout, then pull to
  refresh" promise is gone; the module/list error states offer Try again (re-bootstrap) + Settings.
- **Exports moved out of `tmp` → `Application Support/Reels`**, backup-excluded (regenerable,
  potentially large full-length renders), swept to the newest `keepLatestExports = 3` before each
  new render (pure `sweepableExports`, date-sorted with path tie-break). Backing out or "Make
  another cut" no longer destroys the artifact mid-flow. **Accepted residual**: there's no in-app
  browser for past exports — the on-disk copies are an *internal* safety net (nothing in the UI
  lists or reopens them), so user-facing copy promises only Save to Photos (see review fix 4).
- **Regenerate confirms only when something is at stake** (pure
  `regenerateConfirmation(pinned/removed/order/exportedUnsaved)` → message or nil): curation
  and/or an exported-but-unsaved cut produce a destructive-role `confirmationDialog`; with nothing
  to lose, regenerate stays one tap.
- **The payoff screen plays the reel**: auto-playing looped hero (`AVQueuePlayer` +
  `AVPlayerLooper`, paused on disappear; audio respects the silent switch — no audio-session
  override), *Save to Photos* (add-only via the existing `MediaLibraryService`, with a Settings
  hint on save-denied) + *Share*, and the success haptic **rides the existing `.celebrates(on:)`
  landing** (issue #80) — deliberately not double-fired.
- **Thumbnails**: `Highlight.mediaItemId` already names the source asset, so rows load a poster
  frame via one shared `PHCachingImageManager` (static on the View struct — MainActor-isolated via
  the `View` conformance, hence concurrency-safe), `.highQualityFormat` (single callback ⇒ safe
  continuation), network-disallowed; the old kind icon is the fallback when the asset is
  unreadable (e.g. ungranted under limited access). Workout rows gained pure-mapped activity icons.

**Pre-merge adversarial review round** (8 confirmed, all fixed): (1) the limited-access toolbar
add-clips button regenerated straight over pins/removals/order with no dialog while Regenerate
and Make-another-cut both confirmed — it now runs through the same `regenerateConfirmation` gate
(the `.empty`-state pick stays one-tap: curation is always empty there). (2) "Select clips" under
`.limited` looped silently back to `.empty`: PHPicker browses the FULL library but never widens
the grant, and `media(forIdentifiers:)` resolves only granted assets, so out-of-grant picks
vanished with zero feedback — rule: under limited access every pick surface presents the system
**limited-library picker** (`PHPhotoLibrary.presentLimitedLibraryPicker`, the one sheet that
extends the grant; UIKit-presented from the view layer via the key window's top VC — the policy
stays pure with a new `.extendLimitedSelection` action) and regenerates on return so the newly
granted clips are auto-discovered; `usePickedMedia` runs picks through the pure
`pickedMediaResolution` — all dropped → the explanatory `pickedClipsUnavailableSpec` (Open
Settings + Try again) instead of the generic empty, partially dropped → build with what resolved
plus an honest edit-list footnote naming the left-out count. (3) `bootstrap()` flipped `.ready`
*before* awaiting `refreshWorkouts()`, so every cold load flashed the "may not have permission"
overlay over the empty list and the overlay's Refresh gave no in-flight feedback — `.ready` now
lands after the fetch (a failed refresh's `.error` is preserved), and an `AppModel.refreshing`
flag swaps the overlay to a spinner while a fetch is in flight (`WorkoutModuleView`'s `.loading`
spinner still covers the bootstrap window). (4) the keep-3 copy overpromised ("Snappet keeps your
latest exports on this device") although no UI lists or reopens past renders — the payoff caption
and the unsaved-cut confirmation now promise only what's real: Save to Photos, or a new cut
replaces/discards this one; the sweep is documented as an internal safety net (comments in
`ReelExporter`/`ReelFlowPolicy` corrected). (5) the Health-denied copy routed to the per-app
Settings page, where no Health toggle exists — the copy now names Settings > Privacy & Security >
Health > Snappet and Open Settings stays a best-effort shortcut (stale "Health toggles live
there" comments corrected). (6) `.kept` feedback was logged before the export `try`, so every
failed-then-retried export re-logged the survivors as training data — kept + exported both log
once, after a successful export. (7) `generate()` didn't invalidate `previewPlayer`, so a
confirmed Regenerate / Make-another-cut / new-pick rebuild could keep showing (and playing) the
discarded cut — invalidated with the other per-cut resets. (8) `export()` had no reentrancy
guard, so a double-tap could run two concurrent exports racing the sweep — it bails when already
`.exporting`. New/changed pure tests: `pickedMediaResolution` (all/partial/none dropped + the
empty-pick-is-cancel edge), `pickedClipsUnavailableSpec`, shortfall-note pluralization, the
limited spec's `.extendLimitedSelection`-not-`.selectClips` shape, the Privacy & Security path
assertion, and the no-overpromise assertions on the unsaved-cut message. No UI tests for the
picker flows — the limited-library round-trip is the device-pending class.

**Verified off-device**: all changed files parse; pure suite added (`ReelFlowPolicyTests`).
**Device-pending (per repo pattern)**: the full flow on hardware — real export into
`Application Support/Reels`, looped playback, Photos add-only permission sheet + save, the
limited-library picker round-trip (extend grant → regenerate), Settings deep-link round-trips
for Photos/Health, haptic feel. Simulator: full `SnappetTests` run by the orchestrator after
merge into the test queue.

---

## 2026-06-10: iOS #71 — actionable Home: shell-hoisted SuiteRouter, TodayDigest render gates, flagship first-run CTA

**Decision**: Make the Home tab actionable (prompt `46-ios-home-actionable.md`, issue #71) by
hoisting `SuiteRouter` to the shell and deriving an "Up next" Today section from the modules' own
SwiftData rows via a new pure `TodayDigest`. The non-obvious choices:

- **The router hoist lands in `RootShell`, and the tab moved INTO the router.** `SuiteRouter` now
  owns `tab: SuiteTab` + the Apps stack's `NavigationPath`, is created by `RootShell` (the `apps`
  launch arg seeds the initial tab — the `--start-tab apps` QA hook is unchanged), and is injected
  shell-wide. Anything that routes — Home today; `.onOpenURL` QR links (#75) and App Intents (#81)
  tomorrow — needs to switch the tab *and* set the path as one operation, so splitting tab state
  from path state would force every deep-link site to coordinate two objects. `ShellTabs` binds
  `TabView(selection:)` to `router.tab`; `AppLibraryView` binds its `NavigationStack` to the hoisted
  path, so Apps-tab navigation is byte-for-byte the old behavior (the Journal mid-compose tab-switch
  test is the guard: switching tabs never touches the path).
- **`open(module:)` REPLACES the path rather than appending.** A deep link should land on the
  module root, not on top of wherever the user last was — repeated entries would otherwise pile a
  stale stack. Deeper screens are typed pushes layered on the fresh root: Home's Kilter card does
  `open(module: "kilter"); push(KilterPlanRoute())` — a two-level path set in one transaction,
  relying on `KilterPlanRoute`'s `navigationDestination` registering when `KilterRootView` (level 1)
  loads. Parse-verified only; the orchestrator's simulator run is the proof.
- **`nil` IS the render gate.** Each `TodayDigest` derivation returns `nil` when its module has no
  data (no habits / no active session / Pomodoro never used / no positive budget limit / no logged
  climbs), and the card simply doesn't render — "cards render only when their data exists" without a
  separate visibility flag that could drift from the data. Corollary: the focus card renders with
  honest zeros once Pomodoro has *ever* logged a block (that's the "start focus" nudge), but an
  untouched module never advertises on Home.
- **Budget pace = month-to-date spend vs the `MonthScope`-prorated total budget**, counting only
  transactions whose category still exists — orphans (deleted categories) are excluded to match the
  Budget screens. Resume picks the newest-started open session (stable id tie-break) even though the
  store invariant is "at most one active" — Home should never crash or mislead on drifted data. The
  Kilter card's grade label comes from `KilterRecommender.workingDifficulty` over the user's own
  logs, so the card and `KilterPlanView` can't disagree about the anchor.
- **First-run = the flagship CTA, not a tutorial.** The fresh-install Home hero deep-links into the
  `workout` module, which already phase-gates to `OnboardingView` on first entry — reusing the
  value-first permission flow instead of inventing a global first-run state on `AppModel`. The App
  Library gains a featured flagship hero card *above* the grid (the grid card stays — the smoke
  test taps `moduleCard.workout` by id, and removing it would also break muscle memory); the hero
  initially shipped without its own `matchedTransitionSource` — reversed in the pre-merge review
  round below, which gave it a distinct source id (review fix 4). Home tab glyph:
  `square.grid.2x2.fill` → `house.fill` (the grid glyph promised an app grid that lives on the
  *other* tab).
- **Feed rows guard on the registry**: a `UsageRecord` from a retired module id renders as a plain,
  non-tappable row instead of a button into nothing.

**Pre-merge adversarial review round** (5 confirmed, all fixed): (1 — major) the Home "Plan
tonight's session" deep link landed in `KilterPlanView` without ever running
`KilterRootView.onAppear`, so its "Start session" could start an **unbound, unrecovered** session —
no live HR / Live Activity / media discovery, plus a possible duplicate open session (the exact
stale-session class #54 fixed). Rule: **an AppModel-owned manager is bound to its sibling services
in `AppModel.init`**, never in a view's `onAppear` — binding must not depend on appear order once
deep links can skip the root — so `kilterSessions.bind(...)` moved into `init` (all four services
are AppModel-owned siblings) and the root's now-redundant rebind was deleted (nothing else rebinds).
Stale-session recovery folded into `KilterSessionManager.start` itself: a `recover(in:)` pass runs
before creation (adopt-the-fresh / auto-close-the-abandoned-at-last-activity, replacing the blind
`newestOpenSession` adopt — which would happily adopt a 2-day-old orphan), chosen over a
`KilterPlanView.task` recover because the fold applies the #54 policy on EVERY path that can start
a session: root entry, the plan deep link, a BLE connect, and the QR path (#75) tomorrow. New
`KilterSessionStartRecoveryTests` (in-memory store, deliberately **unbound** manager) assert
adopt-not-fork, abandoned-auto-close-then-fresh-start, duplicate-close-adopt-newest, and the
already-current no-op. (2) the "Resume <routine>" card landed on the workout dashboard with the
player **closed** — the player is a `fullScreenCover` on `WorkoutHomeView`'s local `@State`, which
no pushed route can open — so `SuiteRouter` carries the intent: a one-shot `pendingWorkoutResume`
flag the card sets before `open(module:)`, consumed in the view's `.task` through the **existing**
`resume(_:)` path (cold-relaunch live-metrics + Live-Activity restart logic for free); the flag
always self-clears and is a no-op when no active session exists. (3) Today cards froze across
midnight ("Streak safe for today" survived into tomorrow): every derivation read `.now` inline at
render time, so nothing invalidated at the day boundary — the clock now lives in `@State var now`,
feeding `todayCards` AND `todayStart` (so the stat tiles / week chart / streak roll too), refreshed
on `.NSCalendarDayChanged` (received on main — the OS posts it on a background thread) and on
scenePhase `.active` (covers the suspended-overnight resume the notification can miss). (4) the
flagship hero zoom-animated from the WRONG card: the destination's
`.navigationTransition(.zoom(sourceID: route.id))` always claimed the grid card's source, so a hero
tap zoomed out of the `moduleCard.workout` tile right below it. Chosen shape (not the plain-push
fallback): `ModuleRoute` carries an optional `zoomSourceID` recording the `matchedTransitionSource`
actually tapped — grid card = the module id (byte-for-byte the old pairing), hero = its own new
`flagship-hero` source (reversing this entry's "no second source" stance: the conflict is two
sources claiming one *id*, distinct ids coexist fine) — and `nil` (programmatic `open(module:)`
deep links, the Pomodoro re-entry chip) gets a plain push, since zooming out of a card the user
never tapped reads wrong (the chip had this same wrong-source bug latently). The per-route `if let`
around `.navigationTransition` is stable for a pushed value's lifetime, so a destination's
transition can't change identity mid-flight. (5) the hero's secondary "Or browse all 9 apps" action
had no knowledge-graph edge — added `home → tab-apps` (navigate, "hero: browse all apps").

**Verified off-device**: all changed files parse; `xcodegen generate` clean; `TodayDigestTests`
added (in-memory `ModelContainer` held for the test's lifetime — the documented gotcha — with an
injected fixed UTC clock so month-proration numbers are exact). **Simulator-pending (orchestrator)**:
the two-level Kilter push, the three acceptance-criteria card routes, the fresh-install hero → reels
onboarding, and the full XCUITest suite (smoke / journal tab-switch / kilter `apps` launches).

## [2026-06-10] iOS — suite backup/restore as explicit versioned Rows; the corrupt-store fallback becomes visible (#68)

**Decision** (prompt 47, the iOS mirror of Android #84): the suite backup is ONE versioned JSON
file of **explicit per-model Rows**, not a storage-level dump — SwiftData hides its SQLite, so
the Android schema-agnostic trick is unavailable. Each `SnappetSchema` model gets a
`Codable & Hashable` mirror of its *stored* properties in `Core/SnappetBackup.swift`; the drift
hazard that creates (a new `@Model` silently missing from backups) is fenced by a **tripwire
test** — `SnappetBackup.coveredModels` must equal `SnappetSchema.models` or
`SnappetBackupTests` fails — plus an integrator note on `SnappetSchema` itself.

- **Rows restore raw, not through enums.** `make()` writes `sportRaw`/`statusRaw`/
  `kindRaw`/… directly (and un-pins `ClipEdit`/`StudioProject.updatedAt`, which their inits
  force to `createdAt`) so a stored value the current enum doesn't know survives a round trip
  verbatim. The model inits launder; a backup must not.
- **Dates ride `deferredToDate`** (Double seconds since reference date): the only encoding
  that round-trips a `Date` bit-exactly. ISO-8601 is for the human-facing per-module exports
  (`ModuleExports`), where sub-second loss is fine; the backup is held to exact equality in
  tests.
- **HR series at full fidelity, compact JSON** (the issue's iCloud-size caveat): downsampling
  a backup corrupts the source of truth, so size is managed by *encoding* (`sortedKeys`, no
  pretty-print, no escaping-slashes) — ~100 bytes/sample ⇒ a few hundred KB per hour-long
  session; the backup-section footer says the file can be a few MB. Rows are sorted by stable
  keys so the same store always encodes to the same bytes (diffable; re-export equality is a
  test).
- **Replace-everything in one save**: decode-validate the whole file first (strict `kind`
  sentinel + same-`formatVersion` — the #84 shared decision; cross-version restore stays the
  migrate-and-re-export pipeline's job), then delete-all + insert-all + a single
  `context.save()`, `rollback()` on throw. One save keeps old/new unique-key overlap
  (`KilterFavorite.climbUUID`, `KilterSession.id`) inside one transaction — covered by a
  dedicated test.
- **Reset ≠ container swap.** When the store fell back to in-memory, the banner's Reset
  deletes `default.store(-shm,-wal)` so the **next** launch starts fresh, then tells the user
  to quit and reopen. A live `ModelContainer` swap was rejected: `RootShell` builds
  `SnappetCore` from the old container's context once (and #71 owns RootShell — its hoist
  shouldn't collide with a re-wiring), so swapped-under views would keep writing into the dead
  container. Restoring *while* in fallback works but is honestly footnoted as
  lost-on-relaunch.
- **Entry points stay out of the #71 blast radius**: one toolbar button on `AppLibraryView`
  (sheet), and the banner mounts in `SnappetApp` via `safeAreaInset` — `RootShell` untouched.
  `BackupView` logs usage by inserting `UsageRecord` directly (the banner path has no
  `SnappetCore` in the environment).
- `-uiTestCorruptStore` follows the `-uiTest*` hook pattern (the real `try?` failure can't be
  forced from a test); `BackupUITests` asserts the banner + recovery actions. The UI test taps
  Reset only up to its confirm dialog — confirming would delete the simulator's real store.

**Accepted residuals**: strict same-version import means backups don't outlive a future format
bump (migrate-on-import is the v2-era follow-up, as on Android); the Files-picker round trip
itself is system UI (not XCUITest-automatable) — the codec contract is what's locked by tests;
and the backup covers Snappet's **database** only — UserDefaults-resident settings
(`UserHRProfile`, `expense.myName`, band pairing, Kilter prefs) and the highlight-feedback
JSONL are outside the envelope (feedback has its own export row, and the backup footer scopes
its claim to records accordingly — review fix 6 below).

**Verified off-device**: `xcodegen generate` clean; all new/changed files parse. Simulator
suite (`SnappetBackupTests`, `ModuleExportsTests`, `StoreRecoveryTests`, `BackupUITests`) is
run by the orchestrator. Device-pending: a real Files/iCloud Drive export+restore round trip.

**Post-suite fix (same day)**: `BackupUITests`' banner assertions failed because a bare
`.accessibilityIdentifier("store.health.banner")` on the banner's VStack **propagates to every
child accessibility element**, clobbering the buttons' `store.health.restore`/`store.health.reset`
ids (XCUITest saw both buttons as `store.health.banner`). Fix: `.accessibilityElement(children:
.contain)` before the container identifier — the banner becomes its own named container and the
children keep their ids. Rule of thumb: never put a bare `accessibilityIdentifier` on a container
whose children also carry identifiers. (The same suite run's six "Test crashed with signal kill"
failures were environmental — a second agent's `xcodebuild test` drove the SAME simulator UDID
concurrently, and each run's app launch terminates the other's app instance; the tests pass in
isolation. Reserve distinct simulator UDIDs per agent.)

**Pre-merge adversarial review round** (7 confirmed classes, all fixed): (1) backup-in-fallback
exported the EMPTY in-memory store — a panicked user could "back up" 0 records, then reset their
real store believing they were covered. Rule: **fallback gates every export path** — the suite
button and all per-module rows disable (footers say a backup/export made now would not contain
saved data; the feedback row gates uniformly even though its JSONL is disk-resident — one rule
in that state), `backUpEverything()` belt-and-braces a `.failure` early-return, and the App
Library entry point now derives `storeIsFallback` from `StoreHealth` (injected via the
environment in `SnappetApp`) instead of defaulting to healthy — the banner wasn't the only door
in. (2) restore deleted rows under the LIVE `KilterSession` held by the AppModel-owned manager —
later writes would trap on the deleted `@Model` (or resurrect zombie rows) and the Live Activity
kept counting. Rule: **detach before restore** — `KilterSessionManager.detachForStoreRestore()`
nils `current` + active-climb state, stops live metrics only when this session owns them, ends
the Live Activity, and deliberately writes NOTHING to the store (the rows are about to be
deleted); `recover(in:)` re-adopts whatever open session the restored data carries on the next
Kilter entry (the #54 semantics; locked by a unit test). Audit: the manager is the only
AppModel-level `@Model` holder — the workout player's `playing` is view-local `@State` on
`WorkoutHomeView`, unreachable while the backup sheet is presented (`LiveMetricsCoordinator`
copies values, never the session). (3) restoring while in fallback restored into the in-memory
store but reported an unqualified "Restored N records" — the data silently vanished on relaunch.
The confirm dialog and the success message now say temporary/lost-on-close and spell out the
real path (reset → relaunch → restore), and the banner leads with **Reset storage** (prominent)
while demoting restore to "Preview a backup" — reset-then-restore is the recovery story the
banner advertises. (4) `ModuleExports`' three `Dictionary(uniqueKeysWithValues:)` constructors
trapped on duplicate FK ids, which a tampered/hand-duplicated backup can legally carry — all
three are now first-wins (`uniquingKeysWith`), and **restore dedupes id-bearing rows first-wins**
so duplicates never enter the store at all (rows with no natural identity — UsageRecord,
JournalEntry, HabitCompletion, … — insert as-is; duplicates there are valid data). Restore-side
dedupe was chosen over reject-at-decode: a duplicated file is still the user's data, and
refusing the whole restore over one row punishes them. (5) the drift tripwire guarded only half
the codec: a model added to the schema + `coveredModels` but not File/snapshot/restore passed
the tests while restore DELETED its rows without re-inserting. Restore's deletes are now
hand-listed per model beside their inserts (future drift fails SAFE — rows survive), and the
round-trip test asserts every covered model has ≥1 seeded row AND that `File.recordCount`
equals an independent `fetchCount`-over-`coveredModels` total, before and after restore. (6)
the backup footer overclaimed "every module's data" while UserDefaults-resident settings and
the highlight-feedback JSONL aren't in the envelope — copy now scopes the claim to Snappet's
database and points at the separate feedback export (residual recorded above). (7) import
parsed the whole file TWICE (`JSONDecoder` pays the full parse even for the two-key version
probe) and ran read+decode synchronously on the main actor — a multi-MB HR-heavy backup froze
the sheet. `decode` now full-parses ONCE in the happy path (the probe only classifies
failures), and `handlePickedBackup` reads + decodes in a detached task (security-scoped access
bracketing the read inside it, `File`/rows explicitly `Sendable`), storing the decoded `File`
for both the preview and `runRestore`; the restore itself stays on the main context. New/changed
tests: seeded-coverage + recordCount-vs-store assertions in the round trip, duplicate-id
restore dedupe (first-wins across `Habit`/`KilterSession`/`KilterFavorite`), the
detach-then-recover lifecycle, the CSV duplicate-id no-crash case, and the fallback UI test now
asserts the export buttons are disabled while restore stays enabled.

## [2026-06-11] iOS — fitness IA cleanup: Gym Tracker rename, text segments, module-level Video Studio entry (#74)

**Context.** The App Library showed two near-identically named fitness cards — "Workout Reels" and
"Workout" — side by side; after an Apple Watch run the natural tap was "Workout", which is the gym
tracker. The tracker's five-section control was icon-only SF Symbols (titles existed only as
accessibility labels), Settings hid *inside* the section control, and the CapCut-style multi-clip
studio was reachable only via a "Open studio (multi-clip)" button four levels deep — no module
surface mentioned a video editor exists. Prompt 48.

**Decisions.**
- **Rename the display title only, never the id.** `WorkoutTrackerModule.title` becomes
  "Gym Tracker" (subtitle: "Routines, sets, PRs & a video studio") while `id` stays
  `"workout-log"` — it keys persisted `UsageRecord.module` rows, `ModuleRoute` deep links, and
  the accent mapping; renaming it would orphan history. A unit test pins both the id and the
  title disambiguation (`StudioEntryTests.testFitnessModuleTitlesAreDistinctAndIdsStable`).
  Home's activity-feed rows now caption with the **registry display title** (falling back to the
  capitalized raw id for retired modules) so old `workout-log` records read "Gym Tracker", not
  "Workout-Log".
- **Text segments over a custom control.** SwiftUI's segmented style can't mix icon+text, so the
  segments became `Text(segmentTitle)` — staying on the native `Picker(.segmented)` keeps the
  control under `app.segmentedControls.buttons[<title>]`, which is exactly how the four
  walkthrough/UI tests already address it, so "Exercises/Routines/History" taps needed no test
  changes. A custom HStack control would have labeled segments too but silently broken every
  `segmentedControls` query.
- **Settings = toolbar gear → pushed route**, not a fifth segment. `WorkoutSettingsRoute` +
  `navigationDestination` (a sheet would break `WorkoutSettingsView`'s pushes into
  `UserHRProfileView` / custom-exercise detail). Known trade-off: the live-workout banner
  (`safeAreaInset` on `WorkoutHomeView`) is not visible *on the pushed Settings screen* — it was
  while Settings was a segment; the player remains one back-tap + banner-tap away and the Live
  Activity still shows. Both walkthrough tests now tap `workout.settings` instead of a Settings
  segment.
- **Module-level studio entry via a pure core.** `StudioEntry` (new) owns candidates
  (newest-first video-bearing sessions, default cap 3 — the dashboard is a summary, not a second
  History), `videoSessionIDs` (History badge + leading-swipe shortcut), capture-ordered
  `seedClips`, and the **single** `findOrCreateProject` SwiftData edge — extracted from
  `SessionDetailView.openStudio` so the dashboard card, the History swipe, and the detail button
  all resume the *same* `StudioProject`. Selection/seeding is unit-tested without a simulator;
  photos never count (the studio's main track seeds from videos). The dashboard card renders a
  how-to hint when no session has video yet, so the studio is discoverable before any clip
  exists; the session-detail button is renamed "Edit in Video Studio" (identifier `openStudio`
  kept for the walkthrough).
- **Cross-links both ways, cheap rows not banners.** The tracker dashboard's last row — shown on
  the empty state too, which is exactly where the misdirected after-a-watch-run tap lands — opens
  Workout Reels via `router.open(module: "workout")`; the Reels list gets a mirrored footer row to
  Gym Tracker (hidden while its empty-state recovery overlay is up, which would render over it).

## [2026-06-11] iOS — Kilter's headline features un-buried: visible session/create, auto-start on log, Download-first gate, HR-profile doors, snappet:// registered (#75)

**Decision** (prompt 49, iOS Wave 2; the iOS sibling of Android #94): the platform's differentiated
Kilter features stop hiding behind the unlabeled ellipsis menu, and the two "silently worse" paths
(idle logging, default HR ceiling) now say so and offer the fix inline.

- **Session lifecycle is first-class, owned by the bars.** The slot between the filter chips and
  the list belongs to the session: the green live bar when active (unchanged), a new
  `idleSessionBar` when not — one-line value pitch + a prominent **Start session**
  (`kilter.session.start`). Start/end left the More menu entirely (the bars own the lifecycle;
  a menu copy would just be a second, staler door). **Create climb is a visible `+` toolbar
  button** (id `kilter.create` preserved), the iOS equivalent of Android #94's extended FAB; More
  keeps plan / surprise / scan / settings, and the Mine empty state points at `+`.
- **First log with no session auto-starts one** (source `"auto"`, matching the BLE-connect
  behavior) instead of silently inserting `sessionId: nil` — the climber was forfeiting live HR,
  the Live Activity, per-climb timing, media tagging, the summary and the reel with no prompt.
  Auto-start over an ask-first prompt: logging happens mid-climb with chalky hands, and the #54
  policy makes it safe (the fold of `recover` into `start` adopts an open session rather than
  forking). `start` now reports **created-fresh vs adopted** (`@discardableResult Bool`) and the
  undoable "Session started" capsule is offered ONLY for a fresh creation — undoing an adopted
  session would delete real history. `undoStart(in:)` keeps the logs (detached to `sessionId =
  nil`, the exact pre-#75 idle shape), stops live metrics only if this start owned them, ends the
  Live Activity, deletes the row. Covered by `KilterSessionAutoStartTests` (in-memory store,
  unbound manager — the `KilterSessionStartRecoveryTests` harness).
- **Reversal recorded — "file-import primary" (iOS first-run gate), mirroring Android #94.** The
  [2026-06-10] Android entry's reasoning applies verbatim: Import-prominent buried the only path
  most phone users can act on, and the caption's "boardlib tool — see tools/kilter" + the stale
  "your account is optional" (the download is an accountless user-hosted static file) were
  repo-artifact copy. Now **Download from Kilter leads** (filled, first), Import is the outlined
  secondary, and the caption explains both paths in user terms. Everything carrying the legal
  posture is unchanged: ToU notice + link before any fetch, user-controlled host, no Aurora API.
- **The shared HR profile gets a Kilter front door.** `KilterSettingsView` links the same
  app-global `UserHRProfileView` the workout tracker uses (one editor, one store — nothing moved),
  and the session summary's HR card shows "Zones use a default 190 bpm ceiling — set up your
  heart-rate profile" exactly while its ceiling falls through to the default. To make that
  affordance honest, the summary's ceiling now resolves session snapshot → **live profile** →
  `defaultMaxHR` (previously snapshot → default): filling the profile from the affordance
  personalizes the visible card immediately, and a pre-profile session's zones re-score under the
  better ceiling (its `maxHR == nil` snapshot meant "never knew", not "knew it was 190").
- **The `snappet://` deferral (2026-06-05) is un-deferred** — the #71 SuiteRouter hoist it waited
  on landed. `CFBundleURLTypes` lives in the checked-in `Resources/Info.plist` (what
  `INFOPLIST_FILE` points at; `GENERATE_INFOPLIST_FILE: NO` — so "register via project.yml"
  resolves to the plist file, never the .xcodeproj). `RootShell.onOpenURL` → pure `SnappetDeepLink`
  route table → one-shot `SuiteRouter.pendingKilterClimb` + `open(module: "kilter")` (the
  `pendingWorkoutResume` pattern): the shell can't push the climb itself because the push needs the
  Kilter root's `navigationDestination` + catalog knowledge. The root consumes the intent with
  `.onChange(initial: true)` (cold start: intent set before the root exists; warm: set while it's
  up), runs `recover` first (#54), and routes through the pure
  `KilterDeepLinkRouting.destination(for:climbInstalled:availableAngles:)` — angle adopted only
  when this board offers it; an unresolvable climb gets a **graceful "not in your catalog" alert**
  (reads correctly over the catalog gate too). The in-app scanner now routes through the same
  decision, fixing its silent dead-end push for un-installed climbs. While here: the Info.plist
  carried TWO `NSCameraUsageDescription` keys (receipts vs QR — a plist dict keeps one); merged
  into a single description covering both uses.

**Verified off-device**: `xcodegen generate` clean; all changed files parse; `plutil -lint` clean;
graph data.js node/edge audit clean. **Simulator-pending (orchestrator)**: unit
(`SnappetDeepLinkRouteTests`, `KilterSessionAutoStartTests`) + updated `KilterSessionLifecycleTests`
(drives the visible Start control), and the deep-link acceptance check —
`xcrun simctl openurl booted "snappet://kilter/climb/<uuid>?angle=40"` warm and after
`simctl terminate` (cold), plus an unknown uuid for the graceful landing. **Device-pending**: a real
Camera-app QR scan, BLE auto-start parity, live HR/Live Activity in an auto-started session.

## [2026-06-15] iOS — create-a-climb lifecycle: edit / rename / delete + live grade estimate (#76)

**Decision** (prompt 50): close the authoring loop and feed setters a grade while they build.

- **Live manual grade estimate.** Pure `KilterClimbGenerator.holdTokens` (maps each placed
  `(placementId, role)` through the model vocab `HOLD_<placementId>_<roleId>`, dropping out-of-vocab
  holds) + `estimateManualGrade` (nil when nothing resolves). The chip loads **only the generator
  meta** and only when already installed — authoring never triggers the 9 MB model download. Labeled a
  model estimate; reactive to hold placement.
- **Edit = re-derive identity.** The content uuid (`KilterClimbIdentity`) is unchanged, so editing holds
  is by construction a *new* climb. `CreateClimbView` gains `editing:`; on save, unchanged holds update
  the row in place (rename / angle / no-match / re-grade), changed holds **migrate** the climb's logged
  ascents (and its favorite, respecting the unique `climbUUID`) to the new uuid and delete the old row.
  The duplicate check excludes the climb being edited so re-saving its own holds isn't a self-duplicate.
  Seeding the editor guards the `layoutId`-change hold-clear with a one-shot flag.
- **Delete keeps the ascents.** `KilterLogEntry.climbName` is a stored snapshot, so a deleted climb's
  logged sends stay readable in History as orphans — delete the climb row + a stale favorite, keep the
  logs, confirm with the kept-ascents count. **Accepted residual:** an orphaned log's detail-by-uuid no
  longer resolves to a climb; History (which reads the snapshot) is unaffected, and Mine no longer lists
  it. One shared `KilterCreatedClimb.delete(_:in:)` backs both the detail screen and the Mine swipe so
  the policy can't drift. Removing the row also frees the duplicate checker from trapping users against a
  climb they deleted (the AC's third bullet falls out for free).

**`#Predicate` gotcha (re-)recorded.** A `#Predicate` can't capture a model **property access**
(`climb.uuid`) — the macro reads it as another model keypath and fails to type-check. Hoist to a local
`let uuid = climb.uuid` first. (Same class as the SwiftData container-retain gotcha — silent at
`swiftc -parse`, only a real build catches it.)

**Verified**: full simulator suite green incl. new `KilterGradeEstimateTests` (pure estimator + frames
round-trip) and the unchanged `KilterCreateClimbTests` golden UUIDv5 vector (cross-platform dedup with
Android preserved). Reviewed in the main loop (the multi-agent review workflow was rate-limited).

## [2026-06-15] iOS — shared HR chart/zone bar across both session summaries + an in-UI colour legend (#78)

**Decision** (prompt 51): one definition of the heart-rate summary, and make the badge colours legible.

- **Extracted shared components.** `HeartRateChart` + `ZoneBar` move from private structs inside
  `SessionDetailView` to `Features/WorkoutTracker/HeartRateComponents.swift` (internal). Both summaries
  already share `WorkoutHRStats` and `HRPoint` (`KilterSession.hrSeries` is `[HRPoint]`), so no adapter
  was needed — the Kilter summary's raw `.pink`/hidden-axis chart and its hand-rolled `zoneBar` +
  `redlineMinutesLabel` are deleted, and `import Charts` drops from `SessionDetailView` (the grade
  pyramid keeps it in the Kilter file). The engine's resample/smooth is reused — `HighlightEngine` stays
  platform-free.
- **In-UI colour legend.** New `HRMetricsInfoButton` (ⓘ → popover) explains the HRV and recovery-dot
  red/orange/green with the "within-session trend, not a clinical reading" caveat. Its swatch colours
  call `HRVBadge.recoveryColor` / `HREffortBadge.recoveryColor` directly, so the legend can't drift from
  the badge thresholds. Rendered once per summary's Heart-rate header (one legend covers all the
  per-set/per-climb badge instances on that screen) — satisfies "explained at both call sites" for the
  two summary screens.

**Verified**: full simulator suite green; reviewed in the main loop (review workflows rate-limited).
**Accepted residual**: the redline tile label is now "3 min"/"15s" (the shared `ZoneBar.minutesLabel`)
rather than the Kilter file's old "3m"/"15s" — minor, and now consistent with the zone-bar legend.

## [2026-06-15] iOS — accessibility pass: VoiceOver Studio + create-climb board, Dynamic Type, Reduce Motion (#79)

**Decision** (prompt 52): make the two creative features non-visually operable, scale text, and gate
all WorkoutTracker motion.

- **One motion vocabulary.** `Transitions.swift`'s `Motion` now aliases `SnappetMotion`, and the
  `workoutPhase`/`sectionSwap`/`liveBanner` transitions are `reduceMotion:` factories that return
  `.opacity` under Reduce Motion. WorkoutTracker (section swap, player phase, live banner) and the App
  Library focus chip route through the gated helpers. Gotcha recorded: the global
  `snappetAnimation(_:reduceMotion:)` collides by name with the `View.snappetAnimation(_:value:)`
  modifier inside a View body — qualify the global as `Snappet.snappetAnimation(...)`.
- **Dynamic Type** via `@ScaledMetric(relativeTo: .largeTitle)` for the big fixed sizes (countdown 56,
  rest timer 44, done seal 72, brand mark 44); Studio timeline 8/9pt chrome → scaled `.caption2`/`.caption`.
- **Studio VoiceOver.** `diamond.fill` (keyframe) and the undo/redo arrows carry no default labels —
  explicit labels added, plus close/play-pause/title and the timecode. The centre playhead is now an
  `accessibilityAdjustableAction` scrubber (±1 s); the selected clip exposes trim rotor actions
  (`ClipTrimActions`, ±0.5 s per edge) because the 7pt drag handles are invisible to VoiceOver.
- **Create-climb board.** `KilterEditableBoardView` gains a **VoiceOver-gated** per-hole overlay — one
  44pt hittable element per placeable hole, labelled by coarse position (top/middle/bottom × left/centre/
  right) + current role, double-tap cycles the role through the shared `cycle(_:)` (same as the sighted
  near-hit tap). Gated on `accessibilityVoiceOverEnabled` so it never interferes with sighted tapping.

**Accepted residuals / device-pending.** VoiceOver navigation, the adjustable scrubber, the rotor trim
actions, and per-hole board authoring are structurally implemented but can only be verified with
VoiceOver **on a device** (repo's device-pending class). The 7pt timeline trim handles keep their visual
size (enlarging to 44pt would wreck the dense timeline) — VoiceOver trims via the rotor actions instead.

**Verified**: full simulator suite green; reviewed in the main loop (review workflows rate-limited).

## [2026-06-15] iOS — design-consistency sweep + Pulse app icon (#77)

**Decision** (prompt 53): make the suite read as one product past the shell.

- **Module accent one tap deep.** `AppLibraryView.moduleDestination` now applies `.tint(module.tint)`, so
  a module's controls inherit its wayfinding accent inside the module (previously only the library card
  used it). Stray module-chrome system colours were hardcoded as the accent — `.tint(.blue)` in
  Habit/Budget/Expense and `.orange` in `WorkoutDashboardSection` → the module token. Genuinely-semantic
  colours kept (Kilter no-match amber, live-record green).
- **Token card sweep.** The cited hand-rolled `Color(.secondarySystemBackground)` + drifting radii
  (10/12/14/16) become `SnappetColor.surfaceMuted` + `SnappetRadius.md`. **Chose the token+radius swap
  over `.snappetTile()`** deliberately: `snappetTile` applies `SnappetSpacing.lg` (24) padding vs the
  existing `.padding()` (16), which would shift every card's layout and risk the screenshot/UI tests;
  the token swap satisfies the AC (no `secondarySystemBackground`, unified radius) with zero layout shift.
- **Paper canvas** (`SnappetColor.paper.ignoresSafeArea()`) on the Home + App Library shell screens, not
  just the cold-start loading view.
- **Pulse app icon.** Replaced the "S" gradient (the loudest prototype signal) with the
  `waveform.path.ecg` brand mark — the exact glyph the loading view shows — in the three iOS 18
  luminosity slots (light: white on coral→ember, opaque; dark: coral on near-black; tinted: grayscale).
  `generate-pulse-icon.swift` renders the SF Symbol; `Contents.json` declares the appearance slots; the
  asset catalog compiles clean (light icon opaque per App Store).

**Verified**: full simulator suite green; the asset catalog compiles the new appearance slots. Reviewed
in the main loop (review workflows rate-limited). Visual polish verified by eye on the generated icons +
the build; the suite is the regression net for the token/layout changes (no structural change).

## [2026-06-15] iOS — OS integration Phase 1: App Group + widget Today snapshot (read path) (#81)

**Decision** (prompt 54, PR "Part of #81"): open the suite to the OS in four stacked PRs (App Group →
widgets → intents → Spotlight). This first PR builds only the foundation every later phase needs — an
**App Group** and a **read-only snapshot** the `SnappetWidgets` extension can read.

- **Snapshot, NOT the live SwiftData store, in the App Group.** The hard requirement (a home-screen
  widget reading live-ish data, and — Phase 2 — an interactive check-off `AppIntent` writing without
  the app open) needs a place both processes share. Two options were weighed (recorded so it isn't
  re-litigated): **(A)** move the live store into the App Group; **(B)** publish a small versioned
  snapshot the widget reads. **Chose B.** Rationale: it keeps the widget completely isolated from
  `SnappetSchema` (22 `@Model` types, bumped almost every PR — the extension never compiles or
  migrates the model graph); needs **no irreversible store-location migration** (the existing on-disk
  store stays where it is); has **no cross-process SQLite locking**; and is **fully unit-testable
  without a device**. Cost: the widget reflects data as of the last write, and a widget-originated
  mutation reconciles into the canonical store on next app open — handled in Phase 2 via an App-Group
  **outbox** (append-in-widget → drain-into-SwiftData-on-foreground), so the write path stays equally
  schema-isolated.
- **Contract + store live in `Shared/`** (compiled into both targets, the `PomodoroActivityAttributes`
  pattern): `SnappetWidgetSnapshot` (versioned `Codable`, with a **defaulting decoder** so a widget
  reading a snapshot written by an older app build can't crash — the OverlayItem migration discipline)
  and `WidgetSnapshotStore` (the one place that knows the group id `group.com.snappet.app` + file name;
  a **pure** `encode`/`decode` that **rejects a higher `version`** than this binary understands, plus a
  thin file edge over the container that degrades to `nil`/no-op when unprovisioned).
- **Builder reuses the app's pure derivations — same numbers as the app's screens.** `WidgetSnapshotBuilder`
  (pure, app target) builds the snapshot from the same rows the app queries. `dayStreak` is the Home
  dashboard's **suite-engagement** "day streak" (consecutive days ending today with any logged
  `UsageRecord`) — extracted into the shared pure `TodayDigest.activityStreak` that `HomeDashboardView`
  now also routes through, so the widget and Home can't diverge (the issue points the widget's streak at
  HomeDashboardView's logic; it is NOT a per-habit `HabitMilestones` streak). Focus minutes via
  `TodayDigest.focusToday`; "habits remaining" via the same start-of-day "done today" rule as
  `TodayDigest.habitsToday`. `WidgetSnapshotService` (the device edge) fetches + writes +
  `WidgetCenter.reloadAllTimelines()`, wired in `RootShell` on `scenePhase` (per-mutation refreshes land
  with the widget UI in Phase 2), and **no-ops under the `-uiTest*` launch args** so a test run can't
  leak a real snapshot file (see the residual below). No home-screen widget UI ships yet —
  `reloadAllTimelines()` is a no-op until Phase 2 adds one.

**Verified**: `xcodegen generate` clean; the app **and** the watch + widget extension build, code-sign
(simulator), and embed with the new App-Group entitlement (no provisioning failure). Unit suite green
(`WidgetSnapshotTests` ×7: codec round-trip, corrupt/missing-key/future-version back-compat, builder
parity with `TodayDigest`/`HabitMilestones`); full `SnappetTests` 647 passing; UI suite green.
**Accepted residual / device-pending**: the iOS **Simulator DOES provide** the App-Group container (it
just doesn't validate the group against the developer portal), so the `WidgetSnapshotStore` file edge
actually runs on the sim — which is exactly why `WidgetSnapshotService.refresh` is gated off under the
`-uiTest*` args (an unguarded write would persist a real `today-widget-snapshot.json`, leaking across
runs and into the production app on the same sim/device — defeating the in-memory-store isolation those
args promise; caught by the review). What is genuinely **device-pending**: the group must be registered
under the signing team in the portal for a **device/TestFlight** build, and the **home-screen widget
actually rendering** the snapshot (Phase 2) — that pair lands verifiable with the Phase-2 widget UI on
hardware. The builder, codec, and streak/derivation parity — the logic — are sim-verified.

## [2026-06-15] iOS — OS integration Phase 2: Today widget + interactive check-off (#81)

**Decision** (prompt 55, PR "Part of #81"): build the home-screen **Today** widget on Phase 1's read
path — and the interactive habit check-off, the trickiest part of the whole issue.

- **Widget-originated writes go through an App-Group OUTBOX, not SwiftData.** An interactive widget
  `AppIntent` runs OUTSIDE the app process and can't touch the SwiftData store. So `ToggleHabitIntent`
  (in `Shared/`, `openAppWhenRun = false`) records the desired check-off state to the App Group and
  optimistically rewrites the snapshot (the widget reflects the tap instantly); the **app is the sole
  writer of the canonical store**, draining + reconciling the outbox on its next foreground. This keeps
  the write path as schema-isolated as the read path (the extension never compiles/migrates `@Model`s).
- **Outbox = a DIRECTORY of one-file-per-toggle**, not a single mutated file. Appending is writing a
  new uniquely-named file (`<toggleID>.json`), so the widget process and the app process never do a
  cross-process read-modify-write on one file (no lost-update race) — the lock-free outbox pattern.
  `WidgetOutbox.pending()` reads (sorted by request time), `remove(ids:)` deletes only what was
  applied.
- **Reconciliation is pure + idempotent + order-tolerant.** `HabitCheckoffReconciler.plan(toggles:
  existing:)` records the ABSOLUTE desired state per toggle and folds to the **last desired state per
  (habitID, day)** (a toggle-on-then-off nets to off), emitting inserts only when desired-and-absent
  and deletes only when not-desired-and-present (a state already in sync is a no-op). `WidgetSnapshot
  Service.refresh` applies the plan, saves, and removes the outbox files **only after a successful
  save** — so a save failure loses nothing and the idempotent plan safely retries next foreground.
  Still gated off under `-uiTest*`.
- **"Start focus" reuses the deep-link plumbing**, not a bespoke intent: the widget's button is a
  `Link(snappet://pomodoro/start)`; `SnappetDeepLink.startFocus` (pure, unit-tested route) →
  `RootShell.onOpenURL` → `SuiteRouter.pendingPomodoroStart` (the `pendingKilterClimb` one-shot
  pattern) → `PomodoroRootView` starts the app-owned `AppModel.pomodoro` engine on appear/change. The
  Siri `StartPomodoro` AppShortcut comes in Phase 3.
- **Widget uses plain SwiftUI colours**, not `SnappetColor` — the design-token files aren't compiled
  into the extension (only `Shared/` is, like the Live Activity widgets). Gotcha recorded.
- **Day-staleness is resolved at the read edge** (adversarial-review fix): the widget is read-only and
  only the app rewrites the snapshot file, so after midnight a snapshot still says "all done" /
  yesterday's streak. `SnappetWidgetSnapshot.resolvedForDisplay(now:)` (pure, tested) neutralises a
  snapshot whose `dayStart != today` (habits read not-done, focus 0, streak 0, dayStart stamped today);
  `TodayProvider` and `ToggleHabitIntent` both apply it — so the widget never shows yesterday's checks,
  and a first tap after midnight can't compute a stale `desired` and silently no-op.
- **Widget check-off mirrors the in-app activity log** (review fix): the in-app toggle logs a
  `UsageRecord` on check-ON, and that — not `HabitCompletion` — is what `TodayDigest.activityStreak`
  (the streak the widget headlines) counts. So `reconcileOutbox` inserts the `UsageRecord` too
  (`action: "done"`, stamped at the toggle's tap time so it credits the right day), only for inserts
  (check-ON), matching the in-app rule.
- **Orphan guard** (review fix): the pure planner takes `liveHabitIDs` and drops a check-ON for a habit
  that no longer exists (a stale snapshot the user tapped), so reconciliation can't leave a dangling
  `HabitCompletion` for a deleted habit.
- **Widget uses plain SwiftUI colours**, not `SnappetColor` — the design-token files aren't compiled
  into the extension (only `Shared/` is, like the Live Activity widgets). Gotcha recorded.
- Swift-6 gotcha: an `AppIntent`'s `static title/description/openAppWhenRun` must be `static let` (not
  `var`) or strict concurrency rejects them as nonisolated mutable global state.

**Verified**: clean build; app + watch + widget build/sign/embed; `WidgetOutboxTests` (HabitToggle
codec + the reconciler truth table — insert/delete/no-op/last-write-wins/order-independence/day-
normalisation/orphan-drop/loggedAt) + `WidgetSnapshotTests` (resolvedForDisplay staleness) + the
extended `SnappetDeepLink` route tests green; full `SnappetTests` 665 passing; UI suite green;
`xcrun simctl openurl snappet://pomodoro/start` routes to Snappet. **3-lens adversarial review** caught
4 real findings (the day-staleness silent-no-op, the missing UsageRecord streak credit, the orphan
completions), all fixed above.
**Device-pending**: the widget actually rendering on the springboard + a real check-off tap firing the
AppIntent are best confirmed on hardware (the sim verifies the snapshot read, outbox round-trip,
reconciliation, staleness handling, and the deep link).

## [2026-06-15] iOS — OS integration Phase 3: Siri / Shortcuts App Shortcuts (#81)

**Decision** (prompt 56, PR "Part of #81"): give the suite a voice + Shortcuts presence with App
Shortcuts — **reusing Phase 2's two cross-process channels, not inventing a third**.

- **Two intent shapes, mapped to the two existing channels.** `CheckOffHabitIntent` is `openAppWhenRun
  = false` and writes the Phase-2 **outbox** (`WidgetOutbox`, `desired: true`) + optimistic snapshot —
  so "check off Read" persists with the app closed, and the app's foreground reconcile (which now also
  logs the streak `UsageRecord`) credits it. The "open-app-and-act" intents (`StartPomodoroIntent`,
  `OpenModuleIntent`, `QuickJournalIntent`, `StartRoutineIntent`) are `openAppWhenRun = true` and
  enqueue a typed `PendingAppAction` to a new App-Group **inbox** (`AppActionInbox`, the same race-free
  directory-of-one-file-per-record pattern as the outbox); `RootShell` drains it on first build +
  scenePhase `.active` and dispatches through the **existing `SuiteRouter`** deep-link plumbing (the
  `pendingPomodoroStart` / `open(module:)` paths the `snappet://` URLs use). The drain is gated off
  under `-uiTest*` so a stale inbox file can't navigate a test run.
- **Habits are a `HabitEntity` read from the snapshot.** `CheckOffHabitIntent`'s `@Parameter` is a
  `HabitEntity` whose `EntityStringQuery` reads `WidgetSnapshotStore.read()?.habits` — so Siri/Shortcuts
  resolves a habit by name OFF-PROCESS, no SwiftData, consistent with the rest of the widget surface.
- **`AppShortcutsProvider` lives in the app target** (the system discovers it in the main bundle); the
  intents + entity live in `Shared/` (compiled into app + widget) so the provider can reference them.
- **QuickJournal** opens a prefilled new entry via a `SuiteRouter.pendingJournalCompose` one-shot
  consumed by `JournalRootView` (the `pendingPomodoroStart` pattern); a dictated note has a non-empty
  body so it survives the abandoned-blank sweep (the capture persists even if the user backs out).
- **Accepted residual**: `StartRoutineIntent` opens the gym tracker (`workout-log`) rather than
  auto-launching a *named* routine — resolving a `RoutineEntity` and driving the full-screen player's
  start path from a cold deep-link is a larger lift, deferred (recorded here, not silently dropped).

- **Dispatch is a pure, tested mapping** (review fix): the action→navigation decision (which module to
  open + the one-shot flags, incl. the `startRoutine → "workout-log"` literal) lives in the pure
  `AppActionRouter.route(for:)`, unit-tested per case; `RootShell.dispatch` is just glue that applies
  it via `SuiteRouter`. So the module-id literals aren't re-hardcoded untested in the view (the review
  caught that the earlier inline switch was unguarded, and that an earlier draft of this entry
  overclaimed the dispatch was sim-verified).

**Verified**: clean build (app + watch + widget; the intents/`AppEntity`/`AppEnum`/`AppShortcutsProvider`
all compile + register); `AppActionInboxTests` (PendingAppAction codec per case, `AppActionRouter` route
per case incl. `startRoutine`/`startPomodoro`, ModuleChoice→id map, HabitEntity mapping) + full
`SnappetTests` green; UI suite green.
**Device-pending**: actual Siri-phrase invocation, the Shortcuts-app gallery listing, and shortcut
donation are confirmable only on a device — the sim verifies the serialisable contracts, the
inbox/outbox round-trips, and the pure action→route dispatch mapping (the in-app navigation glue that
applies it is the thin untested edge, mirroring the `onOpenURL` one-shots).

## [2026-06-15] iOS — OS integration Phase 4: Spotlight indexing + deep-link routing (#81, FINAL phase)

**Decision** (prompt 57, PR "Fixes #81"): index the suite's content in Spotlight, reusing the
`snappet://` routing so a result tap lands on the right screen with no new routing brain — closing #81.

- **The Spotlight identifier IS the deep-link URL.** Each `CSSearchableItem`'s `uniqueIdentifier` is its
  `snappet://` URL; a tap arrives via `.onContinueUserActivity(CSSearchableItemActionType)` carrying
  that identifier, which `RootShell` turns back into a `URL` and routes through the SAME `handle(_:)` as
  `onOpenURL`. So QR / widget / Siri / Spotlight all share one router. `RootShell`'s `onOpenURL` switch
  was extracted into `handle(_:)` for this reuse.
- **What's indexed (the AC = "an exercise or climb name"):** the 873-exercise catalog
  (`snappet://exercise/<id>` → resolve from `ExerciseCatalog.all` → open `workout-log` + push the
  `Exercise` detail, the two-level deep-link pattern) and the user's **created climbs**
  (`KilterCreatedClimb`) — which reuse the EXISTING `snappet://kilter/climb/<uuid>` route entirely (it
  already resolves user-created climbs), so they need NO new routing.
- **Pure spec, thin edge.** `SpotlightCatalog` (pure) builds `SpotlightItemSpec`s (identifier/domain/
  title/description/keywords) — unit-tested incl. that each identifier round-trips back to its route;
  `SpotlightIndexer` is the CoreSpotlight edge (`CSSearchableIndex.indexSearchableItems`), run once on
  launch (the index dedupes by identifier) and gated off under `-uiTest*`.
- **Deleted created climbs are de-indexed** (review fix): `indexSearchableItems` is additive (it never
  evicts), and the fixed catalog self-heals on re-index but a deleted *user* climb wouldn't — so
  `KilterCreatedClimb.delete` calls `SpotlightIndexer.deindexCreatedClimb(uuid:angle:)`
  (`deleteSearchableItems` by the same identifier `SpotlightCatalog.createdClimbIdentifier` builds, one
  source of truth). Without it a deleted climb stayed permanently searchable (a tap landed gracefully on
  the "not in your catalog" alert, but a stale result is a UX wart). Caught by the adversarial review.
- **Accepted residual**: **journal entries are not indexed** — `JournalEntry` has no stable id, so it
  would need a schema migration (+ a `SnappetBackup` row + the tripwire test). The AC is exercise/climb;
  journal Spotlight is a small, clean follow-up once `JournalEntry` gains a `uuid`. (Custom exercises —
  `CustomExercise` — are likewise a follow-up; the built-in catalog covers the AC.)

**Verified**: clean build (app + watch + widget); `SpotlightIndexTests` (exercise + created-climb spec
ids/fields, identifier→route round-trip, the `snappet://exercise/<id>` parse + malformed rejection) +
full `SnappetTests` 680 green; UI suite green. **Device-pending**: real Spotlight index visibility +
a Spotlight-result tap → `onContinueUserActivity` (the sim verifies the specs, the route parse, the
index call, and `simctl openurl` delivery). With this, **#81 is complete** (4 stacked PRs:
App Group → widgets → App Intents → Spotlight); the #100 iOS tracker box is checked.

## 2026-06-15 — Flagship P1 device validation + reel-export mixed-orientation fix (prompt 58, #139)

Ran the long-deferred P1 on a physical iPhone (the flagship's first real-device run). Outcome: the
whole reel flow works — permissions, workout load, media auto-discovery, HR/Fusion reel, preview,
**export** — and produced the **first real `highlight-feedback.jsonl`** (73 events; `feedback-replay`
ranks 3 real configs). This satisfies the "do NOT start #83 before flagship device validation"
prerequisite.

**Bug found + fixed:** `ReelExporter` exported an `AVMutableComposition` with **no `AVVideoComposition`**.
A reel mixing clip dimensions/orientations failed on device with `AVFoundationErrorDomain -11800` /
underlying `NSOSStatusErrorDomain -12902` — the exporter can't resolve one output format across segments.
Invisible on the simulator (no real footage), which is exactly why P1 device validation existed.

- **Decision**: build a normalizing `AVMutableVideoComposition` in `ReelExporter.makeComposition`
  (now returns `(AVMutableComposition, AVVideoComposition?)`): render canvas = the first segment's
  oriented size (even dims); one instruction with a **piecewise `setTransform` per segment** that orients
  (`preferredTransform`) then aspect-fits/centers (letterbox) into the canvas. Applied to **both** export
  (`session.videoComposition`) and preview (`AVPlayerItem.videoComposition`) so they match. Mirrors what
  `VideoStudio` already did for the single-clip editor; the flagship exporter never got it. Engine
  untouched (platform edge stays in Services/).
- **Decision**: export failures now `os_log` the AVFoundation domain/code/underlying (developer/Console
  only); the user-facing message stays the clean `localizedDescription`. The bare "operation could not be
  completed" was undiagnosable — the logged `-12902` is what pinned the cause.
- **Device-pending residual**: render-canvas choice = first segment's orientation. A reel whose first clip
  is landscape pillarboxes portrait clips (and vice-versa); acceptable (no distortion). A smarter
  majority-orientation or fixed-portrait canvas is a future tuning call, not a correctness issue.
- **Signing note (not committed)**: device build needs `project.yml` team → `NFUS5W8QC6` (the working
  paid team; old notes' `8TRC99V9PN`/`HXU7999BJS` are stale) + the time-sensitive entitlement stripped
  locally. Committed `project.yml` is unchanged.

## 2026-06-15 — Feedback-replay scoring ported into HighlightEngine (#83 Step 2, prompt 59, PR A)

The "using the app improves the app" loop dead-ended in a file: `highlight-feedback.jsonl` was only
replayable by the off-device Python harness, and `FeedbackStore.exportAll()` had zero callers. Ported
the replay scoring into `HighlightEngine` as pure Swift (`FeedbackReplay`), mirroring
`experiments/feedback-replay/replay.py` field-for-field.

- **Decision**: parity is enforced by test, not eyeballed. Bundled the harness's seeded output
  (`synth_feedback.generate(Random(42))`, 277 events) as a test resource
  (`Fixtures/synthetic-feedback.jsonl`), decoded through the engine's OWN `HighlightFeedbackEvent`
  Codable, replayed in Swift, and asserted against replay.py's golden numbers (e.g.
  `sm9_lag6_l60_s40_g20`: satisfaction 0.877778, effort_mix 0.681818) + recommendation text. If the two
  ever drift, the suite fails. Re-derive the golden with `python3 run.py` if replay.py changes.
- **Decision**: the data-driven re-weighting is `FeedbackReplay.tunedWeighting(from:)` — HR-vs-scene
  split where HR weight tracks the best config's empirical `effort_mix`, both clamped to `[0.2, 0.8]`
  (the blend never collapses to a single signal — honors "don't hardwire HR-only"). Returns `nil` until
  ≥5 endorsements, so **weights change ONLY from replayed feedback** (project.md invariant); no data ⇒
  callers keep gated defaults.
- **Decision**: `AppModel.recomputeFeedbackTuning()` is the on-device edge — reads
  `feedback.exportAll()` (its first caller) on `bootstrap`, replays, stores `feedbackTuning`, and
  `os_log`s the recommendation. **No engine behavior change in this PR**: the scene signal is still 0
  until #83 Step 1 (PR B) wires the Vision scorer, so scaling HR by a constant weight leaves ranking
  identical — gated by design. PR B consumes `feedbackTuning` to weight the now-real scene term.
- **Engine stays platform-free** — `FeedbackReplay` is pure; `swift test` 55 green off-device.

## 2026-06-15 — Vision scene scorer wired into the fusion (#83 Step 1, prompt 60, PR B — closes #83)

`SceneHighlightSelector` returned 0 ("until a real vision pipeline is wired"), so reels were
effectively HR-only and could pick a blurry pocket-shot over the crux. Added a real on-device Vision
scorer; #83's two stacked PRs (Step 2 replay = #141, Step 1 vision = this) complete the moat loop.

- **Decision**: `Services/SceneScorer.swift` is the platform edge — samples video frames
  (`AVAssetImageGenerator`, ≤480 px) and scores each via Vision saliency
  (`VNGenerateAttentionBasedSaliencyImageRequest`) + Core Image sharpness (variance-of-Laplacian) +
  face/human presence. Signals relative-normalized across frames, combined by the PURE `SceneScoring`.
  Only the scalar crosses into the engine via `SceneHighlightSelector.visualScore` — `HighlightEngine`
  stays platform-free (verified: only `import Foundation`; `swift test` 55 green off-device).
- **Decision (scoring model, caught by a failing test)**: sharpness is a **multiplicative gate**
  (`score = sharpness * (0.5 + 0.3·saliency + 0.2·presence)`), not an additive term. The first cut was
  additive and let a salient-but-blurry frame outscore a sharp one — contradicting "penalize blurry."
  Multiplicative makes blur kill the score; content is a `[0.5, 1.0]` multiplier so emptiness is
  penalized too but a sharp subjectless frame isn't zeroed. BOTH blurry and empty are penalized; only
  sharp-AND-has-something wins. Off-device proof: `SceneScorerTests` synthesizes a sharp checkerboard vs
  a flat frame and asserts the real Vision/CI metrics rank them correctly, plus pure-combiner cases.
- **Decision (the invariant)**: the scene term is added to the fusion by `engine(boosting:scene:)`
  **only when `feedbackTuning != nil`** (PR A's replay-derived weighting). No replayed feedback ⇒ no
  scene weight ⇒ blend is exactly today's HR + effort. So visual content changes selection ONLY once the
  user's own feedback earns it (project.md invariant), and the existing effortAligned/achievement-window
  selection can't regress without data. `sceneSelector(for:)` also skips the Vision cost when untuned.
- **Device-pending residual**: real-footage selection *quality* (do the scene picks look right?) is a
  device-verified judgment, not unit-assertable; the fixture proves the scorer penalizes blur/empty.

### Adversarial review of #83 (3-lens + skeptic) — one minor finding, fixed
The parallel review (engine-layering / invariant-regression / correctness lenses + per-finding skeptics)
confirmed the four invariants hold (engine platform-free; replay formulas match Python; scene term gated
behind replayed-feedback tuning; no regression without data). It surfaced ONE minor parity gap:
`FeedbackReplay.ranked()` tie-breaks by `key` while replay.py relied on dict-insertion order, so an
equal-satisfaction tie could pick a different best config — and the parity test never pinned the tie.
Fix: aligned the Python oracle (replay.py + run.py) to the deterministic `(-satisfaction, key)` tie-break
(a Swift Dictionary can't reproduce insertion order, so the key tie-break is canonical) and added
`testRankingTieBreaksByKeyMatchingPython` to pin it (verified Z-before-A → "S | Afp" wins on both sides).
Measure-zero for the shipped fixture (distinct satisfactions), but parity is now drift-proof on ties.

## 2026-06-15 — App Store / TestFlight publishing (prompt 61)

First distribution build shipped to **TestFlight** (internal) under the paid team **`NFUS5W8QC6`**.
The App Store Connect record **"SnappetAI" (App 6779420682)** was pre-created under bundle id
**`com.snappet.app.alpha`** — so the alpha ships under `.alpha`, but the repo's **canonical identity
stays `com.snappet.app`** (user's call). The `.alpha` retarget is a **local overlay**, applied by
`scripts/alpha-build-overlay.sh <build>` and **never committed**.

- **Decision**: commit the genuine, production-correct bundle-validity fixes Apple's first upload
  rejected — `UISupportedInterfaceOrientations~ipad` (all 4, for iPad multitasking) and a watchOS
  `AppIcon` (asset catalog + `ASSETCATALOG_COMPILER_APPICON_NAME` + `CFBundleIconName`); these block any
  App Store build, not just the alpha. Plus release tooling: `ExportOptions.plist`, fastlane `beta`
  lane (archive → TestFlight via an ASC API key from env), and `DEVELOPMENT_TEAM → NFUS5W8QC6` (the old
  free `8TRC99V9PN` is dead; ends the perpetual local team override).
- **Gotcha recorded**: the watch's `WKCompanionAppBundleIdentifier` is a STATIC literal in
  `SnappetWatch/Info.plist`; with `GENERATE_INFOPLIST_FILE: NO` the `INFOPLIST_KEY_…` build setting is
  inert, so the overlay edits the plist directly to match the `.alpha` phone id.
- **Upload pipeline**: `fastlane beta` (build_app → upload_to_testflight) with the API key in env
  (`ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH`); the `.p8` lives in `~/.appstoreconnect/private_keys/`,
  never committed. `altool --upload-app` is the fallback for an already-built `.ipa`.
- **Not done (needs the user / Apple web)**: App Store *review* submission — metadata, screenshots,
  privacy policy URL (mandatory for HealthKit), App Privacy labels, age rating. TestFlight internal
  testing needs none of these.

## 2026-06-15 — Workout-with-timer PR 1: a shared, wall-clock stopwatch primitive (prompt 62)

Kicked off the Gym Tracker "Workout with timer" initiative (timed sets · a one-tap repeat-set loop ·
free-flow climb sessions · a tracking-type search facet). Two upcoming features need the *same* live
Start/Stop timer — timed sets (`SetKind.duration`, PR 2) and per-climb attempts (PR 5) — so the timer
is built and unit-tested **once, as a primitive with no callers**, to de-risk both.

- **Decision**: split it the repo's usual way — a PURE core (`StopwatchTiming`, no SwiftUI/SwiftData)
  computes the only tricky parts (elapsed-with-pause, count-down clamp, reached-zero) and is unit-tested
  on the Mac (`StopwatchTimingTests`); the SwiftUI `StopwatchView` + `@Observable StopwatchViewModel` is a
  thin shell over it. Mirrors `SetMeasure` / `LastSetLookup` (pure logic at a thin edge).
- **Decision**: the displayed time is ALWAYS recomputed from `Date` (`elapsed = accumulated + (now −
  startedAt)`), never summed from a tick counter — the exact anti-drift rule the rest timer and the
  overall timer already use, so it's correct across backgrounding (reconciled on `scenePhase == .active`).
  The ~200 ms task only refreshes the digits and fires the at-zero haptic. Count-up's no-pause common case
  renders `Text(timerInterval:)` for a zero-background-CPU self-update; a resumed (accumulated > 0) run
  falls back to the recomputed reading so the total stays correct.
- **Decision**: reuse `SetMeasure.formatDuration` for every duration string (no second formatter) and the
  rest timer's 220 pt `Circle().trim` arc + Reduce-Motion snap for the count-down dial — consistency by
  reuse, not re-implementation.
- **Decision**: `Haptics.success()` at 0 is the ONLY device-only line; the core + its tests need no
  device. No model change, no callers — `WorkoutModels` / `WorkoutPlayerView` / `FreeformPlayerView` are
  untouched; PRs 2 and 5 wire it in (and add the knowledge-graph caller edges then).
- **Verification (honest)**: authored on Linux — type-check / `xcodebuild test` / the `#Preview` sim
  render are owed on a Mac at the merge gate (per CLAUDE.md this target can't build here).
  `StopwatchTimingTests` is the device-free proof of the timing math.

## 2026-06-15 — Android Wave 2: workout authoring + workout loop + feedback/undo (#87 #95 #89)

Three stacked Android issues shipped in one PR (Wave 2). Non-obvious choices:

- **No Room schema bump — DB stays at v4.** #87/#95 add target weights, custom exercises, and per-set
  actuals, but every one of those already lives in an *existing* JSON `String` column
  (`WorkoutRoutine.exercisesJson`, `WorkoutSession.exercisesJson`) or an existing entity
  (`WorkoutCustomExercise`). No `@Entity` field changed, so there is **no v4→v5 migration** and the
  `MigrationBaselineTest` is untouched. (Wave 3 / #92 BLE HR may independently produce its own v5 — no
  conflict here, since this batch contributes no schema change at all.) The data layer was fully built
  and unused; #87 is purely its missing UI.
- **Bundled catalog uses `kotlinx.serialization`, not `org.json`.** The 873-exercise Free Exercise DB
  (copied from the iOS resource to `assets/workout/exercises.json`) is parsed by `WorkoutExerciseParser`
  with `kotlinx.serialization` *specifically* so the parse + search run in `:app:testDebugUnitTest` —
  Android's `org.json` is stubbed-to-throw in JVM unit tests, and `--offline` blocks adding the
  `org.json:json` test artifact. `WorkoutCatalog` keeps the 20-entry curated list as an offline
  fallback (its ids all exist in the full DB) and swaps to the full list once `load(context)` reads the
  asset.
- **Analytics run on a JSON-free `SessionView`.** `WorkoutAnalytics` public functions take
  `WorkoutSession`, but the math runs on a decoded `SessionView` value type, so tests build the view
  directly and never touch `WorkoutSession.exercises` (which decodes via `org.json`). Weight is
  normalised to kg for volume/PR comparison so kg/lb-mixed history still aggregates; the PR is reported
  in the unit it was logged in.
- **Set prefill carries forward, most→least specific:** previous *completed* set's actuals → routine
  target → most-recent finished session's logged value. Empty targets no longer wipe a typed value.
- **One app-level `SnackbarHost` with a built-in undo primitive.** `SnackbarController.showUndo` runs
  the destructive `commit` only when the snackbar times out *without* Undo. Journal's delete is
  optimistic (row hidden immediately via `pendingDeleteId`, DAO delete deferred, Undo = clear the id),
  and Kilter's log defers the *insert* (so Undo is a clean no-op). Designed at `RootShell` so future
  delete flows reuse it.
- **OCR failure is now typed.** `ReceiptScanResult` (Success/Empty/Failure) replaces the
  resume-`""`-on-everything contract, so a failed or blank photo shows an inline error instead of a
  silent no-op. (Empty and Failure show the same message — "try better lighting, or use Paste" — but
  stay distinct types for future tuning.)

**Verified**: `:app:testDebugUnitTest` 113 tests green (22 new: `WorkoutAnalyticsTest`,
`WorkoutExerciseParserTest`); `:app:assembleDebug` BUILD SUCCESSFUL. **Device-pending** (one shared
emulator, parallel agents — instrumented run deferred): the 873-row catalog scroll/search + routine
authoring on-device; set prefill + charts + last-time hint across two real sessions; and all the #89
feedback paths (snackbar/haptic/undo, Kilter pill timing + BLE-denial Settings deep link, receipt OCR
failure/empty banner) which are observable only on a device/emulator.

## 2026-06-15 — Android Wave 3: reels, BLE HR, Kilter share loop, Today home (#90 #92 #91 #99)

Four product-review issues shipped in one wave PR. Notes on the non-obvious choices:

- **#92 Room v4 → v5 is one self-contained additive AutoMigration.** Three NULLABLE HR columns
  (`avgHr`, `maxHr`, `hrSampleCount`) on `kilter_session`, so the bump is a no-SQL Room
  `@AutoMigration(4, 5)` — nothing is touched, nothing can be lost. **Cross-wave note (resolved at merge):**
  Wave 2 ultimately shipped NO schema change (its new data fit existing JSON columns), so this v4→v5 is the
  ONLY schema bump in the Android batch and stands as-is — no renumber to v6 was needed. The column-set +
  AutoMigration are clearly commented (`KilterSession`, `SnappetDatabase`). `MigrationBaselineTest` gains a
  `runMigrationsAndValidate` case proving the v4 row survives with the new columns null.
- **#92 HR parse parity is the unit-tested core; live capture is the device edge.** `HRMeasurementParser`
  (0x2A37), `HeartRateZone`, `HRStats`/`HRVMetrics`, and `KilterSessionStats` are pure Kotlin ports of
  the iOS sources (same bit masks, same lower-bound-inclusive zones, population-variance SDNN, RR×1000/1024
  ms). `BleHeartRateSource` is the thin scan/connect/notify edge; `rrTrusted` is a pure default-deny gate
  (optical blacklist checked before the chest-strap whitelist, so "TICKR FIT" is rejected). Unsigned byte
  reads (`and 0xFF`) are the Kotlin gotcha.
- **#92 first log of a sitting auto-opens a manual session** (in `KilterDetailScreen.log()`), so ascents
  group without the user finding the kebab Start; `start()` is a no-op if one is already open. The kebab
  Start/End remains, and the active-session banner now carries a live HR pill + End — a visible affordance.
- **#91 the QR payload is uuid+angle**, so a *created* climb the recipient lacks needs the "Copy hold
  string" fallback (the share sheet ships both). The scanner resolves catalog → created (mirroring detail's
  order) and shows "not in your catalog" otherwise. Deep-link parse + paste-frames import are pure/tested;
  the camera scan is device-pending. Routing reuses one shared `SuiteRouter` (deep links + shortcuts +
  widget taps) → `KilterDeepLinkBus` for the intra-module open.
- **#99 cards and widgets read ONE pure aggregator (`TodayData`)** so they can't drift. Glance habit
  check-off is **headless** (an `ActionCallback` writes Room + `updateAll`, no app open). Glance "Start
  focus" instead OPENS the app into Pomodoro: starting the foreground-service countdown from a widget needs
  a started activity for the FGS permission anyway, so routing through the app is the correct, non-flaky
  path (recorded here deliberately). Static launcher shortcuts use `snappet://module/<id>` data URIs.
- **New deps** (resolved + cached once online, then offline builds): `zxing-core` (QR gen),
  `mlkit barcode-scanning` + CameraX (QR scan), `androidx.glance` (widgets). Added to `libs.versions.toml`
  + `app/build.gradle.kts`. `CAMERA` permission + a `snappet://` VIEW intent filter added to the manifest.

**Verified**: `:app:testDebugUnitTest` green (124 tests incl. the new HR/parse/stats/deep-link/reel/today
cores); `:app:assembleDebug` green; v5 schema JSON committed; `:app:assembleDebugAndroidTest` compiles.
**Device-pending** (recorded, per the repo's established Kilter-BLE pattern): live bpm from a real chest
strap in the Kilter banner; the instrumented `MigrationBaselineTest` v4→v5 run on a device/emulator (a
second agent shares the one emulator — not run here); the live camera QR scan; Glance widget render +
on-launcher headless check-off; long-press launcher shortcuts; and the full Reels device pipeline
(Health Connect read + MediaStore match + Media3 export) behind the honest Stage-0 screen.

## 2026-06-15 — Android Continuous-polish batch (#97 design tokens/motion, #98 a11y, #93 Kilter delight)

Three issues shipped together in one PR (branch `claude/android-continuous`), all JVM-verified
(`:app:testDebugUnitTest` + `:app:assembleDebug` green; no instrumented runs — one shared emulator,
parallel waves).

### #97 — design tokens + motion (NN 65)
- **One page gutter, one card radius.** Added `Spacing.pageGutter` (16dp, the home-dashboard value) +
  `Spacing.minTouchTarget` (48dp) as derived props on the existing `Spacing` (additive — parallel waves
  touch the same files). Routed the four scrolling module roots (Home/Reel/Pomodoro/Tip 16/20/24dp) +
  the App Library grid (12dp) through `pageGutter`; the module-card icon tile through
  `MaterialTheme.shapes.small`.
- **Single Kilter accent token.** Added theme-aware `kilterAccent()` (amber, lit brighter in dark) in
  `Color.kt`; replaced the remaining raw hex (saved-star `0xFFE8A800`, GradeChart highlight) and routed
  the LogButton send/attempt colors through `SnappetAccents.Leaf`/`Ember` instead of re-hardcoded hex.
  (#96 had already converted most ad-hoc Kilter status colors to `pulse*` tokens.)
- **One structural-transition spec.** `Motion.snappetSurfaceTransition(reduceMotion, forward)` returns a
  slide+fade `ContentTransform` (220/160ms), built via the `ContentTransform(...)` constructor — the
  fully-qualified `androidx.compose.animation.togetherWith(...)` does NOT resolve (it's an
  `EnterTransition.togetherWith` extension, not a top-level fun). Used for the tab switch (`RootShell`),
  the workout phase change, and Kilter's sub-screen swaps; the library `NavHost` got matching
  enter/exit/pop transitions. All collapse to an instant fade under reduce-motion.
- **Gotcha:** wrapping `KilterRoot`'s `when (screen)` in `AnimatedContent` shadows the outer `var
  screen` — the lambda param was renamed to `target` so the `onOpen*` callbacks still reassign the
  state, not the immutable param.

### #98 — accessibility (NN 66)
- **Pure spoken-summary builders** in new `ui/ChartAccessibility.kt` (`weekBarSummary`, `boardSummary`,
  `roleCountsOf`) — no Compose/Android, so the exact TalkBack wording is unit-tested
  (`ChartAccessibilityTest`). Every silent Canvas (Home WeekChart, PomodoroFocusChart, Budget donut,
  KilterBoard) now carries a `contentDescription` from these.
- **Habit DayCell**: `Role.Checkbox` + `stateDescription` + `onClickLabel`, one merged node via
  `clearAndSetSemantics` (it used to announce just "M 9" from two stray Texts), and `sizeIn(48dp)` on
  the cell and the edit IconButton (was explicitly `.size(36.dp)`). The visible 28dp circle is unchanged.
- **Bar charts made legible**: weekday initials under each bar, today's bar full-accent vs muted
  others, and a value annotation on today/the max bar (reserved 12% headroom so it isn't clipped).
- **Device-pending:** real TalkBack verification (day-cell role/state toggle + chart summaries) on the
  shared emulator — deferred (instrumented runs collide with parallel waves).

### #93 — Kilter delight (NN 67)
- **Live manual grade estimate**: pure `KilterClimbGenerator.holdTokens` + `estimateManualGrade`
  (mirrors iOS), run over the linear grade model in `meta.json`. Loaded meta-only via new
  `KilterGeneratorAssets.installedMeta()` (no download, no ONNX). The "≈ V5 at 40°" chip updates per
  hold tap, gated on assets installed; manual save now persists the estimate into `predictedGrade`
  (was always null) so authored climbs read like generated ones in detail/browse.
- **Sibling swipe**: the browsed list's uuids plumb from `KilterRoot` (a saveable `browseSiblings`)
  into the detail screen, which hosts the existing detail body in a `HorizontalPager` with an
  "n / total" pill. The existing function was renamed `KilterClimbDetail` (private, per-page) and a thin
  `KilterDetailScreen` wraps it; `settledPage` syncs the host's selected uuid (the back target).
  Empty siblings (Create / Surprise me) → single page, no pager.
- **Plan a session**: ported `KilterRecommender` as a pure, unit-tested core (faithful Kotlin port of
  the iOS recommender — working-grade detection, warm-up→send→project bands, `candidateWindow`) + a
  simple `KilterPlanScreen`; new "Plan a session" More-menu entry. The screen does the I/O (reads logs,
  queries the catalog over the recommender's window with the SAME anchor so every band is populated).
- **Distinct log icons + tooltips**: Attempt → Replay, Project → Flag (no shared glyph; Project's flag
  no longer clashes with the top-bar Saved star). Each log button is a long-press `RichTooltip`
  explaining the climbing status, with a one-line "What do these mean?" affordance teaching the gesture.
- **Device-pending:** swipe-through, the estimate chip, and Plan-a-session end-to-end need a real
  catalog (#42 — the app ships none) + the installed generator meta on the emulator.

## 2026-06-17 — Gym clip-tap opens the scoped Studio (Kilter parity); single-clip editor retired (NN 73)

**What.** In the WorkoutTracker (gym) completed-session detail, tapping a video clip now opens the
CapCut-style **multi-clip Studio** (`StudioEditorView`) **scoped to that one clip**
(`focusClipMediaID: clip.id`, `visibleClipMediaIDs: [clip.id]`) — the same editor Kilter already opens
per-clip — instead of the old single-clip "Edit Clip" sheet. The session-wide "Edit in Video Studio"
button keeps opening the Studio unscoped. With both clip-editing entry points now flowing through the
one multi-clip Studio, the entire old single-clip editor stack was removed as dead code.

- **Bare `StudioEditorView`, not `KilterClipStudio`.** The gym side uses the plain scoped studio; the
  Kilter wrapper adds a Climb panel that's meaningless for gym sessions (sets, not climbs). One small
  `StudioPresentation` struct ({project, visibleClipMediaIDs, focusClipMediaID}) drives the existing
  `fullScreenCover` for both the unscoped (`openStudio`) and scoped (`editClip`) opens — the
  `editingClip` sheet + `onEditClip` closure plumbing is gone.
  **Why:** parity with Kilter and one editor to maintain; the studio's own Climb action-bar button is
  already gated on climb info, so it just renders disabled on a gym project.
- **`StudioEntry.resolveProject(for:media:context:)`** = `findOrCreateProject` THEN append any video
  clips discovered after the project was created (mirrors Kilter's inline `resolveStudioProject`).
  **Why:** `findOrCreateProject` returned the existing project verbatim, so a scoped open of a
  just-discovered clip (`visibleClipMediaIDs:[id]`) would filter to an empty timeline. The whole-session
  button hid this; the per-clip open exposes it. Kilter's reconcile stays inline this round (converging
  both onto the shared helper is an optional follow-up — not changing Kilter's behavior here).
- **Retired stack:** `ClipEditorView`, `ClipEditorViewModel`, `@Model ClipEdit` + `TextOverlay`
  (`ClipEdit.swift`), the `VideoStudio` + `EditPlan` render engine, and `AppModel.videoStudio`. The
  multi-clip `StudioProject` / `StudioComposer` supersede them — two render engines + two edit models
  was the drift the full-studio (S1) work always intended to collapse. **Kept (shared):**
  `ClipEditGeometry` (used across the studio), `HROverlayConfig` (defined in `StudioProject.swift`), and
  the HR-overlay views (`HROverlayElementsView`/`HROverlayValues`/`StudioHRChartView` — all studio-used).
- **DATA-LOSS NOTE (first intentional `@Model` removal).** Dropping `ClipEdit.self` from
  `SnappetSchema.models` (`SnappetCore.swift` AND `SnappetBackup.swift` — kept in lockstep so the
  `testCodecCoversEverySchemaModel` tripwire holds) is destructive: the live store uses the default
  `ModelContainer(for:)` with **no** `SchemaMigrationPlan`, so legacy persisted single-clip edits
  (trim/crop/speed/textOverlays/hrOverlay/music) are orphaned, not migrated to `StudioProject` (different
  stored shapes). `ClipEditRow` + the `clipEdits` field leave the backup format; OLD backups still
  **decode** (synthesized `Codable` ignores the now-unknown `clipEdits` key — no custom `CodingKeys`),
  but that payload is dropped on restore. **Accepted** because edits were non-destructive overlays on
  still-present Photos assets (source video intact), the app is pre-release alpha, and the studio
  re-seeds its timeline from the same clips. `SnappetBackupTests` lost the ClipEdit round-trip and its
  seeded recordCount went 22→21.

**Verified:** `xcodegen generate` + `xcodebuild build-for-testing` clean; `SnappetTests` green
(incl. the schema tripwire). This PR changes real UI, so the XCUITest walkthrough's clip-tap step
(`LiveWorkoutStudioWalkthroughTests` 11g) now drives the Studio (`studioClose`) instead of
`clipEditorDone`. Device check pending: tapping a freshly-discovered clip shows the focused clip in the
timeline (the reconcile path).

## 2026-06-17 — Unified, resizable HR stat tile replaces the free-floating overlay badges (NN 74-76)

**What.** The configurable HR/fitness overlay (the scattered `HROverlayElement` badges, each
independently placed) is replaced by ONE resizable, draggable **stat tile** — a design picked from a
7-template catalog (`HRTileTemplate`: scorebug / hero / bento / list / ring / hudPill / chartBanner),
with every metric individually toggleable (ON/OFF) and **all on by default**. Shipped as 3 stacked
PRs: model + pure layout (74), export burn-in (75), editor UX (76).

**Why these choices (the non-obvious ones):**

- **One pure layout, two render paths (WYSIWYG).** `HRTileLayout.layout(...)` is a single
  platform-free function (CoreGraphics only) that both the SwiftUI preview (`HRTileView`) and the
  Core-Animation export (`StudioOverlays.hrTileLayer`) run — so what's placed is what burns in, the
  same contract `HROverlayValues` already gave the per-badge path.

- **Scale-invariant layout is what makes WYSIWYG actually hold.** The preview passes a rect in
  **points** (~hundreds wide), the export passes one in **pixels** (~1080 wide). So every layout
  decision (how many fields fit, grid columns, list rows) is derived from the rect's **proportions**,
  never absolute pixels, and the 11pt legibility floor is applied ONLY to the reported font size,
  **not** to the fit/reflow math — otherwise reflow would diverge between a small preview and a large
  export. Reflow drops trailing low-priority metrics (never bpm/zone) before going below the floor.

- **Default = Scorebug Strip.** A broadcast-style lower-third (y≈0.80, safe zone) led by a
  zone-coloured bpm hero: the one archetype where "all metrics on" reads cleanly (toggles map 1:1 to
  fields), the natural successor to the scattered badges, and the strongest "live numbers over moving
  footage" pattern (broadcast scorebug + Garmin/Strava transparent lower-thirds).

- **Zone colours stay the repo ramp** (`HeartRateZone.color`: blue/teal/green/orange/red), NOT the
  Garmin gray-led ramp the design research suggested — to keep one source of truth with every existing
  pill (prompt 51). Aggregates render white; only live-intensity metrics (bpm/zone/%HRR) +
  redline (red) + recovery (traffic-light) carry semantic colour, so a single hue never misrepresents
  a multi-zone session.

- **Migration-safe + zero data loss.** `HROverlayConfig.tile` is additive-optional; `HRTileMigration`
  folds any legacy `elements[]` into a tile on appear (every badge → an ON entry preserving
  order/flags/colour, the rest appended OFF, template inferred from the count, frame = the badges'
  bounding box). The legacy `elements[]` is kept (read-only) — a later prompt can drop it once all
  persisted blobs are known-migrated.

- **SwiftData phantom-tile gotcha (new, important).** SwiftData's composite coder materializes a
  `nil` **nested-optional** Codable struct (`HRTile?` inside the `HROverlayConfig` blob) as a
  *content-empty* value rather than absent — so `decodeIfPresent` returns an entries-empty `HRTile`
  with a fresh `UUID()` id. That broke `testSnapshotEncodingIsDeterministic` (nondeterministic backup
  bytes) and would have wrongly blocked migration. Fix: a real tile ALWAYS carries every metric entry,
  so `HROverlayConfig.init(from:)` normalizes an entries-empty decoded tile back to `nil`. (Pure-JSON
  round-trips were already correct; only SwiftData's coder exhibits this.) Regression test added.

**Device-only (cannot verify on the simulator / CI), flagged like prior HR prompts:** the burned-in
`.mp4` (scrim opacity, font metrics, Y-flip, the per-value opacity cross-fade for live metrics, which
exists because Core Animation can't redraw text per frame) and the drag/corner-resize feel.

**Verified:** `xcodegen generate` + `xcodebuild build-for-testing` clean; full `SnappetTests` green
(774, incl. new `HRTileLayoutTests` / `HRTileTests` / `HRTileCodableTests` / `HRTileMigrationTests` /
`HRTileResolveTests` + the determinism regression); the studio walkthrough XCUITest now drives the tile
builder (enable → pick Bento → toggle a metric → dismiss).

## [2026-06-18] iOS — Quick Session redesign Phase 3: live climbing stats ribbon + at-logging milestones

**Decision** (`pdd/prompts/features/quick-session-redesign/03-...`): the freeform player gets a docked
**stat ribbon** above the climb cards (shown only when `FreeformClimbStats.hasClimbing`) — hero "N
sends" · "hardest <grade>" (omitted pre-send) · an inline mini-pyramid, with a pre-send teaching
variant — tapping it presents a read-only **`LiveClimbStatsSheet`** (hero Sends/Hardest/Sends-hr tiles,
the full grade pyramid, projects/attempts, median time, time-on-wall-vs-rest, and an Effort block when
HR is present). And after every log, a **milestone celebration** fires for a genuine new best.

- **Reuse the pure helpers, don't re-derive.** The ribbon + sheet read `FreeformClimbStats.stats`
  (which bridges the freeform climbs into the exact `KilterSessionStats` the Kilter board flow
  computes) and `WorkoutHRStats` for the HR roll-up; the views do **no** stats math. The milestone
  diff reuses `FreeformSummary.milestones(for:history:)` — the same gate the done-screen uses — so
  "new hardest" for climbing falls out naturally as a `firstSend` of a harder grade (the existing
  `Milestone` enum is `firstSend` + weighted `personalRecord`; not expanded).

- **Cache the ribbon stats like `prefills`.** `climbStats` is `@State`, recomputed on `session.exercises`
  change (and on append), NOT per render — the command bar re-renders ~1 Hz off the HR/timer, and
  re-deriving the pyramid each tick would be wasteful. `hasClimbing` (cheap) still gates the ribbon
  inline per render so the row appears the instant the first attempt lands.

- **Pyramid is a local `BarMark`, not a shared view.** The Kilter summary's pyramid (`pyramidSection`)
  is a **private** func on `KilterSessionDetailView` (depends on its private `kilterGrade` helper), so
  it can't be reused across files; per the prompt, `LiveClimbStatsSheet` carries its own small Swift
  Charts `BarMark` pyramid (`freeform.statsPyramid`, `chartYScale` pinned to the easiest→hardest order).
  The **`ZoneBar`** (heart-rate zone bar) IS a shared `struct` view, so that's reused as-is.

- **At-logging celebration fires once per milestone, never per attempt.** `appendLog` (the single funnel
  both `logAttempt` and the inline outcome strip route through) calls `checkLiveMilestones()`, which
  diffs the freeform milestones against a `celebratedMilestones: Set<String>` (stable key: `pr:<id>` /
  `send:<grade>`). A new key → a transient `freeform.liveMilestone` banner + a `milestoneTrigger` bump
  driving the screen-level `.celebrates(on:)` (`CelebrationBurst` + `Haptics.success`, already
  Reduce-Motion-aware: haptic + static text, no confetti). A repeat send of an already-celebrated grade
  is silent. The done-screen milestone burst (Phase D) is unchanged and independent.

**Verified:** `xcodegen generate` + `xcodebuild build-for-testing` clean (0 errors / 0 new warnings in
the changed files); full `SnappetTests` green (829, 2 skipped, 0 failures); new
`SnappetUITests/LiveClimbStatsTests` (add a climb → log a Sent attempt → ribbon reads "1 send" → tap →
the `freeform.statsExpand` sheet shows the `freeform.statsPyramid`) passed on the simulator. The HR
**Effort** block is HR-data-gated, so it's exercised only on a session that carries `hrSeries` (a
device/recorded session) — the ribbon, pyramid, counts, and milestone paths are all sim-verified.

## [2026-06-18] iOS — Quick Session redesign Phase 5: timed-exercise hierarchy + catalog (pick or create)

**Decision** (`pdd/prompts/features/quick-session-redesign/05-timed-exercise-catalog.md`): give timed
exercises the same first-class, *named* hierarchy climbs got in Phase 1. Tapping **Timed** (the empty-state
`freeform.cardTimed` card OR the add-menu "Timed exercise") now opens a **`PickTimedExerciseSheet`**
(searchable catalog · "Create new" pinned · recents · category groups · seeded suggestions) instead of
dropping a bare unnamed `.duration` row; selecting/creating one drops a **named timed card** whose timed
sets log underneath it like a climb's attempts. Named exercises **persist** for reuse.

- **`TimedExerciseSpec` is a pure `Shared/` value type, presets only PRE-FILL.** The structure
  (`mode` ∈ openCountUp/maxHang/countDown/repeaters/tabata/emom + work/rest/reps/sets/restBetweenSets/
  leadInSec) lives in `ios/App/Shared/TimedExerciseSpec.swift` (Codable/Sendable/Hashable, compiled into
  every target via the `project.yml` `Shared` glob, like `HeartRateZone`). Pure `totalSeconds` (lead-in +
  all work + inter-rep rest + between-set rest, NO trailing rest) and one-line `summary` ("7:3 × 6 · 6
  sets" / "10s hold" / "Count up"); protocol-preset static factories (`.repeaters7x3x6`, `.maxHang10/7`,
  `.tabata`, `.emom`, `.hold(_)`). **A user-edited value is NEVER snapped back to a preset** (the Tindeq
  antipattern) — chips pre-fill the form, nothing more. Unit-tested (`TimedExerciseSpecTests`).

- **`TimedExerciseCatalog` is the persisted `@Model`; suggestions are in-memory.** New `@Model`
  (`id/name/categoryRaw/specData/createdAt/lastUsedAt`) registered in **`SnappetSchema.models`** AND
  mirrored by a `TimedExerciseCatalogRow` in **`SnappetBackup`** (the enforced invariant — `SnappetBackupTests`
  now seeds one row and asserts `recordCount == 22`). The **structure rides `specData`** (an encoded
  `TimedExerciseSpec`), not a fan of columns, so the value type stays the single source of truth and adding
  a mode never migrates the model. Built-in starters (`7s max hang`, `Dead hang`, `Repeaters`, `Plank`,
  `Wall sit`, `Tabata`) are **in-memory `Suggestion`s**, not seeded rows — the catalog is never an empty
  void without writing rows the user didn't ask for; "Save to my exercises" is how a pick graduates into a
  persisted row. Recents = saved rows with a `lastUsedAt`, newest-first (`@Query` sort).

- **`SessionExercise` gains additive `timedSpecData`/`timedCategory` (migration-safe).** Mirrors the
  Phase-1 climb fields — additive Optionals decode `nil` on legacy data (an old unnamed "Timed exercise"
  renders as a plain open count-up), and the `WorkoutSessionRow` already snapshots `exercises` wholesale so
  backup round-trips them with no codec change. `timedSpec` is the computed Codable bridge.

- **Phase 5 reuses the simple `StopwatchView` timer; the structured runner is Phase 6.** The named card's
  "Add set" opens the existing `LogSetSheet(.duration)` Timer path (the timer measurement IS the log →
  `SetLog(durationSec:)`; Manual stays as a fallback; one-tap Repeat kept). For a **max-hang / count-down**
  spec the dial is armed to count **down** from `workSec` (`StopwatchTiming.Mode.countDown`) — the captured
  value is still the *elapsed time held*, so logging is unchanged. The structured repeaters/tabata/emom
  interval runner is **deferred to Phase 6** (the spec already carries the parameters it will read).

**Verified:** `xcodegen generate` + `xcodebuild build-for-testing` clean (0 errors / 0 new warnings in the
changed files); full `SnappetTests` green incl. new `TimedExerciseSpecTests` and the `SnappetBackupTests`
drift+round-trip tripwire; `SnappetUITests/TimedSetTimerTests` (pick a seeded suggestion → named card → log
a timed set with the live timer; AND create "10s hang" count-down + preset → named card → log a set) on the
simulator. Structured interval runner deferred to Phase 6.

### Quick Session redesign — Phase 6 (structured interval runner: repeaters/tabata/emom)

- **Pure `IntervalSchedule` in `Shared/`, mirroring `StopwatchTiming`.** A `.repeaters`/`.tabata`/`.emom`
  `TimedExerciseSpec` unrolls into an ordered `[Phase]` (`kind: leadIn/work/rest/restBetweenSets/done`,
  each with `durationSec`, 1-based `setIndex`/`repIndex`, a big `label`, and the **next** phase's `nextLabel`
  for the preview chip). A pure `state(at elapsed) -> (phase, remainingInPhase, overallRemaining, setRep,
  isDone)` walks the phases off a wall-clock anchor, so the running view is a thin read that can't drift and
  survives backgrounding. Unit-tested exhaustively (`IntervalScheduleTests`, 18 cases): total ==
  `spec.totalSeconds`, phase counts/boundaries, the multi-set set/rep counter, next-phase labels, and edges
  (lead-in 0, single rep/set). Lives in `Shared/` so the same schedule is available on every target.
- **EMOM is 60-second work windows.** `.emom` carries `workSec/restSec == 0` in the preset, so the schedule
  models each rep as a **60 s work phase** (one effort at the top of every minute, no inter-rep rest) — its
  schedule `totalSeconds` is `leadIn + reps*60` and so deliberately does NOT equal `spec.totalSeconds`
  (which is the spec's raw-field math). For repeaters/tabata the two agree (asserted).
- **`StructuredTimedRunner` drives a wall-clock `RunnerViewModel` directly** (the `StopwatchViewModel`
  freeze idiom, NOT the packaged `StopwatchView` — its composite collapses under XCUITest). A ~200 ms ticker
  recomputes `state(at:)`, fires the per-phase + final-3s cues, and auto-finishes at the `done` marker.
  **Pause** folds the running segment into `accumulated`; **Skip** jumps the anchor to the next phase
  boundary. **"The timer is the log":** on finish/STOP a capture card pre-fills the **time-under-tension**
  (Σ completed work seconds, partial when stopped mid-work), completed reps·sets, and avg/peak HR; "Log set"
  commits `SetLog(durationSec: TUT)` through the same freeform `appendLog` funnel.
- **Cues are a light system sound + the shared `Haptics`, gated by a tri-state toggle.** Per-phase
  work/rest tones (`AudioServicesPlaySystemSound`, no bundled asset → revertible) + a final-3s tick + a
  completion tone, with a **sound + haptic / haptic only / silent** toggle persisted via `@AppStorage`. The
  phase background telegraphs the phase before the beep (WORK = `SnappetColor.workout` ember / REST = muted)
  and Reduce Motion snaps the ring instead of animating. (Audio/haptic + keep-awake are **device-only**.)
- **Wire-in is a one-line branch in the named timed card.** "Add set" presents `StructuredTimedRunner`
  (`.fullScreenCover`) when `ex.timedSpec?.mode.isStructured`, else keeps the Phase-5 `LogSetSheet`
  stopwatch — Phases 1–5 untouched.

**Verified:** `xcodegen generate` + `build-for-testing` clean (0 errors / 0 new warnings in the changed
files); full `SnappetTests` green incl. new `IntervalScheduleTests` (18 cases); a new
`SnappetUITests/StructuredIntervalRunnerTests` (create a Repeaters exercise → named card → "Add set" opens
the runner → asserts `intervalRunner.phase` + `.timer` are live → lead-in elapses into WORK → STOP →
capture card → `intervalRunner.logSet` → a set row appears) passes on the simulator.

### Quick Session redesign — Phase 7 (type-adaptive completion summary · remembered rest timers · polish)

- **The completion screen is now a SCROLLABLE, type-adaptive recap (`FreeformDoneSummaryView`)**, extracted
  out of `FreeformPlayerView.doneScreen`. Its hero strip + cards adapt to `FreeformSummary.dominant(for:)`:
  - **Climbing** → hero Sends · Hardest · On-the-wall(time); a secondary Effort card (sends/hr · total
    attempts · median), the full **grade pyramid**, the per-climb **timeline** (newest-first, top 5 +
    "Show all N"), and — only when `!session.hrSeries.isEmpty` — the **Effort** zone-bar.
  - **Timed** → hero Hold time · Best · Sets; per-exercise rows (name · sets · TUT · best hold).
  - **Strength** → hero Volume · Sets · PRs; a PRs list + per-exercise volume.
  - **Honest degradation, no fake data:** no per-climb timing → "Climbs" (count) not "On the wall"; no HR →
    the Effort block is omitted. Every figure is derived from the pure `FreeformSummary` + `FreeformClimbStats`
    (no model migration). The milestone seal/headline + `CelebrationBurst` and Done / View detail / Keep going
    / Discard all carry over (same a11y ids). A "Turn N clips into a reel" Studio CTA shows when the session
    has video clips and opens the WHOLE session in the shared editor.
- **The pyramid / zone-bar / timeline are SHARED subviews, not duplicated.** `FreeformClimbSummaryComponents`
  holds `ClimbGradePyramid` / `ClimbEffortSection` / `ClimbTimelineList` (+ a shared section title), extracted
  from the Phase-3 `LiveClimbStatsSheet` so the live sheet and the completion recap render the IDENTICAL views
  (the pyramid keeps its `freeform.statsPyramid` id). `LiveClimbStatsSheet` now composes those shared views.
- **Remembered rest timer = a pure `RestTimerDefaults` + a non-blocking command-bar count-down.** A small
  PURE type (unit-tested, `RestTimerDefaultsTests`, 8 cases) owns the deterministic parts — the per-context
  KEY (`.climb(ClimbType)` / `.timed(TimedExerciseCategory)` / `.lifting`), the clamp `[10, 600]s`, the seeded
  per-discipline default (boulder 120 / route 240 / hangboard 180 / lifting 120), and the remember/recall +
  JSON round-trip for `@AppStorage` (which can't hold a dictionary). The view holds the live count-down
  (reused `StopwatchViewModel(.countDown)` + the at-zero `Haptics`): **opt-in** (`freeform.restToggle`, OFF by
  default), and on each `appendLog` (the one funnel) it auto-arms the remembered rest for that exercise's
  context. The rest banner floats as an `.overlay` ABOVE the command bar (NOT a stacked row) so the bar's
  `safeAreaInset` height — which the List's bottom content-margin is sized to — is unchanged when there's no
  rest, keeping the last set's controls hittable. ±15 s nudges remember the new length per context; an X
  dismisses. Never gates logging.
- **Recent-gym chips + per-type scale stick in `AddClimbSheet`.** A one-tap recent-gyms rail under "More ·
  gym" (`addClimb.recentGym.<gym>`, persisted in `UserDefaults` like the recent grades, capped 5,
  case-insensitively de-duped; the disclosure auto-opens when a gym is remembered). The V↔Font / YDS↔French
  scale toggle now sticks **per discipline** via `@AppStorage` (`addClimb.boulderScale` / `addClimb.routeScale`):
  the sheet restores the remembered scale for the opening/selected type, snapping the grade to that scale's
  default so a route never opens on a V grade.
- **Keep-awake on the FOCUS covers** — `TimedAttemptCover` and `StructuredTimedRunner` set
  `UIApplication.shared.isIdleTimerDisabled = true` onAppear / `false` onDisappear so the screen doesn't sleep
  mid-effort (the Phase-6 device-only note). Cheaply revertible.
- **`AddClimbSheet.commit` is now ONE-SHOT (`committed` guard).** A double/triple-tapped CTA — a user mash, or
  XCUITest delivering the tap more than once as the sheet settles — now creates exactly ONE climb (it had been
  creating 2–3, which is why `FreeformFlowWalkthroughTests` was already red on the Phase-6 baseline at its
  grade-pill assertion). Genuine hardening that also stabilizes the walkthrough.
- **`-uiTestFreshStore` now also clears the Quick-Session @AppStorage keys** (recent grades/gyms, per-type
  scales, auto-rest + rest-defaults) in `SnappetApp` — they ride `UserDefaults`, which the in-memory store
  swap doesn't touch, so a prior run's recents would add duplicate chip elements the freeform walkthrough trips
  over (the `KilterCatalogFixture` precedent for its `kilter.*` keys). The walkthrough's timed step was also
  modernized for the Phase-5 pick sheet (pick the seeded "Free hold" suggestion → named card → Add set →
  Manual → 0:45), and its grade-pill assertion + Add-set helper made robust to the documented XCUITest
  double-fire / transient-non-hittable scroll positions.

**Verified:** `xcodegen generate` + `build-for-testing` clean (0 errors / 0 new warnings in the changed
files); full `SnappetTests` green (866 tests, 2 skipped) incl. new `RestTimerDefaultsTests` (8 cases);
`SnappetUITests/FreeformFlowWalkthroughTests` passes end-to-end on the simulator (climb → attempts → lifting →
timed → Finish → the type-adaptive summary with the climbing pyramid + Effort + New-PR milestone → Done) — a
test that was already RED on the clean Phase-6 baseline (pre-existing CTA double-fire) and is green after this
phase. Device-only: the keep-awake, the rest-timer at-zero haptic, and the clips→reel pipeline.

## 2026-06-18 — Add-a-climb: wall name (gym→wall suggestions) + climb colour (prompt 08)

On-device-feedback iteration on `AddClimbSheet` (Quick Session redesign):

- **Wall is scoped to the gym, not global.** A gym has many walls, so wall suggestions live in a
  per-gym map (`UserDefaults` key `freeform.gymWalls`, JSON `[gymKey: [wall]]`, gymKey = trimmed+lowercased
  so "The Front"/"the front " share walls) — reloaded whenever the gym changes (typed or chip-tapped), and
  empty until a gym is set. A newly-typed wall is remembered only under the current gym. Deliberately
  mirrors the recent-gym rail but keyed per gym; the recents ordering (most-recent-first, case-insensitive
  dedupe, capped) is now ONE pure tested helper `AddClimbSheet.mergedRecents`. `SessionExercise.wall` is an
  additive optional; shown in the card's "📍 gym · wall" caption (new `freeform.climbLocation`).
- **Colour is a curated palette, stored by name, swatch derived.** New pure `ClimbColor` enum (12 gym
  hold/tape colours) with `hexValue: UInt32` so the swatch reuses the existing `Color(hex:)` — keeping
  `ClimbColor` Foundation-only + unit-tested (no SwiftUI in the value type). Optional (a "None" clear chip;
  re-tapping the selected colour clears it). Picked **next to the grade** (the user's placement), value
  mirrored on `addClimb.colorValue`; shown as a 14pt swatch next to the grade pill on the card
  (`freeform.colorSwatch`, near-white gets a hairline ring). `SessionExercise.climbColorRaw` additive
  optional. Both fields migration-safe (no new @Model, no non-optional stored field).

**Verified:** `build-for-testing` clean (0 errors / 0 warnings in changed files); `SnappetTests` green
(**868**, +2 new: ClimbColor palette + mergedRecents); `SnappetUITests/NamedClimbTests` green. Sim note:
the iPhone 17 Pro runner wedged ("hung before establishing connection") after a device build left MrRobot
connected+locked — an `xcrun simctl erase` + a different sim model (iPhone 17) cleared it.

## 2026-06-18 — Climb card: edit details · per-attempt clips → editor · climb-name overlay (prompt 09)

On-device-feedback iteration on the freeform CLIMB card (Quick Session redesign), three cohesive parts:

- **Edit climb details — reuse `AddClimbSheet` in an EDIT mode, not a second sheet.** A new optional
  `initial: AddClimbParams?` makes the sheet open PREFILLED (title "Edit climb", a single "Save" CTA
  `addClimb.save`, no "Add & log first attempt"); a "Edit details" (pencil) item sits above "Remove climb"
  in the climb header Menu (`freeform.editClimb`; the Menu's ellipsis label gained `freeform.climbMenu` so
  the XCUITest can open it deterministically — SwiftUI Menu items aren't queryable until the label is
  tapped). The player routes Save to a new `updateClimb(_ exID:, _ params:)` that overwrites THAT
  `SessionExercise`'s type/grade/scale/name/gym/wall/colour **in place** (same `id`, attempts preserved —
  no duplicate). A `AddClimbParams.init(from: SessionExercise)` builds the prefill (grade falls back to the
  scale default, name to the type label). **Gotcha:** the sheet's `type` `.onChange` snaps the grade to the
  scale default, which would clobber a route prefill when `seed(from:)` flips the type — guarded with a
  one-shot `didSeed` flag so the reset only fires on a USER type change, not the seed. A name equal to the
  bare type label (the add-flow blank fallback) is shown empty so the placeholder reads. Decision: existing
  logged attempts keep the grade they were **stamped** with at log time (the per-`SetLog` source of truth
  for the send/pyramid reads); only the card-level grade re-derives — editing the climb is not a
  retroactive re-stamp.
- **Per-attempt media — a UI-only add (no model change).** `SetMediaStrip(session:exerciseID:setIndex:onEdit:)`
  is now rendered under EACH attempt row in the expanded card (`.id("climb-media-\(ex.id)-\(i)")`, `onEdit`
  → `presentStudio`). `SessionMediaAssignment.completions(from:)` already tags `.climbAttempt` sets, so an
  auto-discovered or manually-attached clip maps to `(climbExerciseID, attemptIndex)` with no schema change;
  a video tap opens the shared Studio editor exactly as lifting/timed sets do.
- **Climb-name overlay for FREEFORM clips — widen the existing `.climbName` path, keep the Kilter path
  byte-identical.** A freeform climb has no Kilter `KilterLogEntry`, so `resolvedClimbUUID` is nil and the
  editor's "Climb" action was unreachable for it. Thread the climb's caption end-to-end:
  `FreeformStudioPresentation.climbCaption` (built in `presentStudio` from the tapped clip's
  `assignedExerciseID` → `[displayName, climbGradeLabel].compactMap{…}.joined(" · ")`, e.g. "Cave Roof · V5")
  → `StudioEditorView.init(… suggestedClimbCaption:)` → `StudioEditorViewModel`. `hasClimbInfo` widens to
  `resolvedClimbUUID != nil || suggestedClimbCaption != nil`; `addClimbNameOverlay()` prefers the Kilter
  caption when present, else drops the SAME `.climbName` lower-third (same shape/position/editability)
  seeded with the suggested caption. `suggestedClimbCaption` is an additive optional defaulting to nil — the
  Kilter (`resolvedClimbUUID`) path is untouched; the "Show setter" toggle stays Kilter-only (it early-returns
  for a freeform overlay, which has no setter — benign/inert).

**Verified:** `xcodegen generate` + `build-for-testing` clean (0 errors / 0 warnings in the changed
app-code files — `FreeformPlayerView`, `AddClimbSheet`, `StudioEditorView`, `StudioEditorViewModel`); full
`SnappetTests` green (**868**, 2 skipped); new `SnappetUITests/EditClimbTests` passes (add V3 → Edit details
→ change rung to V5 → Save → `freeform.gradePill` reads V5 and there is still exactly ONE climb) and
`NamedClimbTests` (Phase-1 add-mode regression guard) still passes. The new UITest file carries the same
Swift-6 main-actor-isolation warnings the whole `SnappetUITests` target already has on `XCUIApplication`
access (confirmed by force-recompiling `NamedClimbTests` — same warning family); it deliberately mirrors that
plain-`XCTestCase` idiom rather than diverge. Device-only / deferred: the PHPicker/Photos pick on a real
device (the strip's affordance renders on the sim but the library is empty), and the actual on-video overlay
render/burn-in (Core-Animation export is device-only — the sim shows the editor's placeholder canvas).

## 2026-06-18 — Climb card: name-tap expands · attempt-count on the tag · edit-all-clips (prompt 10)

On-device-feedback iteration on the freeform CLIMB card + its Studio clip editor (Quick Session redesign),
three cohesive refinements:
- **Name tap = expand/collapse (not inline-edit).** The inline-editable `ClimbNameHeader` TextField is
  replaced by a plain, non-editing `Text(name)` wrapped in a `Button { toggleExpanded(ex) }` — the name now
  joins the chevron as the expand/collapse affordance. Editing the name is solely via ⋯ → "Edit details"
  (prompt 09's `AddClimbSheet` edit mode). `ClimbNameHeader` is deleted (nothing else used it).
  **A11y gotcha:** the id (`freeform.climbName`) had to move onto the **Button**, not the inner `Text` —
  a `Button`-wrapped `Text` is exposed to XCUITest as a *button* (the inner Text's id is absorbed), so
  `staticTexts["freeform.climbName"]` no longer matches. It's now `buttons["freeform.climbName"]` whose
  `.label` is the climb name. `NamedClimbTests` was updated: the rename path is ⋯ (`freeform.climbMenu`) →
  `freeform.editClimb` → `addClimb.name` → `addClimb.save`, then assert the button label shows the new name.
- **Attempt-count option on the climb-name tag.** Additive `suggestedAttemptNumber: Int?` threaded
  `FreeformStudioPresentation` → `StudioEditorView.init` → `StudioEditorViewModel` (default nil — the Kilter
  and whole-session paths are byte-identical when nil). In `presentStudio(_ clip:)` it's
  `clip.assignedSetIndex.map { $0 + 1 }` (the clip is attached to one attempt, `assignedSetIndex` 0-based).
  The editor shows a user-toggleable **"Attempt #"** toggle (`studioClimbAttempt`) on the `.climbName`
  overlay bar, gated by `canShowClimbAttempt` (`suggestedAttemptNumber != nil` AND a `.climbName` overlay
  selected) — mirroring the existing "Show setter" toggle. Toggling regenerates THAT ONE overlay's content
  via a new **pure** `KilterClimbCaption.climbTagContent(caption:attempt:showAttempt:)` (ON appends a
  trailing "Attempt N" line; OFF strips it). **Decision:** OFF strips by removing a trailing `\nAttempt N`
  suffix from the *current* content rather than re-deriving from climb data — so a manual edit to the base
  caption survives the toggle and re-toggling never compounds the line (the base caption stays the editable
  source of truth, and no 2nd overlay is created). Unit-tested in `KilterClimbCaptionTests`.
- **Edit all clips together.** A "Edit all clips" item (`freeform.editAllClips`) is added to the climb ⋯
  menu, shown only when the climb has ≥1 video `SessionMedia` (`assignedExerciseID == ex.id`,
  `kind == .video`). `presentStudioForClimb(_ ex:)` gathers those media ids, resolves the session's single
  shared+persisted `StudioProject` (`StudioEntry.resolveProject`), and presents
  `FreeformStudioPresentation(project:, visibleClipMediaIDs: Set(thoseIds), focusClipMediaID: first,
  climbCaption: <name · grade>, suggestedAttemptNumber: nil)`. **No new persistence** — because every
  per-clip edit already lives on that one shared project, a wider `visibleClipMediaIDs` simply shows them
  together; `suggestedAttemptNumber` is nil here since the combined view spans many attempts.
- **Build gotcha:** after threading `suggestedAttemptNumber`, `FreeformPlayerView`'s giant `loggingContent`
  opaque-result body tripped a "compiler unable to type-check in reasonable time". Extracted the climb ⋯
  menu items into a `@ViewBuilder climbMenuContent(_ ex:)` helper to drop the inference load — kept as a
  genuine simplification.

**Verified:** `xcodegen generate` + `build-for-testing` clean (0 errors / 0 warnings in the changed
app-code files — `FreeformPlayerView`, `StudioEditorView`, `StudioEditorViewModel`, `KilterClimbCaption`;
the test-target main-actor-isolation warnings are pre-existing). Full `SnappetTests` green (**872**, 2
skipped) including 4 new `climbTagContent` cases; `SnappetUITests/NamedClimbTests` (updated rename-via-Edit-
details path) and `EditClimbTests` both pass. Device-only / deferred: the actual on-video overlay
render/burn-in incl. the "Attempt N" line (Core-Animation export is device-only — sim shows the placeholder
canvas), and the PHPicker/Photos clip pick that populates the per-climb multi-clip view.

## 2026-06-18 — Climb clip lifecycle: dynamic attempt# · deep-tap reassign/remove/delete (prompt 11)

On-device-feedback iteration on the per-attempt clips (Quick Session redesign), four cohesive refinements —
**most of it PORTED from the post-session `SessionDetailView`** (which already does move/remove/delete) into
the LIVE freeform strip, matching its wording:
- **Dynamic attempt # in the Studio editor.** `StudioEditorViewModel.selectedClipAttemptNumber` fetches the
  `SessionMedia` for `selectedClip?.sessionMediaID` → `assignedSetIndex.map { $0 + 1 }`; a new
  `effectiveAttemptNumber = selectedClipAttemptNumber ?? suggestedAttemptNumber` is what `canShowClimbAttempt`
  and `setSelectedClimbShowsAttempt` use, so the "Attempt #" tag follows the **selected** clip (critical in
  the combined "Edit all clips" view, where the threaded `suggestedAttemptNumber` is nil because the scope
  spans many attempts). **Decision:** `select(_:)` now calls `refreshAttemptLineForSelection()`, which
  re-derives any "Attempt #"-ON `.climbName` overlay's appended line to the newly-focused clip's number via
  `KilterClimbCaption.climbTagContent` — so a tag reading "Attempt 2" becomes "Attempt 4" when you select a
  different attempt's clip. The "Attempt #" OFF-strip is now a `\nAttempt \d+$` regex (matches ANY number)
  rather than a fixed-N suffix, since the appended number can change with selection.
- **Deep-tap (long-press) clip menu on the live strip.** `SetMediaStrip` gains an optional `.contextMenu`
  (a `ClipContextMenu` ViewModifier, attached to either a video Button or a plain photo thumb) wired ONLY on
  the climb-attempt strips via three new (defaulted-nil) params: `moveTargets: [ClipMoveTarget]`, `onReassign:
  (SessionMedia, UUID?, Int?) -> Void`, `onRequestDelete: (SessionMedia) -> Void`. Lifting/timed/guided
  strips pass none → no menu (unchanged). Items (ported from `SessionDetailView.thumbMenu`): **Move to
  attempt…** (submenu over the climb's attempts) · **Remove from attempt** (→ General) · **Delete clip…**
  (destructive). a11y: `freeform.clipMenu` on the thumbnail, `freeform.clipMove.<i>` / `freeform.clipRemove`
  / `freeform.clipDelete` on the leaves.
- **Reassign + remove (sticky).** `FreeformPlayerView.reassignClip(_:to:set:)` (port of
  `SessionDetailView.reassign`) sets `assignedExerciseID/assignedSetIndex` + `assignmentSource =
  exerciseID == nil ? .general : .manual`, so a moved clip pins `.manual` and a removed clip pins `.general`
  — both sticky against `reconcileAssignments`, which only re-places `.auto` rows. "Remove from attempt" =
  reassign to General (`assignedExerciseID nil`): it leaves the strip but keeps the file.
- **Photos-aware delete.** A single `.confirmationDialog($pendingClipDeletion)` is hosted on the (stable)
  logging screen, **ported verbatim** from `SessionDetailView` incl. the Photos wording ("…iOS will ask once
  more"); only the first button's noun is "Remove from attempt only" (vs "…from session only"). "Delete from
  Photos too" → `deleteClipFromPhotos` (port of `deleteFromPhotos`): `MediaLibraryService.deleteAssets(...)`
  FIRST (iOS shows its own confirm), then `context.delete` + save only on success, so a denied/cancelled
  delete never orphans the tag. The `MediaLibraryService` is obtained the same way `SessionDetailView` does
  (a stored `private let mediaLibrary = MediaLibraryService()`).
- **Pure helper + test.** Move targets come from a pure `climbClipMoveTargets(for ex:) -> [ClipMoveTarget]`
  (in `SessionMediaAssignment.swift`): one `ClipMoveTarget(id:"<exID>-<i>", title:"Attempt N", exerciseID,
  setIndex)` per attempt. Unit-tested in `ClipMoveTargetTests` (1-based titles / 0-based setIndex / stable
  unique ids / empty for an attempt-less climb). No model change — `MediaAssignmentSource`/reconcile were
  already correct.

**Verified:** `xcodegen generate` + `build-for-testing` clean (0 errors / 0 warnings in the changed
app-code files — `StudioEditorViewModel`, `SetMediaStrip`, `FreeformPlayerView`, `SessionMediaAssignment`;
the test-target main-actor-isolation warnings are pre-existing). Full `SnappetTests` green (**876**, 2
skipped) including 4 new `climbClipMoveTargets` cases; `SnappetUITests/NamedClimbTests` + `EditClimbTests`
both pass (sim-wedge "hung before establishing connection" cleared by `simctl shutdown all` + retry).
Device-only / deferred: the actual Photos asset deletion (the system confirm + on-disk removal), the PHPicker
pick, and the context-menu long-press feel — a focused unit test for the pure helper + the green climb
UITests cover the rest (a context-menu + Photos-deletion XCUITest is too device-y/flaky to force here).

## 2026-06-18 — Studio editor: scope overlays to the visible clips (prompt 13)

Bug (user, single-clip editor): opening ONE climb clip showed the NEXT attempt's tag too (two overlay-lane
bars over one clip), and "the default climb tag (Attempt# ON) always shows even though I set it once."

- **Root cause (one):** `visibleClipMediaIDs` scoped the CLIPS (`StudioGeometry.filterByMedia`) but NEVER
  the OVERLAYS — `canvasOverlays`/`timelineOverlays`/`scopedSnapshot.overlays` all returned the full
  project set. A foreign clip's per-clip tag (clipID owned by a non-visible clip) leaked into the canvas,
  the overlay lane, AND the export (its `outputWindow` fell back to a stored ~[0,clipDur] window that
  overlaps the single visible clip's [0,2], passing the time-gate). The "default tag that won't stick"
  was the SAME leak wearing a different hat — the other clip's persisted tag (with its flags) bleeding in;
  NOT a persistence/default bug. (11-agent review confirmed nothing auto-adds a tag and the flags persist;
  it explicitly warned NOT to "fix" the toggles — that would have been a misdiagnosis.)
- **Fix (minimal):** a pure `StudioGeometry.filterOverlays(_:clips:to:)` bridging the key mismatch
  (`OverlayItem.clipID` = a `TimelineClip.id`, not the `SessionMedia.id` that `visibleClipMediaIDs` holds):
  nil scope → all; `clipID == nil` (whole-project overlay) → kept in every scope; else `clipID → owning
  clip → sessionMediaID → membership`; orphan dropped while scoping. A VM `scopedOverlays` routes the
  three render surfaces (`canvasOverlays`, `timelineOverlays`, `scopedSnapshot.overlays`) through it.
  `overlays`/`selectedOverlay`/`climbOverlayForSelectedClip` deliberately KEEP reading the full set so a
  scoped edit still persists to the shared project and add-or-select stays idempotent.

**Process note (why this recurred):** prompt 12 made overlays per-clip but only scoped the CLIP list, not
the overlay list — a "what's scoped vs not" gap. Folding an explicit *scope-parity* check (every per-entity
list that has a visible-subset must filter BOTH the entities and anything keyed to them) into the review lens.

**Verified:** `build-for-testing` clean (0 errors / 0 warnings in changed files); `SnappetTests` green
(**889**, +2 new `filterOverlays` cases).

## 2026-06-18 — Studio editor: tapping a clip shows the CLIP editor, not the climb-tag editor (prompt 14)

Bug (user): with a climb tag on, tapping the video clip in the timeline popped the climb-tag OVERLAY editor
(Attempt#/opacity) instead of the clip editor, hiding the clip's trim/speed/filter options.

- **Root cause:** prompt 12 STEP 5 coupled clip selection to overlay selection — `select(_:)` repointed
  `selectedOverlayID` to the clip's climb tag so the dynamic Attempt# could "follow the selected clip." But
  the bottom panel is `selectedOverlay != nil ? overlayBar : actionBar`, so selecting a CLIP showed the
  OVERLAY editor. Now that every tag is a per-clip property (`clipID`, prompt 12), that coupling is obsolete.
- **Fix:** `select(_:)` now sets `selectedOverlayID = nil` (clip tap → clip editor); the climb tag is
  selected only by tapping the tag (overlay-lane bar / canvas chip → `selectOverlay`). `effectiveAttemptNumber`
  now derives from the SELECTED OVERLAY's own `clipID` (a tag's attempt is intrinsic to its clip), falling
  back to `selectedClip?.id` (the add-a-tag moment) then `suggestedAttemptNumber`. Removed the now-obsolete
  `selectedClipAttemptNumber` + `refreshAttemptLineForSelection`. `hasClimbOverlay`/"Climb ✓" read
  `climbOverlayForSelectedClip` (clip HAS a tag), independent of selection — unaffected.

**Verified:** build clean (0 errors / 0 warnings in changed files); `SnappetTests` green (**889**);
`LiveWorkoutStudioWalkthroughTests` + `NamedClimbTests` pass.

## 2026-06-18 — Add-a-climb: re-log a previous climb, setter, photos (prompt 81)

Made `AddClimbSheet` a complete capture surface: a **"Log a previous climb"** picker above Type, an
optional **Setter** field, and optional **Photos** (photos-only).

- **Previous climbs are DERIVED, not stored.** Quick Session climbs have no content identity
  (`SessionExercise.id` is per-instance; the UUIDv5 `KilterClimbIdentity` is a different feature). The new
  pure `PreviousClimb` (`PreviousClimb.swift`, Foundation-only, unit-tested) flattens `.climbAttempt`
  exercises from `history` + the live session, **dedups on a normalized key** (type·scale·grade·name·gym·
  wall·colour — case/whitespace-insensitive on free text), keeps the most-recent instance, caps at 12, and
  filters (All/Boulder/Routes · This gym · Sent · search). `FreeformPlayerView` builds the catalog (+ a
  photo map from a `FetchDescriptor<SessionMedia>` over photos by `assignedExerciseID`) and caches it like
  `climbStats`/`prefills` (rebuilt on appear / exercises-change, never the ~1 Hz re-render); the sheet stays
  a pure capture surface.
- **Re-log = a brand-new climb.** Selecting a previous climb calls the existing `seed(from:)` to prefill
  every field, then commit creates a fresh `SessionExercise` — history is never mutated and old
  photos/attempts are **not** copied. A one-shot `suppressTypeSnap` stops the type `.onChange` grade-snap
  from clobbering the prefilled scale/grade when the discipline differs.
- **Setter** is one additive `String?` on `SessionExercise` (next to gym/wall/colour — lightweight
  migration) + `AddClimbParams`; persisted in `addClimbFromSheet`/`updateClimb`. Its own section (per the
  approved wireframe), not tucked in "More".
- **Photos reuse the shipped media stack, no schema change.** The sheet can't mint the climb's
  `SessionExercise.id`, so it collects picked `localIdentifier`s into `@State` (photos-only `MediaPicker`,
  via a new additive `filter` param) and returns them on `AddClimbParams.photoLocalIdentifiers`;
  `addClimbFromSheet` files them as climb-level `SessionMedia` (`assignedExerciseID == climb.id`,
  `assignedSetIndex == nil`, `source == .manual`, `kind == .photo`) via
  `SessionMediaService.candidates(forIdentifiers:)` after the climb exists. Bytes never copied (on-device,
  PHAsset id only); the previous-climb rows show a first-photo preview via a `localIdentifier`→thumbnail
  `ClimbPhotoThumb`. Photos + the previous-climb picker are **ADD-mode only**; Setter shows in both modes.
- **Sheet opens at `.large` with a pinned CTA bar.** The richer form (previous-climb + setter + photos on
  top of type/grade/colour/name/gym/wall) no longer fits a `.medium` half-sheet, so the sheet opens at
  `.large` (still draggable to `.medium`) and the primary CTA(s) move out of the form into a
  `.safeAreaInset(.bottom)` bar — always visible above the scroll and the keyboard. This also fixed an
  XCUITest reachability regression (the old in-form bottom CTA fell below the longer form's fold).

**Verified:** `build-for-testing` clean (0 errors / 0 warnings in changed files); `SnappetTests` green
(**904**, +15 new `PreviousClimbTests`); the new `PreviousClimbSetterPhotosTests` (re-log prefills the form,
setter round-trips, photos affordance present) + `NamedClimbTests`/`EditClimbTests`/`ClimbAttemptTimerTests`
pass on the iPhone 17 Pro sim. (`TrackingTypeFilterTests` fails identically on baseline — a pre-existing,
unrelated sim issue.)

**Adversarial review fixes (same day, prompt 81):** a 3-dimension review (find → independently verify) of
the diff surfaced 5 confirmed items; 4 folded in: (a) **photo leak** — `selectPrevious` now clears
`photoIdentifiers` so a re-log can't inherit photos picked for an abandoned new-climb entry (the "old
photos not copied" contract); (b) **truthful Sent filter** — `PreviousClimb.catalog` now FOLDS `bestStatus`
across all deduped instances (flash>sent>project>attempt) so a climb sent in an earlier session still
passes "Sent" when the latest session was only attempts (+ a `testCatalogFoldsBestStatusAcrossSessions`
case); (c) **no duplicate media** — `attachClimbPhotos` passes the session's existing `localIdentifier`s as
`existingIdentifiers` (mirrors `SetMediaStrip.attach`) so re-picking an auto-discovered asset is a no-op;
(d) **fresh previews** — `rebuildPreviousClimbs()` also runs on sheet-open so the picker's photo
thumbnails/counts aren't stale within a session. The 5th (setter-search misses a merged-away older setter,
low) is accepted as a design tradeoff — setter is non-identity and the most-recent setter stays searchable.

## 2026-06-19 — Workout-Type Parity — Phase 0 (two-axis model: discipline + measurement axes)

Foundation for bringing **Strength, Running, Dance, Other** to climbing's entity→effort structure
(`docs/ux-research/workout-type-parity/`). Pure-logic only — **no new UI, no SwiftData migration.**

**Two orthogonal axes instead of the monolithic `SetKind`.** A new `WorkoutDiscipline`
(`strength/climb/run/dance/timed/other`) on the entity (`SessionExercise.disciplineRaw`, computed
`discipline`); the *measurement axes* (reps · weight · `durationSec` · `distanceMeters` · outcome) stay
independent on each `SetLog`. `WorkoutDiscipline.swift` is pure (Foundation only) — `label`/`symbol`/
`defaultSetKind`/`primaryAxis` + a `legacyKind` init; the accent `Color` and the `HKWorkoutActivityType`
map are deliberately **not** on the enum (view / HealthKit concerns, added in later phases).

**`SetKind` is NOT extended.** Run/dance/other entities are `kind == .duration`, distinguished by
`discipline` (run also fills `distanceMeters`). This keeps the existing 3-case kind switches valid and
avoids a churny migration; the discipline axis carries the new types.

**Migration- and backup-safe by construction.** `disciplineRaw`/`distanceMeters`/`rpe` are additive
`Optional`s on the Codable composites (`SetLog`/`SessionExercise`) — old blobs decode them as `nil`
(`discipline` then derives from `kind`), and because synthesized `Codable` omits a nil optional via
`encodeIfPresent`, the encoded form (and the backup golden bytes) is unchanged for existing data. No
`@Model`, no `SnappetSchema` change. Tests assert the encoded JSON does **not** contain the new keys when nil.

**Pace is derived, never stored** (distance + duration) to avoid drift; `DistanceUnit` (km/mi) added next
to `WeightUnit`, sticky per user (threaded into `FreeformSummary.stats` in a later phase — Phase 0 defaults
distance to km).

**`SetMeasure`** gained the combined reps×weight×time row ("8 × 60 kg · 0:42", mirroring the climb branch's
existing precedent) + pure `formatDistance`/`formatPace`/`runSummary` (wired by the running phase).
**`FreeformSummary.dominant`** now counts by `discipline` (regression-safe — legacy kinds derive to the same
`.lifting`/`.climbing`/`.timed`) with `running`/`dance`/`other` added and the `stats` headline made
exhaustive (running→Distance, dance/other→Active).

**Verified:** see the build/test run stamped on the commit (Swift 6, 0 warnings; new
`WorkoutDisciplineTests` + extended `SetMeasureTests`/`FreeformSummaryTests` green).

## 2026-06-19 — Workout-Type Parity — Phases 1–6 (all disciplines log like climbing)

Built on the P0 two-axis model. Each phase shipped build-green + unit-tests-green + a per-phase
review agent + a commit (branch `claude/workout-type-parity`). Wireframe/plan in
`docs/ux-research/workout-type-parity/`; phase prompts in `pdd/prompts/features/workout-type-parity/`.

**P1 — shared foundation.** Renamed `expandedClimbs` → `expandedEntities` (one expand-state for all
disciplines); added `EntityCard.swift` (`WorkoutDiscipline.accent` view-layer color kept OUT of the pure
enum; `EntityRollupChip` — the strength/run/timed analogue of the climb grade pill). No behavior change to
the climb card (kept as the template).

**P2 — strength as an expandable card.** Replaced the flat `liftingOrTimedSection` with
`strengthSection`/`strengthHeader`/`strengthRollup` (rolled-up top set · N sets · e1RM via the pure
`StrengthStats` Epley; set list + quick-add + per-set media + footer). **`addLifting` auto-expands** the new
card so quick-add stays immediately reachable (preserves `QuickAddSetTests`). New header a11y ids
`freeform.entityName`/`.expand`/`.entityMenu`; the quick-add/setRow/addSet/repeatSet ids preserved
(UITest contract). Hybrid ⚙ add + inline edit deferred (task #10).

**P3 — timing is an orthogonal axis.** `TimedSetCover` (count-up FOCUS cover with reps/weight steppers,
no outcome grid — the strength analogue of `TimedAttemptCover`) + 'Time this set' footer
(`freeform.timeThisSet`) → commits `SetLog(reps,weight,durationSec)` → the combined "8 × 60 kg · 0:42" row.
STOP commits once (no double-log); empty effort isn't logged.

**P4 — running discipline.** `exerciseSection` now switches on `ex.discipline` (cleaner + forward-
compatible). `addRun` (a `.run`/`.duration` entity) + `runSection` (total distance · avg pace · N legs via
the pure `RunStats`) + `AddRunLegSheet` (manual distance+duration → derived pace; `SetMeasure.runSummary`).
**`distanceUnit` derives from the weight unit** (lb→mi) — a v1 simplification; a sticky toggle + Watch/GPS
distance are deferred (issue #177).

**P5 — Dance/Other + six-type chooser.** `addOpenEffort` (lightweight `.duration` dance/other entities) on
the now **discipline-aware timed card** (icon/accent from `ex.discipline`, so the one card serves
timed/dance/other). Empty-state restructured from a 3-card HStack to a **2-column grid of all six**
(existing card ids preserved, `freeform.cardRunning/Dance/Other` added) + add-menu items.

**P6 — cross-type clip menu.** `climbClipMoveTargets` generalized to `clipMoveTargets(for:)` — titles by
discipline noun (Attempt/Leg/Set); `SetMediaStrip` gains `moveTargetsLabel`; the strength + run per-set
strips now wire the move/remove/delete deep-tap menu (was climb-only). The analytics half (pure session
stats bridges → live ribbon for all disciplines + a mixed-session roll-up summary) is **deferred** (task
#8 follow-up); the completion summary already type-adapts its headline from P0.

**Deferred / tracked (not regressions):** the "Remove from attempt" clip-menu wording stays climb-worded
for strength/run (functionally correct); hybrid ⚙ strength add + inline edit + recent chips (#10); the
analytics ribbon/mixed-summary; and the cross-cutting items — watch `HKWorkoutActivityType` per discipline,
the saved-session `SessionDetailView` SetTileRow second kind-switch, the `HistorySectionView` discipline
facet, and the `SnappetBackup` golden + Android `BackupRoundTripTest` (no new non-nil fields in old data →
golden stays stable until those are exercised). Android is its own wave.

## 2026-06-19 — Workout-Type Parity — completion cards, live ribbon, saved detail, strength polish

Post-device-build follow-ups (the two "worth doing now" items + the strength polish), shipped on
`claude/workout-type-parity` (PR #178), each build-green + unit/UITest-green + a review agent.

**P7 — completion-summary cards** for the new disciplines (were EmptyView): RUNNING → hero
Distance·Pace·Duration + a Runs card (per-run legs·distance·avg-pace via `RunStats`) + the type-agnostic
time-in-zone Effort block; DANCE/OTHER → routed to the timed recap (they're `.duration`); `timedExerciseRows`
excludes `.run` so a run leg never lists as a timed hold.

**P8 — live aggregate stats ribbon** for non-climbing sessions (`disciplineRibbonSection`): strength
Volume·sets, running distance·pace, timed TUT·sets; climbing keeps its rich tappable ribbon. New id
`freeform.disciplineRibbon`.

**P9 — saved-session detail** (`SessionDetailView.SetTileRow`): a `.run` leg renders distance·time·pace
(`SetMeasure.runSummary`) and a timed-strength set appends its duration; the row is now discipline-aware
(the second kind-switch the review flagged).

**Review fix:** `holdTimeSeconds`/`bestHoldLabel` excluded `.run` — a run is a `.duration` entity, so it was
over-counting a timed session's TUT (regression test added).

**Strength polish (closes the hybrid-add intent):** one `StrengthEditSheet` reached from the card ⋯ →
"Edit details" (`freeform.editEntity`) does rename + a default sets×reps×weight×unit (the `target*` columns)
+ a one-tap "Last time" chip; `quickAddSeed` now falls back to `target*` before the hardcoded 8/bodyweight,
so a fast bulk pick + a per-card default carries into the first set. `updateStrength` overwrites in place.
*Recents* ships as the single "Last time" chip (multi-entry history rail deferred).

**Device:** built + installed + launched on MrRobot (iPhone 13 Pro Max) via `-allowProvisioningUpdates`
(team NFUS5W8QC6 auto-provisioned; no entitlement strip needed).

## 2026-06-19 — Workout (Gym Tracker) redesign — direction + keystone locked (planning; impl gated on wireframe review)

Planning for a broad Gym-Tracker redesign (more intuitive app; creative dashboard + session detail; a library
of all workout types; routines with full type parity; QR routine sharing; smart planning; save-a-quick-session
as a routine). Full design + phased plan in `docs/ux-research/workout-redesign/README.md`
(+ `wireframes.html`, `research-appendix.md`); PDD chain in `pdd/prompts/features/workout-redesign/PLAN.md`
(E0–E7 + hardening). Driven by a 14-agent research workflow (8 file:line code maps + 6 design sweeps) and an
8-agent wireframe pass. Implementation is **gated on the user reviewing the wireframes first**
([[wireframe-before-implementation]]).

**Keystone architecture decision.** The freeform Quick Session already carries the rich two-axis model
(`WorkoutDiscipline` + measurement axes on `SessionExercise`/`SetLog`), but **`RoutineExercise`
(`WorkoutModels.swift:216-226`) has no discipline field** — so routines, the guided `WorkoutPlayerView`, and
the builder are reps×weight-locked. The redesign's spine is to **add `disciplineRaw` + per-axis target
Optionals to `RoutineExercise`** (additive Optionals on a Codable composite ⇒ migration-free, the documented
`:220-225` invariant) and make `makeSession(from:)` (`WorkoutTrackerModule.swift:403-417`) propagate it. That
one change unblocks routine parity, save-as-routine, QR-share, and smart planning — all routine-shaped. **No
new `@Model` in the keystone** (per-entity history `@Model` stays deferred); backup golden bytes + the Android
store mirror are the not-free parts (the Workout-Type-Parity §8 caveat).

**Three calls locked with the user:**
1. **Visual direction = "Pulse Pro" evolution** (not a bolder departure, not minimal cleanup): score-first
   hero numerals; a **two-axis color contract** — discipline accent = wayfinding, a NEW performance ramp
   (leaf `0x3F9D55` → amber `0xB45309` → tomato `0xE5483D`) = effort/zone/PR state, `brand` coral reserved
   for the single primary CTA; a type-adaptive recap scaffold; glass-on-chrome only; dark-mode-first; earned
   PR celebrations. **Elevates the existing `SnappetColor` tokens — no rebrand.**
2. **First build wave = Foundation → Dashboard → Session detail** (E0→E1→E2): the two visible wins need **no**
   model change, so they ship before the routine-parity spine (E3→E4) and the share/plan/save phases.
3. **Smart planner = heuristic core + on-device Apple Intelligence sharpener** (E7): a pure, deterministic,
   always-available recommender (per-muscle recovery/volume/recency + strategy presets, modeled on
   `KilterRecommender`) **plus** an optional on-device **Foundation Models** pass for natural-language tweaks
   ("15 min, no barbell"), gated to capable devices and **degrading silently to the heuristic**. No server
   LLM (on-device-only). Extends the [[receipt-ocr-apple-intelligence-followup]] direction.

## 2026-06-19 — Workout redesign E4 — Routine parity (THE KEYSTONE), iOS

The spine of the redesign (`docs/ux-research/workout-redesign/README.md` §2/§5; PDD prompt
`pdd/prompts/features/workout-redesign/E4-routine-parity.md`; issue #184). Propagated the two-axis discipline
model the freeform side already proved to the routine side, so a routine can mix a strength block, a timed
circuit, a graded climb, and a run — and the guided player logs each like the freeform canvas does.

**Migration approach (the critical bit).** `RoutineExercise` is a nested `Codable` composite (inside
`Routine.exercises` / `SnappetBackup.RoutineRow`), NOT an `@Model` — SwiftData lightweight migration doesn't
reach inside the blob. The keystone fields (`disciplineRaw`, `targetDurationSec/DistanceMeters/RPE`,
`climbTypeRaw/climbGradeLabel/climbGradeScaleRaw`, `timedSpecData/timedCategory`) are therefore added as
**additive `Optional`s**: synthesized `Codable` decodes a *missing* key as `nil` AND **omits a nil optional
on encode** (verified empirically before relying on it — a `swift` repro showed `New(nil optionals)` encodes
byte-identically to the legacy struct). So a pre-E4 `Routine` decodes with `disciplineRaw == nil` (→
`discipline` derives `.strength`, every target nil) and **`SnappetBackupTests`' golden round-trip +
determinism stayed green** — the additive nils did NOT shift the bytes (the documented
`SetLog`/`SessionExercise` invariant). Pinned by `RoutineExerciseMigrationTests` (legacy-blob decode +
byte-omission assertions) so a future non-additive field fails the test instead of silently corrupting old
routines or shifting golden bytes. The `RoutineExercise` init keeps `disciplineRaw` nil for a strength block
(strength is the implicit default) so a strength routine session is byte-identical to a pre-E4 one.

**`makeSession` discipline propagation.** Extracted the mapping into a pure, device-free
`RoutineSessionBuilder` (unit-tested without a simulator): each block → a `SessionExercise` with
`se.disciplineRaw = re.disciplineRaw` + `se.kindRaw = discipline.defaultSetKind.rawValue` + the
climb/timed/distance metadata carried through; a fresh climb attempt is stamped with the prescribed grade so
the pyramid reads. `block(from: LibraryItem)` is the inverse — the E3→E4 builder pipeline that seeds a typed
block from a picked library item.

**Mixed-session HK decision (README §10 Q1, resolved).** Added `WorkoutDiscipline → HKWorkoutActivityType`
(run→`.running`, climb→`.climbing`, dance→`.cardioDance`, timed→`.highIntensityIntervalTraining`,
strength→`.traditionalStrengthTraining`, other→`.other`) and `activityType(disciplines:sport:category:)`. A
**single-discipline** routine records that discipline's type (a run is NEVER silently logged as strength). A
**mixed** routine records `.mixedCardio` — one `HKWorkoutSession` holds one activity type, so a mixed session
can't faithfully be any single one; `.mixedCardio` is the honest umbrella. An all-strength / pre-E4 routine
falls back to the legacy `sport`/`category` path unchanged. `LiveMetricsCoordinator.start(for:disciplines:…)`
threads the routine's per-block disciplines.

**Actuals→prescription (README §10 Q3) — deferred to E5** as designed (save-as-routine). E4 only carries the
prescription *forward* (routine → session); the inverse (session actuals → a reviewable prescription) is E5's
pure converter.

**Scope call — the guided player LANDED** (not descoped to E4b). The discipline-aware input block +
`completeSet` switch on `current.discipline` (climb outcome+grade rail · timed/dance/other via the shared
`StopwatchView` · run distance+duration · strength reps×weight unchanged), composing the right `SetLog` axes
per discipline. The 826-line player's stateful machinery (resume/prefill/step-back/rest/Live-Activity) is
untouched — only the per-set input + the logged-set write were threaded. This was necessary, not optional:
the re-authored starters now include an all-`.timed` "5-Minute Mobility" (which sorts first alphabetically),
so the `WorkoutWalkthroughTests` routine flow drives a timed routine end-to-end through the player.

**Starter re-author.** Two genuine climb-discipline starters (a boulder Session Pyramid + a Routes Volume
Night) prescribe real climbing; every timed hold (planks, stretches, mountain climbers, wall sits) is now a
`.timed` block with a `targetDurationSec` + a `TimedExerciseSpec.hold(_)`, not a faked `"30s"`/`"60s"` reps
string.

**Android (wave H, tracked).** The parallel `WorkoutModels.kt` / Room store + `BackupRoundTripTest` mirror is
deferred to the hardening wave — iOS is the lead platform and the Android tree was not touched.

**What E5/E6/E7 build on.** `RoutineExercise` now carries the full per-block prescription shape
(`discipline` + per-axis targets + climb/timed metadata) and `RoutineSessionBuilder.exercises(from:)` /
`block(from:)` are the pure, tested round-trip seams. E5 (save-as-routine) writes the inverse of
`RoutineSessionBuilder` (actuals → a `RoutineExercise` per discipline); E6 (QR share) serializes the
`RoutineExercise` composite (exerciseId references); E7 (planner) emits a `[RoutineExercise]`.

## 2026-06-19 — Workout redesign E7: smart workout planning (heuristic + on-device Apple Intelligence) (#187)

**Shipped.** A pure `WorkoutRecommender` (modelled 1:1 on `KilterRecommender`) + a per-muscle extension of
`WorkoutHistoryStats` + a `WorkoutPlanLogic` readiness verb + an editable-draft screen (`WorkoutPlanView`),
with an **optional on-device Foundation Models sharpener** behind a degrade-to-heuristic seam. Files:
`Features/WorkoutTracker/WorkoutRecommender.swift`, `WorkoutPlanLogic.swift`, `WorkoutPlanTweak.swift`,
`WorkoutPlanView.swift`, extended `WorkoutHistoryStats.swift`; `Services/WorkoutPlanIntelligence.swift`;
`TodayDigest.workoutPlan`; dashboard `Plan a session` entry. Tests: `WorkoutRecommenderTests` (14),
`WorkoutPlanLogicTests` (12), `WorkoutPlanTweakTests` (11), `WorkoutHistoryStatsTests` (+5 per-muscle),
`WorkoutPlanFlowTests` (UI). All green on iPhone 17e.

**The recommender mirrors Kilter exactly.** `Strategy` (balanced/hypertrophy/strength/recovery/timeCapped) →
`StrategyConfig` (count + `Mix` + a rep/rest `Scheme`) → `Options` → largest-remainder `allocation` →
`recommend`, deterministic with stable tie-breaks + a `rerollSeed` rotation. `Goal` =
warmUp/main/accessory/finisher. The same "the view does the I/O, the core is pure value types" contract.

**The per-muscle signal — join at the I/O edge.** `WorkoutHistoryStats.make(history:resolved:)` takes
`ResolvedSession`/`ResolvedSet` value snapshots whose `Exercise.primaryMuscles` were joined *in the view*
(`WorkoutPlanView`, where the `@MainActor ExerciseResolver` lives) — the pure core never touches SwiftData
or the resolver. It emits `daysSinceByMuscle` / `lastTrainedByMuscle` / `weeklyVolumeByMuscle` (rolling
7-day completed-set count). The old `make(history:)` stays for E0 callers (muscle maps empty).

**Decision — never-trained muscle freshness is *moderate*, not maximal.** `focusMuscles` biases toward the
least-recently-trained muscle, but treats a never-trained muscle as `untrainedFreshnessDays = 6` (not ∞).
Otherwise the 14 muscles a lifter has never logged would always crowd out a genuinely-rested trained one
(the first failing test surfaced this — focus came back `[abdominals, abductors, adductors]`). 6 days sits
*below* a well-rested trained muscle (7+ days leads) but *above* a recently-trained one, so the plan biases
toward what the user actually trains while still giving a beginner sensible variety.

**Decision — fill the `main` block FIRST.** Warm-up also ranks by muscle-freshness, so running it before
`main` let it steal the prime compound off the freshest muscle. We fill `main` first (it's the anchor), then
warm-up/accessory/finisher draw from what's left; the *display* order (warm-up → main → …) is restored by a
final sort. (A second failing test surfaced this.)

**Decision — Apple Intelligence parses *inputs*, not the *plan*.** The locked decision is "AI is a
sharpener, never required." Rather than have the LLM emit a whole workout (untrustworthy / unexplainable),
`WorkoutPlanIntelligence.resolve(phrase:)` asks Apple's Foundation Models system model to structure a
natural-language tweak into the **same** deterministic `WorkoutPlanTweak` the heuristic parser produces —
then the **pure `WorkoutRecommender` still builds the plan** from those constraints. The plan stays
deterministic, auditable, and explainable; the AI only fills in the inputs. `WorkoutPlanTweak.apply(to:)` is
the single place a tweak becomes recommender inputs, shared by both paths so they can't diverge.

**FoundationModels seam status — REAL call, SDK/device-gated, degrades silently.** The iOS 26 SDK ships
`FoundationModels`; the deployment target is iOS 18. So the import is behind `#if canImport(FoundationModels)`
+ `@available(iOS 26.0, *)` + a runtime `SystemLanguageModel.default.isAvailable` gate. The real call uses a
`@Generable PlanTweakSchema` + `LanguageModelSession.respond(to:generating:)` with an 8-second `withTimeout`
race; **any** unavailability/error/timeout returns the heuristic floor (`resolve` always computes the
heuristic first and only *replaces* it on AI success). On the simulator the model is unavailable, so the
seam is verified to return `.heuristic` (`WorkoutPlanTweakTests`). **On-device only — no network, no server
LLM** (the hard constraint). The `@Generable` macro forced `PlanTweakSchema` to be `fileprivate` (not
`private`) so the macro-expanded conformance can reach it — the one non-obvious compile gotcha.

**`@Generable` gotcha.** A `@Generable private struct` fails to compile ("inaccessible due to 'private'") —
the macro expands a conformance in a separate synthesized file that can't see a `private` type. Use
`fileprivate` (or `internal`) for any `@Generable` type nested in an enum.

**Started session = a freeform session.** "Start this session" seeds a *routineless* `WorkoutSession` from
the plan's `[RoutineExercise]` (via `RoutineSessionBuilder.sessionExercise(from:)`) so it uses the
grow-as-you-go `FreeformPlayerView` — the user can add/swap on the fly. "Save as routine" hands the
`[RoutineExercise]` + a verb-folded default name to a pre-filled `RoutineEditorView` (new
`prefillExercises`/`prefillName` params, used only for a new routine) for review/rename before saving.

**Scope.** v1 plans **strength** sessions only (the candidate pool filters to strength/powerlifting; emitted
blocks are strength → `disciplineRaw == nil`, the additive-nil invariant). The `Plan → [RoutineExercise]`
bridge already returns the routine shape, so a later tier can widen it to discipline-mixed plans.

**Merge-conflict anticipation with E5/E6.** This phase touched `WorkoutTrackerModule.swift` (added a
`WorkoutPlanRoute` destination, a `PlannerRoutinePrefill` sheet, `startPlannedSession`, and the dashboard
`openPlan` wiring), `WorkoutDashboardSection.swift` (added an `openPlan` param + a `planEntry` row in both
the populated and empty states), `RoutineEditorView.swift` (added `prefill*` params + a `loadExisting`
branch), `TodayDigest.swift` (added `workoutPlan`), and `HomeDashboardView.swift` (added a `workoutPlan`
card in the `else` of the resume-workout card). E5 (save-as-routine from the freeform summary) and E6 (QR
share) also touch `WorkoutTrackerModule`/`RoutineEditorView` — the additions here are all new members at the
ends of their sections, so conflicts should be small and mechanical.
## 2026-06-19 — Workout redesign E6: share a routine via QR (#186)

**The reuse, generalized.** Kilter already had an offline QR stack (a `KilterClimbLink` codec + a CoreImage
QR renderer + an AVFoundation scanner + the `SnappetDeepLink` route table + the `SuiteRouter` one-shot +
`KilterDeepLinkRouting.explainMissing`). E6 lifts that into reusable pieces rather than forking it:
- **`SnappetShareable`** (`Core/SnappetShareable.swift`) — a tiny protocol (`url` + `init?(decoding:)`,
  default `encoded`). `KilterClimbLink` and the new `SharedRoutine` both conform, so ONE QR renderer
  (`QRCodeImage.make(for:)`, the lifted `qrImage`) and ONE scanner serve both.
- **`SnappetScannerView`** (`Core/SnappetScannerView.swift`) — the AVFoundation plumbing (the old private
  `QRScannerRepresentable`/controller) lifted into a generic scanner taking a `decode:` closure.
  `KilterScannerView` is now a thin wrapper over it (passing the climb decoder), so the climb + routine
  scanners share one camera path and can't drift. The Kilter scanner's a11y id (`kilter.scanner`) is
  preserved; the full-bleed look became a rounded-rect preview (cosmetic).

**`SharedRoutine` codec — reference-not-payload, then squeeze.** A user routine is on no shared catalog, so
unlike a climb (a single uuid reference) it must carry the routine. We keep it small by carrying **`exerciseId`
references** (both phones ship the same 870-row catalog + the same timed/climb structures) — NOT full
`Exercise` defs — in a **terse `Codable`** (1–3-char `CodingKeys`, omit-nil/omit-default on encode), then
**raw DEFLATE** (Apple `Compression`, `COMPRESSION_ZLIB` = the raw stream, no zlib/gzip header — smallest form;
distinct from the gzip *inflate* the Kilter catalog download does via the `zlib` C lib) → **base64url** (RFC
4648 §5, no padding) → `snappet://routine/v1/<blob>`. Pure value + codec → unit-tested without a camera.

**Measured size + the QR-vs-link threshold (README §10 Q4).** The realistic case is comfortably small:
- A realistic **11-block mixed routine (strength + timed + climb + run) = 519 encoded URL bytes**.
- `scannableURLByteCap = 900` bytes (conservative — a QR v40 at ECC-M holds ~2300 alphanumeric chars, so 900
  URL bytes scans easily at arm's length). `fitsInScannableQR` gates the QR; past it the sheet hides the QR
  and leans on the always-present `ShareLink` (link/file) — the honest size handling the design calls for.
- **Surprise from the tests, worth recording:** deflate crushes repetitive content so hard that a 60-block
  routine of *repeated* notes was only 755 bytes. A routine only really exceeds the cap when its content is
  genuinely **diverse/high-entropy** (many custom names + distinct notes) — a 40-block routine of unique
  `custom-<uuid>` ids + per-block notes clears it. So the fallback is correctly reserved for the rare large,
  diverse routine, and the common case is always a QR.

**Custom-exercise handling (the documented call).** A `custom-…` exercise id won't resolve on the other
phone (it's not in the shared catalog). We **inline the block's `displayName`** (already a terse field) so an
imported custom block stays legible with its real name, AND flag the id via
`SharedRoutine.unresolvableExerciseIds(resolving:)` — the `KilterDeepLinkRouting.explainMissing` analog — so
the import-confirm preview shows a graceful *"N exercises aren't in your library"* line. The block still
imports (never dropped, never silent). We deliberately did NOT inline a full minimal `Exercise` definition:
it would bloat the blob and a custom strength move needs no catalog metadata to be logged as reps×weight.

**Route + import — additive, never silent, never overwrite.** `SnappetDeepLink.route(for:)` gained
`case routine(SharedRoutine)`, tried **after** the climb decode so a climb URL still routes to Kilter (no
regression — locked by `testClimbStillRoutesToKilterNotRoutine`). `RootShell.handle` stages
`SuiteRouter.pendingRoutineImport` (the `pendingKilterClimb` pattern) + `open(module: "workout-log")`;
`WorkoutHomeView` consumes it (`onChange initial:true`, self-clearing) into a **`RoutineImportSheet`** preview
(name + blocks + the missing-ids line) → on confirm `importRoutine` inserts a **NEW `Routine` (new UUID)** with
fresh-id blocks (`SharedRoutine.routineExercises()`) — never overwrites an existing routine. The
`RoutineDetailView` qrcode toolbar button opens a segmented **My Code / Scan** `RoutineShareView`; a scan there
routes through the SAME router one-shot (one import brain), popping to root so the preview surfaces on the
tracker root that owns the model context.

**Testing.** Pure: codec round-trip (every block field), fresh-id-never-overwrite, byte-stable strength block,
measured size + threshold, `unresolvableExerciseIds`, custom-name survival, version/scheme rejection, the
base64url + raw-deflate primitives, and the **open path** (URL → route → one-shot → new-UUID insert) — all
device-free. The camera scan is the only device-pending half (the Kilter precedent). Build + the codec/routing
suites + the existing Kilter deep-link suite green on iPhone 17.

**Android (wave H, tracked).** The Android Kilter share loop (#91) already proves the cross-platform
`snappet://` shape; the routine-share mirror (a `SharedRoutine` Kotlin codec + the same deflate/base64url +
the import sheet) is deferred to the hardening wave — iOS is the lead platform and the Android tree was not
touched.
---

## 2026-06-19 — E5: Save a Quick Session as a repeatable routine (workout-redesign, wave 3)

> (Appended at the END, out of reverse-chronological order, to minimize merge conflicts with the parallel
> wave-3 agents E6/E7 — per the E5 orchestration brief.)

**Actuals→prescription is a pure, lossy, USER-REVIEWED converter — `SessionToRoutine` (the inverse of E4's
`RoutineSessionBuilder`).** A finished session is a *record* (1 set here, 6 attempts there, an open hold); a
routine is a *plan*. Collapsing one to the other discards detail and makes judgement calls, so the conversion
is pure + device-free (Foundation only, unit-tested in `SessionToRoutineTests`) and its output is **reviewed in
the editor before anything is inserted** (README §10 Q3). We keep it the deliberate inverse of
`RoutineSessionBuilder` (same per-discipline `switch`) so a freeform → routine → freeform round-trip preserves
discipline — pinned by a round-trip test through both seams.

**Per-discipline prescription rules (defensible + overridable):**
- **strength** → completed-set count × **modal** completed reps (most-frequent working reps; ties → the
  higher reps) × the **top weighted set** (heaviest by `weightKg × reps`, the PR ranking) in its OWN logged
  unit (not converted — show what was lifted). `disciplineRaw` stays nil (the additive-nil strength default,
  so a strength-only saved routine is byte-identical to a hand-built one).
- **climb** → the climb is the slot: type + grade + scale carried through; `sets` = the logged attempt count.
- **timed** → the `TimedExerciseSpec` + category verbatim. A **structured** protocol (repeaters/tabata/emom)
  keeps its own set count + NO extra `targetDurationSec` (the spec already carries work seconds); a **simple**
  hold uses the completed-set count + a **median** hold target (median, not mean, so one outlier hold doesn't
  skew the prescription).
- **run** → a single block targeting Σ completed distance (pace is derived, never prescribed). Never a weight.
- **dance / other** → a duration block with a median active-duration target.
- An exercise with **no completed set is dropped** (prescribing zero sets is meaningless — the lossy-but-clean
  call; warm-ups the user didn't log fall away, and the rest is trimmable in the editor).

**The editor is pre-filled for REVIEW, not silently inserted.** Added an additive optional `prefill:
RoutineDraft?` to `RoutineEditorView` (used only when `routine == nil`): it seeds the local staged state, then
Save takes the EXISTING new-routine INSERT path (a brand-new `Routine` with a fresh UUID + the "Created
routine" activity log). So save-as-routine reuses one editor + one insert+log path; the user trims warm-ups /
renames / adjusts targets first, and the loop never writes a routine behind the user's back. `RoutineDraft` is
a pure value type (`Identifiable`, drives the `.sheet(item:)`), not a new `@Model`.

**The CTA is the screen's single brand-coral moment (the two-axis color contract).** "Save as routine"
(`freeform.saveAsRoutine`) on `FreeformDoneSummaryView.actionBar` is tinted `SnappetColor.brand` (coral) — the
one "make this repeatable" CTA — while Done stays `SnappetColor.workout` (the discipline accent) and View
detail / Discard stay neutral. Shown only when `SessionToRoutine.canConvert` (≥ 1 completed set), so it never
offers to save an empty plan.

**Name/sport suggestion (lossy, overridable).** The suggested routine name reuses the session's name unless
it's the generic "Quick session" placeholder, in which case it's a dominant-discipline label ("Climbing
session" / "Strength session" / …). `suggestedSport` maps the dominant discipline to a back-compat `SportTag`
(climbing → `.climbing`, else `.general`) — lossy (3 tags vs 6 disciplines, README §10 Q2); the per-block
discipline is the real identity axis the routine carries.

**Verification.** `build-for-testing` SUCCEEDED (iPhone 17 Pro Max); `SessionToRoutineTests` (18) +
`RoutineSessionBuilderTests` (5) + `FreeformSummaryTests` (9) + `RoutineExerciseMigrationTests` (17) = 54 tests,
0 failures; `FreeformFlowWalkthroughTests/testSaveQuickSessionAsRoutine` (Quick Start → log → Finish → Save as
routine → review → Save → routine appears in Routines) green.

**Android (wave H, tracked).** No Android tree touched — save-as-routine is an iOS-only UI/converter wave; the
Kotlin mirror rides the E4 keystone wave.


## 2026-06-19 — All-axis session-detail edit + RoutineEditor prefill unify (E2/E7 follow-ups)

Two iOS loose ends from the workout-redesign waves, shipped together on `feat/workout-redesign-allaxis-edit-cleanup`.

**All-axis edit (the E2 follow-up).** `SessionSetEditing` was reps/weight-only — a fat-fingered climb grade,
hold time, or run distance wasn't correctable. Generalized it: `Draft` now carries every axis (reps/weight,
duration, distance, grade, statusRaw, attempts); `drafts(for:)` seeds a draft for EVERY completed set of any
discipline (so the Edit button now appears for climb/timed/run sessions, not just strength); `apply` writes
ONLY the axes its discipline/kind owns. **The strength branch is byte-identical to the original** (same seed,
same parse, same unit conversion) so legacy lifting edits are regression-pinned — only NEW disciplines gain
edit. `SetEditFields` became discipline-adaptive (timed→duration; run→distance+duration; climb→grade text +
status Menu over `KilterAscentStatus` + attempts). Added pure `SetMeasure.parseDuration` ("M:SS"/secs/"45s")
+ `parseDistance` (display-unit decimal → metres) + `distanceFieldText` (the inverse), all unit-tested.
Scope guard: the combined timed-strength *duration* edit stays out (strength edit = reps×weight); pure logic
only — no model/schema/backup change (writes existing `SetLog` fields), so golden bytes are untouched.

**RoutineEditor prefill unify (the merge-train cleanup).** The wave-3 parallel merge left `RoutineEditorView`
with two prefill paths — E5's `prefill: RoutineDraft?` and E7's `prefillExercises`/`prefillName`. Removed the
E7 pair; the planner's "Save as routine" now builds a `RoutineDraft` and goes through the SAME `prefill` seam.
One save-as-routine path for both. Both flows re-verified green (`FreeformFlowWalkthroughTests` +
`WorkoutPlanFlowTests`).

**Adversarial-review fix (per-axis guard).** A 4-lens review found the edited-vs-seeded guard was
*whole-Draft*, so editing one axis re-applied untouched siblings from their rounded seed text — e.g. fixing a
run leg's distance silently dropped the leg's fractional `durationSec` (42.37 → 42), and a reps-only edit
cross-unit perturbed the stored weight ~0.01 kg. Fixed: `apply` writes each axis **only when its field
changed** from the seed, so an untouched sibling keeps its exact stored value (fractional seconds, un-rounded
metres, exact kg). Pinned by tests. *Accepted follow-up:* no XCUITest yet drives a non-strength edit field
(the round-trip logic is exhaustively unit-tested; the per-discipline `SetEditFields` branches are declarative).

**Verified (iPhone 17 Pro):** build green; full `SnappetTests` **1094 / 0 failures** (13 new: parsers + the
per-discipline round-trips + the per-axis-guard regression pins + the unchanged strength path); UI green —
`CompletionMomentTests` (incl. `testEditSetsFromSessionDetail` driving Edit→fields→Save),
`FreeformFlowWalkthroughTests`, `WorkoutPlanFlowTests`.
