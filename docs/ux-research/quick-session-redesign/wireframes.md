# Quick Session Redesign — Wireframes (all 12 surfaces)

> ASCII mockups rendered as if they were screenshots, with multiple states and edge cases (empty / no-HR / first-ever / long-session / Reduce-Motion). For styled visual versions of the key screens, open **[wireframes.html](./wireframes.html)**. Design rationale lives in **[README.md](./README.md)**. · 2026-06-18

## Contents
1. [Quick Session — start & workout-type chooser (the launchpad after Quick Start)](#1)
2. [Climbing — Session Canvas (climb list)](#2)
3. [Climbing — "Add a climb" bottom sheet (freeform Quick Session / FreeformPlayerView)](#3)
4. [Climbing — Climb detail with attempts (expanded climb card inside the running Quick Session / FreeformPlayerView)](#4)
5. [Climbing — Live timed attempt screen (full-cover FOCUS)](#5)
6. [Climbing — live in-session stats: a one-line "stat ribbon" docked just above the freeform climb cards, plus a tap-to-expand Live-stats sheet. Read-only/ambient; logging stays on the climb cards below it.](#6)
7. [Timed exercise — pick or create](#7)
8. [Timed exercise — live timed-set screen (full-screen FOCUS cover)](#8)
9. [Strength — quick set logging (freeform session: exercise card with a sets list + fast reps×weight entry)](#9)
10. [Running — quick log / live run (freeform session)](#10)
11. [Shared live command bar / mini-HUD (docked, all session types) with peek-to-expand LiveMetricsPanel](#11)
12. [Session completion summary (type-adaptive) — the "Finish" destination of a Quick Session (FreeformPlayerView.doneScreen, re-laid-out)](#12)

---

<a id="1"></a>
## 1. Quick Session — start & workout-type chooser (the launchpad after Quick Start)

*Type: all*

**Purpose.** The one-screen launchpad layered over the already-running FreeformPlayerView the instant the user taps Quick Start — it replaces today's three-card emptyStateHero (Lifting / Climbing / Timed). The session shell is auto-started, dated, and live (timer ticking off session.startedAt, HR + Live Activity warming in the persistent command bar); this surface is purely the type chooser, NEVER a setup wizard. Its job: collapse "what am I doing?" into ONE tap, route straight into the right first-entity creator (Add a climb / Add a timed exercise / pick a lift / start an open count-up), teach the new entity-then-attempt loop ("attempts log underneath it"), surface the single most-likely choice via a Resume-last card so the dominant path is one tap, keep every target in the bottom thumb zone, and never block logging behind a catalog or config step. It renders only while session.exercises.isEmpty and auto-dismisses to the canvas on the first entity add; if the user deletes back to empty it re-shows (guarded so it never flashes mid-session). NOTE on data model: the rich climb fields the populated state shows (climbType, gradeScale, climbName, attemptTimestamps[], per-climb startedAt/endedAt) do NOT yet exist on the freeform SetLog/SessionExercise path — today's freeform SetLog only carries flat climbGradeLabel/climbStatusRaw/climbAttempts and no parent grouping. Those rich fields live only on the board-only KilterLogEntry @Model. So this redesign is NOT "~1:1 reuse" as the brief claimed; it requires promoting the KilterLogEntry shape (+ two net-new fields, climbType and gradeScale) into a freeform climbAttempt PARENT and wiring KilterSessionStats.compute over it. That modeling move is the real prerequisite and is called out here so the screen is not designed on a false "already exists" premise.

~~~text
A · FIRST-EVER OPEN  (no history → no Resume card, neutral copy)
+--------------------------------------------+
| 9:41                            ...  100%  |
+--------------------------------------------+
|  v Minimize    Quick session     ||  ...   |
+--------------------------------------------+
|                                            |
|  Thu Jun 18 · 0:04 · live ●                |
|                                            |
|  What are you training?                    |
|  Pick one to log your first set — every    |
|  attempt logs underneath it.               |
|                                            |
|  +------------------+ +------------------+ |
|  | (figure.climb)   | | (dumbbell)       | |
|  |  Climbing        | |  Strength        | |
|  |  boulder·TR·lead | |  reps × weight   | |
|  +------------------+ +------------------+ |
|  +------------------+ +------------------+ |
|  | (timer)          | | (figure.run)     | |
|  |  Timed           | |  Run             | |
|  |  hangs·planks·   | |  duration ·      | |
|  |  intervals       | |  distance        | |
|  +------------------+ +------------------+ |
|  +------------------------------------+   |
|  | (sparkles) Open / mixed            |   |
|  | just start a timer, add types later|   |
|  +------------------------------------+   |
|                                            |
+--------------------------------------------+
|  (sw) 0:04   (♡) -- warming   [  Finish  ] |
+--------------------------------------------+

B · RETURNING USER  (history → Resume card on top, sticky scale/gym chips)
+--------------------------------------------+
|  v Minimize    Quick session     ||  ...   |
+--------------------------------------------+
|  Thu Jun 18 · 0:06 · live ●                |
|  What are you training?                    |
|  +------------------------------------+   |
|  | RESUME   figure.climbing       >   |   |
|  | Climbing · boulder · The Front     |   |
|  | last: Cave Roof V6 · 2 days ago    |   |
|  +------------------------------------+   |
|  +------------------+ +------------------+ |
|  | (figure.climb)   | | (dumbbell)       | |
|  |  Climbing        | |  Strength        | |
|  +------------------+ +------------------+ |
|  +------------------+ +------------------+ |
|  | (timer)  Timed   | | (run)    Run     | |
|  +------------------+ +------------------+ |
|  +------------------------------------+   |
|  | (sparkles) Open / mixed            |   |
|  +------------------------------------+   |
|  Recent  [ V-scale ]  [ The Front ]       |
+--------------------------------------------+
|  (sw) 0:06   (♡) 88 Z1 ●     [  Finish  ]  |
+--------------------------------------------+

C · TAP "Climbing" → medium-detent sheet (essentials only)
+--------------------------------------------+
| Cancel        Add a climb            (·)   |  <- grabber
|                                            |
| TYPE                                       |
| [ Boulder ] Top-rope  Lead  Sport         |  <- segmented, drives scale
|                                            |
| Name                                       |
| [ Cave Roof________________________ ]      |
|                                            |
| Grade · V / Font                           |
| recent  (V4) (V5) (V6)                     |  <- one-tap chips
| < V3  [ V4 ]  V5  V6  V7  V8  V9 >         |  <- scale-aware wheel
|                                            |
| v  Gym · scale · note          (pull up)   |  <- detent-2 disclosure
|                                            |
|  +--------------------------------------+  |
|  |           Add climb & log            |  |  <- Pulse Coral CTA
|  +--------------------------------------+  |
+--------------------------------------------+

D · POPULATED CANVAS  (3 climbs, Slab expanded; chooser is gone)
+--------------------------------------------+
|  v Minimize  Front St · boulder  ||  ...   |
+--------------------------------------------+
| SENDS 2  ·  hardest V6  ·  ▁▂▅ pyramid   > |  <- live hero strip, tap=expand
+--------------------------------------------+
| (climb) Cave Roof       [V6] SENT  ★NEW   |
|         3 tries · 4:12 on climb        v   |
|--------------------------------------------|
| (climb) Blue #3         [V4] FLASH         |
|         1 try · 0:38                    v   |
|--------------------------------------------|
| (climb) Slab Project    [V5] PROJECT  ...  |
|         5 tries · 6:40 · open           ^  |
|    1  attempt   1:12                        |
|    2  attempt   0:54                        |
|    3  rest …                                |
|    [  +1 attempt  ]        [  Send  v  ]   |  <- 2 footer taps, no sheet
|--------------------------------------------|
|                                            |
|        ( + )  Add  ·  fans up in thumb zone|  <- ExpandingAddBar
+--------------------------------------------+
|  (sw) 41:12   (♡) 142 Z3 ●   [  Finish  ]  |
+--------------------------------------------+
~~~

**Interactions**

- Tap Quick Start (home) → session auto-created and started (liveWorkout.start, Live Activity warms), TypeChooserView renders as the live-but-empty canvas. No wizard, no modal — the chooser IS the empty state.
- Tap a TypeCard → standard motion: Climbing/Timed slide up a medium-detent sheet (AddClimbSheet / AddTimedSheet); Strength pushes ExercisePickerView; Run and Open/mixed start a count-up duration entity IMMEDIATELY and dismiss the chooser (one tap to logging, no sheet).
- Tap ResumeContextCard → opens the same sheet pre-filled with last session's TYPE + gym + grade scale, so re-entering a familiar context is one tap to the form. (Only present in state B.)
- AddClimbSheet: tap a TYPE segment → swaps the Grade picker's scale (boulder→V/Font, TR/lead/sport→YDS/French) AND the downstream status set live; pull to large → reveals Gym/scale/note; tap a recent-grade chip → fills grade in one tap; Cancel returns to the chooser (nothing created), not the canvas.
- Tap 'Add climb & log' (Pulse Coral CTA) → creates the parent climb card carrying climbType + gradeScale + name + grade + gym, dismisses the sheet AND the chooser, scrolls the new card into view (ScrollViewReader). The chooser never returns while exercises exist.
- On the populated canvas, expand a climb card (tap header / chevron) → inline attempt list; tap '[ +1 attempt ]' → ONE gesture, haptic, appends an attemptTimestamp (no sheet); tap 'Send v' → flash/sent/project menu, couples to count (Flash → attempts=1 + closes; Sent on an open project → folds in accumulated attemptTimestamps).
- Swipe-left on a climb row = quick +1 attempt; swipe-right = Send (secondary idiom mirroring KAYA). Both have explicit accessible action equivalents in the row's rotor so they are not gesture-only (VoiceOver / Switch Control reach them).
- Timed attempt with a timer → full-cover FOCUS StopwatchView (count-up, Glass HUD) with the climb name/grade up top and a ≥64pt bottom-center Stop; Stop captures duration into startedAt/endedAt and auto-collapses to the canvas with the outcome picker. Untimed attempts skip FOCUS entirely.
- ExpandingAddBar (thumb zone) → tap fans out 'Add climb / Timed / Strength / Run' to add another entity mid-session without scrolling to a toolbar. The toolbar '+' remains as a secondary path.
- Inline edit: tap the grade chip or a counter to correct it in place; delete a row → instant with Undo. Only discarding the WHOLE session shows a confirmation dialog (reuses the existing freeform.discard confirmationDialog).
- Genuine, history-derived milestone at the LOGGING moment → CelebrationBurst on the climb row + success haptic, auto-dismiss, reduce-motion + mute gated. Computed against full history (KilterMilestones.isFirstSend already exists), so 'First V4 ever' reads bigger than a session best.
- Tap the HR chip in the command bar → LiveMetricsPanel (zones Z1-Z5, recovery ring, calories). Tap the LiveHeroStrip → expands to the same panel plus the full live pyramid.
- Edge: tap Finish from the chooser with zero entities → exits and discards silently (nothing to celebrate), reusing finishTapped()'s guard. No empty summary screen.
- Edge: long (2h+) session — the command-bar timer keeps wall-clock format and rolls to H:MM:SS at 1h so '1:41:12' never collides with the HR chip; the live hero strip stays a single line (sendsPerHour, not a growing list).

**Data captured**

- chosenActivity → Activity enum (climbing | running | dance | strength | other) — drives the session's sport/category and which SetKind the first entity uses (climbAttempt | duration | repsWeight). Run maps to .running, Open/mixed to .other, Timed to .other with a duration entity.
- climbType (boulder | topRope | lead | sport) → NET-NEW field; must be added to the freeform climb parent (does NOT exist on SetLog today). First field in AddClimbSheet; drives gradeScale + status set.
- gradeScale (vScale | font | yds | french) → NET-NEW sticky field, defaulted from RecentChipRail, persisted per climb type. YDS/French scales are net-new modeling the brief flagged as the biggest gap — Kilter is boulder-only/V-Font today.
- climbName → promoted from KilterLogEntry.climbName onto the freeform climb PARENT. Today freeform has only SessionExercise.displayName (a single string), not a per-entity named climb with grouped attempts — this is the structural change.
- gradeLabel + difficulty(float) → store the ordinal (difficulty) so pyramid/hardest-send math is exact; replaces today's free-text climbGradeLabel string with no difficulty.
- gym/location → session-level field (NET-NEW; no field exists on WorkoutSession today), inherited onto each climb, free-text + recents, no catalog gate.
- status → KilterAscentStatus (flash | sent | project | attempt; isSend = flash|sent) — already exists. For lead/sport, EXTENDED with onsight/redpoint as net-new cases (today's enum is boulder-shaped).
- attempts (Int) + attemptTimestamps[] → exist on KilterLogEntry but NOT on the freeform SetLog (only a flat climbAttempts Int). Each +1 appends a timestamp on the new parent.
- startedAt / endedAt per climb → exist on KilterLogEntry; net-new on the freeform parent (set from the FOCUS timer or first/last attempt). Today freeform only stamps SetLog.completedAt per row.
- note → KilterLogEntry.note (already additive/optional there); net-new on the freeform parent.
- timed-exercise selection → NET-NEW TimedExerciseCatalog (SwiftData) entry (name + default work/rest) or a freshly created one; logs duration SetLogs under the parent. No such catalog exists today (freeform timed is a bare 'Timed exercise' displayName).
- resumeContext → derived read-only from history (most recent session's Activity + gym + scale, with the staleness guard) — drives the prefill, not stored anew.

**Live stats**

- Session shell clock — 'Thu Jun 18 · 0:04 · live ●' on the chooser, proving the session auto-started (no wizard) and ticking off session.startedAt.
- Command-bar elapsed timer (0:04 → 41:12 → 1:41:12 past an hour) — wall-clock from session.startedAt via Text(timerInterval:), always on, rolls to H:MM:SS so a 2h+ session never overflows the bar.
- Live HR chip — bpm + zone capsule (Z3) + recovery dot, tinted by HeartRateZone color; reads '-- warming' on the chooser BEFORE the first sample (not blank, so the bar doesn't reflow), then fills as HealthKit/BLE comes online. No-HR sessions keep showing '--' indefinitely without breaking layout.
- LiveHeroStrip (populated, climbing) — Sends counter (2), hardest-send chip (V6), and a mini accruing grade pyramid, all from KilterSessionStats.compute wired live into the freeform session and recomputed on every log event. Activity-aware hero swaps to Volume (strength) / Hold time (timed) / Duration (run/open).
- Per-card rolled-up state — 'N tries · M:SS on climb' + status badge on each parent card, so the canvas reads as a scannable list of outcomes without expanding. Single-attempt climbs read '1 try' (not '1 tries'); a flashed climb shows the flash badge with no redundant try count.
- Expanded layer (on hero-strip / HR-chip tap) — sends/projects, sends-per-hour, full pyramid + time-in-zone bar in LiveMetricsPanel; capped, hidden by default. During a timed-attempt FOCUS cover these session stats hide entirely.

**Rationale.** CRITIQUE OF THE INPUT SCREEN (problems found):
1) FALSE 'reuse' premise / data-model mismatch — the biggest issue. The input asserts the climb card 'reuses the KilterLogEntry shape' and is '~1:1 reuse, not new modeling'. Ground truth (FreeformPlayerView.swift / WorkoutModels.swift) shows the freeform path has only a flat SetLog with climbGradeLabel(String)/climbStatusRaw/climbAttempts(Int) and a single SessionExercise.displayName — NO parent climb, NO climbType, NO gradeScale, NO attemptTimestamps[], NO per-climb startedAt/endedAt, and NO gym field on WorkoutSession. All the rich fields live ONLY on the board-only KilterLogEntry @Model. So the redesign needs real net-new modeling; I made that explicit in purpose + dataCaptured so the screen isn't built on a 'already exists' fiction.
2) Card-count inconsistency — input prose says 'five big tappable cards' and the rationale says the cards 'map to the Activity enum (climbing/running/dance/strength/other)', but dance has no card and the wireframe only ever shows the four + Open. I kept exactly FIVE (Climbing/Strength/Timed/Run/Open) and stated dance routes through Open/mixed, removing the contradiction.
3) Discoverability / consistency with the sibling screen — the real FreeformPlayerView keeps an always-present toolbar '+' (freeform.addExercise) AND the empty-state cards; the input's ExpandingAddBar silently 'replaces the buried toolbar Menu', which would break the existing freeform.addExercise UITest id. I kept the toolbar '+' as a secondary path so the new primary add doesn't regress tests.
4) Accessibility gaps — (a) cards specced at '~75x88pt' with the glyph as the visual; I made the WHOLE card the hit target at 164x96 and stated subtitles hide at AX sizes so titles don't clip under Dynamic Type. (b) Swipe-left=attempt / swipe-right=Send were gesture-only; I added rotor action equivalents so VoiceOver/Switch Control aren't locked out. (c) CelebrationBurst already reduce-motion gated (good) — kept.
5) Edge cases the input ignored — no-HR session (chip now shows '-- warming' / '--' without reflowing the bar instead of vanishing), 2-hour session (timer rolls to H:MM:SS), single attempt ('1 try' not '1 tries', flash shows no redundant count), first-ever climb (state A has no Resume card and neutral copy), Finish-from-empty (silent discard, no empty summary), and Cancel-from-sheet (returns to chooser, not the canvas, since nothing was created). The input's single wireframe showed none of these.
6) Stale-context risk — a Resume card that resurfaces a gym from months ago is noise; I added a staleness guard (~14 days / deleted gym suppresses it).

WHAT I KEPT (works well): the no-wizard auto-started session over which the chooser is the empty state; the entity-then-attempt spine; TYPE-first driving the scale; scale-aware discrete grade picker replacing the free-text field (today's real antipattern in LogSetSheet); one hero strip over an over-stuffed HUD; thumb-zone targets; instant-with-Undo over confirm-everything; teach-the-loop copy. These all map cleanly to the pattern library and the user's two explicit directions (climb-as-parent, catalog-or-create timed).

UPGRADED WIREFRAME: now shows FOUR realistic states (A first-ever empty / B returning with Resume + recent chips / C the Add-a-climb sheet / D the populated canvas with one card expanded), consistent 44-char inner width, real sample data (Cave Roof V6, Slab Project V5 open with per-attempt times, Blue #3 flash), the warming-HR state, and the H:MM:SS long-session timer — directly fixing the input's single-state, ambiguous wireframe.

**Reuses (existing Snappet):** `.snappetTile() — the five TypeCards (flat tappable tiles), matching the current emptyStateHero typeCard styling already in FreeformPlayerView (typeCard() helper).`, `.snappetCard() — the elevated ResumeContextCard and each NET-NEW parent climb/timed card with rolled-up header + inline expansion.`, `CommandBar (FreeformPlayerView.commandBar) — the persistent bottom bar (elapsed timer via Text(timerInterval:) · live-HR chip with zone capsule + recovery dot · Finish), kept verbatim under the chooser; only the empty-HR label changes to '-- warming' so the bar doesn't reflow.`, `StopwatchView(mode: .countUp / .countDown) — the FOCUS timed-attempt cover and timed-exercise sets; already the consumer in LogSetSheet's Timer mode and the climb timer, reused as the full-cover FOCUS screen.`, `LiveMetricsPanel(session:) — the peek-to-expand HR zones / recovery ring / calories layer opened from the HR chip (already wired to showingMetrics).`, `CelebrationBurst via .celebrates(on:) — inline milestone burst on a climb row at the logging moment, reduce-motion gated (already used on the done screen).`, `ExercisePickerView(resolver:) — reused verbatim for the Strength path's catalog (recents-first); already presented via pickingLift.`, `Haptics.success / Haptics.tap — per-log and per-tap feedback (already called in appendLog / togglePause).`, `ScrollViewReader auto-scroll-to-new-entity — the existing .onChange(of: session.exercises.count) scrollTo(lastID) in loggingContent, reused so a freshly added card scrolls into view.`, `FreeformSummary.stats / .milestones + KilterSessionStats.compute + KilterMilestones.isFirstSend — pure, device-free stat/milestone engines reused to drive the LiveHeroStrip and completion summary (Sends / hardest send / pyramid / first-send celebration).`, `SnappetColor.workout (ember-orange) + Pulse Coral CTA + HeartRateZone.color + the Glass HUD kit (#111928@72%, SF Rounded tabular digits) for the FOCUS timer.`, `RecoveryReadiness.evaluate + the recovery dot — already computed in the command bar and pushLiveActivity; reused unchanged.`, `The existing freeform.discard confirmationDialog — reserved (per Instant+Undo) for discarding the whole session, not per-row deletes.`

---

<a id="2"></a>
## 2. Climbing — Session Canvas (climb list)

*Type: climbing*

**Purpose.** The climb-first home of a freeform climbing session: a vertical, scannable list of CLIMBS/ROUTES added this session. Each climb is a .snappetCard() that rolls up its IDENTITY (type icon + name + color-banded scale-aware grade chip) and its OUTCOME (status badge, attempts count, best outcome, time-on-climb). Attempts always live UNDERNEATH a climb, never as flat sibling rows — directly fixing the current pain point ("you cannot group 3 tries on the same V4 project"; today every attempt is a flat LogSetSheet row with a free-text "Grade (e.g. V4, 6c)" field, popped-and-dismissed once per bid). A teach-the-loop empty state invites "Add your first climb"; a bottom-thumb-zone "+ Add climb" CTA grows the session; one peek strip of live, accruing stats (Sends hero + hardest-send chip + tiny grade pyramid with a text equivalent) sits just above the command bar. Tapping a climb expands it inline to its attempt list and a one-gesture +1 attempt / Send footer; toggling "Time next go" routes the next attempt into the FOCUS live-timer cover; every other action stays on this canvas. TYPE is chosen first at creation and drives the grade SCALE (boulder→V/Font, TR/lead/sport→YDS/French) and the status taxonomy, so the canvas honestly renders mixed-type sessions (a V5 boulder and a 5.10a top-rope side by side).

~~~text
EMPTY STATE — session auto-started, nothing logged yet
+------------------------------------------------+
| 9:41                                  ···  100% |
+------------------------------------------------+
|  v  Boulder Sesh                      Climbing  |  title (inline-edit) · type
|     Gym  [ + Add gym ]                          |  free text · no recent forced
+------------------------------------------------+
|                                                |
|               .------------------.             |
|               | (figure.climbing)|             |
|               '------------------'             |
|                                                |
|              Add your first climb              |
|     Name a route, pick its grade, then log     |
|        every go underneath it.                 |
|                                                |
+------------------------------------------------+
|       +--------------------------------+       |
|       |       +  Add a climb           |       |  Pulse Coral · thumb zone
|       +--------------------------------+       |
+------------------------------------------------+
|  (T) 0:00          — no HR —        [ Finish ]  |  HR chip hidden until data
+------------------------------------------------+


POPULATED STATE — 4 climbs, mixed type, one expanded
+------------------------------------------------+
| 9:41                                  ···  100% |
+------------------------------------------------+
|  v  Boulder Sesh           Movement RiNo        |  gym now inline, inherited
+------------------------------------------------+
|  LIVE   3 sends   ·   hardest V5   ·   [pyramid]|  ONE peek strip (tap=expand)
|  V3 #   V4 #   V5 #          (sends by grade)   |  text equiv beside mini-bars
+------------------------------------------------+
| .--------------------------------------------. |
| | (B) Cave Roof          [V5]        ✓ Sent  | |  Kilter-amber grade band
| | boulder · 4 attempts · 6:18 on climb     v | |  rolled-up child summary
| '--------------------------------------------' |
| .--------------------------------------------. |
| | (B) Blue #3            [V3]        ⚡ Flash | |  Flash ⇒ attempts pinned to 1
| | boulder · 1 attempt · 0:42               v | |
| '--------------------------------------------' |
| .--------------------------------------------. |
| | (R) Yellow Arete       [5.10a]     ✓ Sent  | |  top-rope · YDS scale shown
| | top-rope · 2 attempts · 3:30             v | |
| '--------------------------------------------' |
| .------------------ EXPANDED ----------------. |
| | (B) Slab Project       [V4]    ◷ Project   | |  ember "open" badge
| | boulder · 3 attempts · 4:05 · open         | |
| |  -------------------------------------     | |
| |   1   0:42   attempt                       | |  per-attempt children
| |   2   1:10   attempt                       | |  (tap row to edit)
| |   3   2:13   attempt              + note    | |
| |  -------------------------------------     | |
| |  ( ) Time next go            rest 3:00 v   | |  off=untimed (1 tap)
| |  +--------------------+ +-----------------+ | |
| |  |    + 1 attempt     | |    Send  v      | | |  two footer taps, no sheet
| |  +--------------------+ +-----------------+ | |
| '--------------------------------------------' |
+------------------------------------------------+
|       +--------------------------------+       |
|       |       +  Add climb             |       |  thumb zone · grows session
|       +--------------------------------+       |
+------------------------------------------------+
|  (T) 41:12   (H) 142 Z3 ●   rest 1:48 ▾  Finish|  elapsed · HR(zone+rec) · rest
+------------------------------------------------+
● green recovery dot · Z3 tinted ember · rest = live count-DOWN, shows only when armed
~~~

**Interactions**

- Empty state: tap '+ Add a climb' → medium-detent 'Add a climb' sheet; TYPE segmented control is the FIRST field and drives the grade scale + status set. Commit (Pulse Coral CTA) → sheet dismisses → new climb card appears → List auto-scrolls to it.
- Tap '+ Add gym' or a recent chip → free-text gym field; value sticks at SESSION level and prefills every subsequent climb's sheet (never re-entered per attempt). With no gym set the row simply shows '+ Add gym' — nothing is silently pre-applied.
- Tap a collapsed climb card (or its caret) → expands inline (caret rotates, layout pushes down) to its attempt children + footer; tap again to collapse. No push/navigation, no sheet.
- Tap '+ 1 attempt' in the expanded footer → INSTANT: appends an attemptTimestamp, bumps the count, success haptic, no sheet. (If 'Time next go' is ON, this instead opens the FOCUS timer — see below.)
- Tap 'Send ▾' → menu (Flash / Sent / Project / Attempt; +Onsight / Redpoint / Pinkpoint + 'top-rope' flag when climbType is lead/sport). Flash/Onsight sets attempts=1 and CLOSES the climb (prevents 'Flash with 5 attempts'); Sent on an open project folds in accumulated attemptTimestamps[]; Project/Attempt keeps it open and increments.
- Toggle 'Time next go' ON → the NEXT +1 attempt opens the FOCUS full-cover live timer (count-UP StopwatchView + Glass HUD #111928@72%, climb name + grade chip + attempt # up top, ≥64pt circular Stop bottom-center, live-HR chip kept visible). On Stop → captures duration into startedAt/endedAt + attemptTimestamps[] → outcome picker → auto-collapse back to this canvas. Untimed attempts skip FOCUS entirely (single tap).
- Card swipe-RIGHT = quick Send; card swipe-LEFT = quick +1 attempt (KAYA idiom) — disambiguated from child-row swipe so gestures never collide; both secondary to footer buttons, with VoiceOver custom-action equivalents.
- Trailing swipe on an attempt CHILD row → Delete with an Undo toast (instant action, no confirm dialog; child rows never carry +1/Send swipe so left-swipe stays unambiguous per nesting level).
- Tap the grade chip on a card → inline scale-aware grade picker for that climb's scale — single-value edit stays inline, no sheet.
- Tap the live peek strip → expands the LiveMetricsPanel (full pyramid, sends/hr, median time-on-climb, HR zones, recovery ring).
- Genuine milestone at the LOGGING moment (first-ever V5 vs full history, flash, new hardest send) → CelebrationBurst fires inline on that climb row + success haptic, auto-dismiss, reduce-motion + mute gated. Fires ONLY on history-derived bests.
- On attempt completion (untimed or on Stop), the remembered rest preset OPTIONALLY auto-starts a count-DOWN shown as a 'rest 1:48 ▾' chip in the command bar (terminal haptic at zero); tapping cancels/resets. Only place count-DOWN appears — all attempt timing is count-UP.
- Tap '+ Add climb' (thumb zone) → same Add-a-climb sheet, prefilled with last TYPE/gym/prevailing SCALE so another route is fast (prefill lives on the sheet, not as a per-card footnote).
- Finish (command bar) → completion summary (Duration / Climbs / Sends headline + full grade pyramid + milestone cards). An empty session (zero climbs) just exits/discards with no save.

**Data captured**

- climb.climbUUID — UUID minted on climb creation (KilterLogEntry.climbUUID; freeform climbs get a generated id, not a catalog one)
- climb.climbName — from the Add-a-climb sheet NAME field, normalized via SetMeasure.climbName trim/fallback (KilterLogEntry.climbName)
- climb.climbType — boulder | top-rope | lead | sport (NET-NEW field; segmented control chosen FIRST; drives gradeScale + status set + type icon)
- climb.gradeScale — V/Font for boulder (reuse '6a/V3' labels) · YDS/French for TR/lead/sport (NET-NEW; sticky per type, picked once)
- climb.gradeLabel + climb.difficulty — discrete scale-aware picker; store the ordinal/float so pyramid + hardest-send math stays exact (KilterLogEntry.gradeLabel + difficulty)
- climb.status — KilterAscentStatus rawValue (flash|sent|project|attempt; +onsight/redpoint/pinkpoint NET-NEW for lead/sport) — the rolled-up best-outcome badge
- climb.attempts — Int shown as 'N attempts' (KilterLogEntry.attempts)
- climb.attemptTimestamps[] — one Date per +1 attempt tap, for cadence (KilterLogEntry.attemptTimestamps)
- climb.startedAt / climb.endedAt — per-climb timing; time-on-climb = endedAt − startedAt (KilterLogEntry.startedAt/endedAt → timeOnClimb)
- climb.note — optional per-ascent free text (beta/conditions) (KilterLogEntry.note)
- attempt.durationSec — captured on FOCUS-timer Stop (reuses SetLog.durationSec the current code already repurposes for climb time)
- session.gym — free-text + recents, captured once at session level, inherited; resting state is empty (NET-NEW session-level field)
- session.restPresetSec — remembered per-climb/per-type rest duration powering the command-bar count-down (NET-NEW)

**Live stats**

- Sends — hero count, recomputes on every log (KilterSessionStats.sends)
- Hardest-send chip — e.g. 'hardest V5'; HIDDEN until the first send lands so an all-projects session shows no empty chip (hardestSendGrade / hardestSendDifficulty)
- Accruing grade-pyramid mini-bars + 'V3 # / V4 # / V5 #' text equivalent — sends stacked by grade, grows live, readable without color (pyramid[])
- Total attempts / projects open — secondary counts in the expand panel (totalAttempts, projects, attemptsOnly)
- Sends per hour — pace stat in the expand panel (sendsPerHour)
- Time-on-climb per card + median time-on-climb in panel (timeOnClimb, medianTimeOnClimb)
- Live HR + zone (ember-tinted dot) + recovery dot in the command bar; whole HR chip hidden until first sample (HeartRateZone.forBpm + RecoveryReadiness)
- Optional rest count-DOWN chip in the command bar after an attempt, shown only while armed (StopwatchView count-down, wall-clock backed, terminal haptic)

**Rationale.** CRITIQUE OF THE PRIOR DRAFT (verified against the actual code I read — FreeformPlayerView.swift LogSetSheet .climbAttempt case at line 867 with its free-text "Grade (e.g. V4, 6c)" field + Outcome picker + "Time the attempt" toggle, KilterModels.swift KilterLogEntry/KilterAscentStatus, KilterSessionStats fields, the safeAreaInset command bar), and the fixes I folded in: (1) PREFILL PLACEMENT BUG — the draft put "last: V5 · sent · 4 tries" as a footnote on every card including a CLOSED send, which is nonsensical (a sent boulder is done; you don't re-log it). Prefill belongs on the Add-climb sheet (last type/gym/scale) and on a re-opened project, so I removed the per-card footnote and moved prefill to the sheet. (2) GESTURE COLLISION — the draft used swipe-LEFT for both "card +1 attempt" AND "delete attempt child", an ambiguous double-meaning of the same gesture; I split it: card swipe-RIGHT=Send / swipe-LEFT=+1, child rows carry only a trailing Delete, and added VoiceOver custom actions since swipe is not accessible. (3) HIDDEN CLAIMED STAT — the draft listed a rest count-down as a live stat but never showed it; I surfaced it as a 'rest 1:48 ▾' chip in the command bar and made it the SOLE count-DOWN surface (all attempt timing is count-UP), closing the count-up-vs-count-down ambiguity. (4) MIXED-TYPE EDGE CASE — the draft asserted onsight/redpoint and type-drives-scale but only ever drew boulder cards; I added a top-rope card with a YDS [5.10a] grade so the canvas visibly proves TYPE drives the scale, exercising the lead/sport status edge. (5) EMPTY-GYM / NO-HR EDGE CASES — the draft's empty state pre-filled a recent gym ("Movement RiNo recent") and implied data before any log; I made the resting state an unfilled '+ Add gym' and '— no HR —', so first-ever-climb and no-band sessions render honestly. (6) HARDEST-SEND CHIP — now explicitly hidden until a send lands, so an all-projects session (single attempt, zero sends) doesn't show an empty chip. (7) PYRAMID ACCESSIBILITY — added a 'V3 # / V4 # / V5 #' text equivalent beside the color mini-bars for color-blind/VoiceOver/Dynamic-Type users. WHAT I KEPT (it works and is ~1:1 reuse): the entity-then-attempt spine promoting the EXISTING, unit-tested KilterLogEntry shape out of the Kilter-only path into the freeform climb parent (the single highest-leverage move; three tries on a project become three children of one card); auto-started lazy session (no setup wizard); the costly TYPE-first form once at creation then one-gesture +1/Send; constrained scale-aware grade picker storing the float so KilterSessionStats.pyramid/hardestSend stays exact; outcome-couples-to-count guarding against 'Flash with 5 attempts'; one Sends hero + thin strip + peek-to-expand (Zwift four-field cap); three-state PEEK→FOCUS→auto-COLLAPSE HUD with the ≥64pt bottom Stop; card-based progressive disclosure; bottom-thumb-zone CTA/footer/Finish; instant-action+Undo; inline grade edit; teach-the-loop empty state; gym-once-inherited; milestone-at-logging-moment via CelebrationBurst — all on-brand Snappet Pulse (Kilter amber boulder band, ember warm HR zone, Pulse Coral CTA) and reusing FreeformPlayerView's container, command bar, ScrollViewReader, and Live-Activity plumbing.

**Reuses (existing Snappet):** `KilterLogEntry @Model — the rich climb shape (climbUUID, climbName, gradeLabel, difficulty, status, attempts, attemptTimestamps[], startedAt/endedAt, note, timeOnClimb) promoted from the Kilter-only path into the freeform climb parent`, `KilterSessionStats.compute — pure, device-free; wired live to the freeform session for the Sends hero, hardest-send chip, accruing pyramid, sends/hr, median time-on-climb`, `KilterAscentStatus (flash/sent/project/attempt + isSend) — drives the Send menu and status badge; extended with onsight/redpoint/pinkpoint for non-boulder types`, `StopwatchView (count-up, wall-clock backed, success haptic) — the FOCUS timed-attempt cover, plus its count-DOWN mode for the command-bar rest chip; already the consumer the current 'Time the attempt' toggle drives`, `FreeformPlayerView command bar (safeAreaInset(.bottom): elapsed timer · live-HR zone chip + recovery dot · Finish) and its ScrollViewReader auto-scroll-to-new-item, inline-editable title, and persist/Live-Activity plumbing`, `.snappetCard() (elevated climb cards) and .snappetTile() (peek strip, recents chips)`, `Glass HUD kit (#111928@72%, white@14% hairline, SF Rounded tabular digits) for the FOCUS timer overlay`, `CelebrationBurst (.celebrates(on:)) — inline milestone burst on the climb row, reduce-motion + mute gated`, `HeartRateZone.forBpm + RecoveryReadiness — HR chip zone color + recovery dot in the command bar`, `LiveMetricsPanel — the peek-strip tap-to-expand detail (full pyramid, HR zones, recovery ring)`, `SetMeasure.climbName trim/fallback + Haptics.success/tap — name normalization and feedback`, `FreeformSummary (Duration / Sets→Climbs / Sends headline + milestones) for the completion screen`, `SetLog.durationSec — already repurposed for climb time; receives the FOCUS-timer measured duration with zero re-entry`

---

<a id="3"></a>
## 3. Climbing — "Add a climb" bottom sheet (freeform Quick Session / FreeformPlayerView)

*Type: climbing*

**Purpose.** Create a named, TYPED, GRADED climb PARENT inside the already-running freeform session so every later effort logs UNDERNEATH it instead of as a flat SetLog row (the documented pain point: no named climb, no type, no grade-scale awareness, cannot group 3 tries on one V4). Replaces TWO current antipatterns at once: (1) tapping "Climbing" in the Add-exercise confirmationDialog instantly dropping a generic "Climbing" SessionExercise row with no creation step, and (2) the flat per-attempt LogSetSheet whose freetext TextField("Grade (e.g. V4, 6c)") + single Outcome Picker + .medium-only detent carry the only climb identity. The sheet captures identity ONCE — TYPE first (boulder/top-rope/lead/sport, because it drives the grade scale and the status taxonomy), a scale-aware DISCRETE grade picker (never freetext, stores an ordinal Double so the pyramid + hardest-send math are exact), optional smart-suggested NAME, optional session-inherited GYM — then exits straight into the first attempt. Mostly-optional with last-time defaults: the warm path (a returning boulderer whose TYPE/scale/gym are prefilled) collapses to ~2 taps (tap a recent-grade chip, tap the CTA); the cold path (first-ever climb, no recents) is a short TEACHING form, never a blank void. This is the single highest-leverage fix and is ~1:1 reuse of the KilterLogEntry shape promoted out of the Kilter-only path into the freeform SetKind.climbAttempt parent.

~~~text
STATE A — FIRST-EVER CLIMB (cold / teaching · .medium)
+----------------------------------------------+
|            ====  grabber  ====               |
|  Add a climb                            (X)  |
|  Attempts log underneath this climb          |
|                                              |
|  TYPE                                        |
|  +--------+ +--------+ +------+ +-------+     |
|  |Boulder●| |Top-rope| | Lead | | Sport |    |
|  +--------+ +--------+ +------+ +-------+     |
|                                              |
|  GRADE                          V · Font  ⇄  |
|  Recent: none yet — pick a grade below       |
|  +----------------------------------------+  |
|  | V0  V1  V2  V3 [V4] V5  V6  V7  V8  …   |  |
|  |             ▔▔▔▔  filled chip + bold    |  |
|  +----------------------------------------+  |
|        ‹ scrolls · selected stays in view ›  |
|                                              |
|  NAME (optional)                             |
|  +----------------------------------------+  |
|  | e.g. Blue #3                       🎙  |  |
|  +----------------------------------------+  |
|                                              |
|  ⌄ More: gym · note                          |
|                                              |
|  +----------------------------------------+  |
|  |     Add & log first attempt            |  | ← Coral CTA
|  +----------------------------------------+  |
|  +----------------------------------------+  |
|  |          Add climb only                |  | ← outline btn
|  +----------------------------------------+  |
+----------------------------------------------+

STATE B — WARM / FAST (returning boulderer · prefilled)
+----------------------------------------------+
|            ====  grabber  ====               |
|  Add a climb                            (X)  |
|  Bridge Climbing Co.                         | ← gym inherited
|                                              |
|  TYPE                                        |
|  +--------+ +--------+ +------+ +-------+     |
|  |Boulder●| |Top-rope| | Lead | | Sport |    |
|  +--------+ +--------+ +------+ +-------+     |
|                                              |
|  GRADE                          V · Font  ⇄  |
|  Recent:  [V4]  [V5]  [V3]  [V6]             | ← 1-tap reuse
|  +----------------------------------------+  |
|  | V2  V3 [V4] V5  V6  V7  V8  V9  …       |  |
|  +----------------------------------------+  |
|                                              |
|  NAME (optional)                             |
|  +----------------------------------------+  |
|  | Blue #3                            🎙  |  | ← auto-suggest
|  +----------------------------------------+  |
|  Suggest: [Blue #3] [Cave Roof] [Slab]       |
|                                              |
|  ⌄ More: gym · note                          |
|                                              |
|  +----------------------------------------+  |
|  |     Add & log first attempt            |  |
|  +----------------------------------------+  |
|  +----------------------------------------+  |
|  |          Add climb only                |  |
|  +----------------------------------------+  |
|  last here: V4 · sent · 3 tries              | ← faint hint
+----------------------------------------------+

STATE C — ROUTE (Lead) · .large detent, options open
(NEW surface: YDS/French rungs + onsight/redpoint
 are net-new modeling — see dataCaptured notes)
+----------------------------------------------+
|            ====  grabber  ====               |
|  Add a climb                            (X)  |
|                                              |
|  TYPE                                        |
|  +--------+ +--------+ +------+ +-------+     |
|  |Boulder | |Top-rope| |Lead●| | Sport |    |
|  +--------+ +--------+ +------+ +-------+     |
|                                              |
|  GRADE                       YDS · French ⇄  | ← scale auto-
|  Recent:  [5.11a] [5.10d] [5.11c]            |   switched by TYPE
|  +----------------------------------------+  |
|  | 5.10b 5.10c 5.10d [5.11a] 5.11b 5.11c   | |
|  +----------------------------------------+  |
|                                              |
|  NAME (optional)                             |
|  +----------------------------------------+  |
|  | Yellow overhang                         | |
|  +----------------------------------------+  |
|                                              |
|  GYM / LOCATION                              |
|  +----------------------------------------+  |
|  | Bridge Climbing Co.                  ⌄ | |
|  +----------------------------------------+  |
|  Recent: [Bridge] [Movement RiNo] [Home]     |
|  (empty 1st session → "Add a gym" placeholder)|
|                                              |
|  NOTE (optional)                             |
|  +----------------------------------------+  |
|  | Pumpy crux at the 2nd clip…             | |
|  +----------------------------------------+  |
|                                              |
|  +----------------------------------------+  |
|  |     Add & log first attempt            |  |
|  +----------------------------------------+  |
|  +----------------------------------------+  |
|  |          Add climb only                |  |
|  +----------------------------------------+  |
+----------------------------------------------+

CONTEXT — session canvas the CTA returns to (reference)
+----------------------------------------------+
|  ‹ Climbing            Quick session    •••  |
+----------------------------------------------+
|  Sends 2 · hardest V5 · 12 attempts          | ← live hero
|                                              |
|  ◣ Cave Roof              [V5]  ★Sent         |
|     boulder · 3 attempts · 4:18 on climb     | ← parent card
|  ◣ Blue #3                [V4]  ◌Project      |
|     boulder · 2 attempts · 2:— on climb      |
|                                              |
|        ⊕ Add climb        ⊕ Add timed        |
+----------------------------------------------+
|  ⏱ 41:12   ♥ 142 Z3 •      [   Finish   ]    | ← command bar
+----------------------------------------------+
(no-HR session: ♥ chip hides, elapsed + Finish remain)
~~~

**Interactions**

- Open from canvas '⊕ Add climb' or the empty-state 'Add your first climb' → sheet slides up at .medium. TYPE prefills to the session's last-used type; grade scale + Recent chips + gym prefill from session/history; NAME shows a ghosted smart suggestion. ZERO fields are mandatory — the Coral CTA is enabled on open even with nothing touched (it falls back to type-default grade + name='Climbing').
- Tap a TYPE segment → switches the grade SCALE strip (boulder → V/Font; top-rope/lead/sport → YDS/French) AND the downstream status set; the strip re-snaps to the nearest valid rung in the new scale; light haptic. NOTE: route scales + route statuses are net-new; until route rungs ship, route TYPEs fall back to the boulder status taxonomy and a generic numeric rung so logging is never blocked.
- Tap a rung on the scale strip → it fills (coral chip + bold weight, NOT a hue-only underline, so it reads under color-blind / Reduce-Transparency) and selects that grade; the selected rung is kept scrolled into view. Horizontal drag scrolls with momentum and snaps to rungs.
- Tap a Recent-grade chip → one-tap selects that grade and scrolls the strip to it. First-ever climb: the rail reads 'none yet — pick a grade below' instead of an empty row.
- Tap the scale toggle (V·Font / YDS·French ⇄) → flips the label convention; choice is remembered sticky per TYPE. Placed inline-right of the GRADE header, sized ≥44pt; secondary to TYPE (which already implies the family).
- Tap a NAME suggestion chip ('Blue #3' auto-incremented from recents, or 'Cave Roof'/'Slab') → fills the field; or type freely; 🎙 mic = voice dictation (fast-follow, hidden if speech unavailable).
- Pull the sheet to .large (or tap '⌄ More: gym · note') → reveals GYM + NOTE. Tap a recent-gym chip to fill; first session with no recents shows an 'Add a gym' placeholder, never a dead empty rail.
- Tap 'Add & log first attempt' (Coral CTA) → creates the parent climb card (stable climbUUID), dismisses the sheet, and immediately seeds attempt #1 on that card: status defaults per TYPE (boulder→.attempt, kept OPEN so it's a project-in-progress; a later Send folds in accumulated timestamps), attempts=1, startedAt stamped, attemptTimestamps appended. Untimed = the attempt is already +1 with no further screen; timed-attempt FOCUS is chosen later on the card, not here.
- Tap 'Add climb only' (outline button, equal visual weight band but secondary fill) → creates the parent card collapsed on the canvas with NO attempt logged yet — the explicit 'I'll come back to this project' path, now a real button not a buried text link.
- Tap (X) or swipe the sheet down → dismiss with nothing created. No confirm dialog — nothing destructive happened (instant-action + reversible).
- After return the new card is the top card. A mis-set grade/name/type is fixed INLINE on the card (tap the grade chip, long-press the title) — the sheet is never reopened for a single-value edit.
- Re-adding a climb you've logged before: its last grade + a sensible default outcome prefill, so 'another go' collapses toward a single confirm tap (the faint 'last here: V4 · sent · 3 tries' hint states what will be reused).

**Data captured**

- climbType (boulder|topRope|lead|sport) — NEW enum on the freeform climb parent (SessionExercise). Chosen via the TYPE segmented control; drives gradeScale + the status set. This is the headline modeling gap: it does not exist on SetLog/SessionExercise today.
- gradeScale (vFont|yds|french) — NEW; derived from climbType + the sticky scale toggle, persisted per type. YDS/French rungs are net-new (KilterCatalog.gradeScale() is V/Font only today) — this sheet is where route grading is introduced; boulder stays the proven V/Font path.
- gradeLabel: String — e.g. 'V4' / '6a/V3' (reuses the Kilter combined-label convention) / '5.11a'. Persists to SetLog.climbGradeLabel on the seeded first attempt; the parent climb's display grade is snapshotted on the SessionExercise.
- difficulty: Double — NEW on the freeform path: the ordinal/float for the selected rung, stored so the grade pyramid + hardestSend math (KilterSessionStats) are EXACT. Mirrors KilterLogEntry.difficulty; SetLog has no difficulty field today, so this is an additive optional.
- climbUUID: String — NEW on SessionExercise: a stable id grouping every attempt under this parent and enabling cross-session dedup/prefill. Today the freeform climb parent's only identity is displayName (no UUID) — this is the field that makes 'group 3 tries on one V4' possible.
- climbName: String? (optional) — smart-suggested ('Blue #3' auto-increment / recents) → SessionExercise.displayName (already exists; SetMeasure.climbName trims/falls back to 'Climbing').
- gym/location: String? (optional, session-level, inherited) — NEW; remembered across sessions via a tiny recents store. Captured once, defaulted onto later climbs.
- note: String? (optional, .large detent) → maps to the KilterLogEntry.note convention promoted onto the freeform parent.
- On 'Add & log first attempt' the parent's FIRST child attempt is seeded into the existing freeform persistence: SetLog{climbStatusRaw=KilterAscentStatus default for the type, climbAttempts=1, climbGradeLabel} under a SessionExercise{kindRaw='climbAttempt'}; startedAt + attemptTimestamps[0] stamped. CRITICAL constraint: SetLog/SessionExercise are Codable composites inside @Model WorkoutSession (NOT @Model rows), so SwiftData lightweight migration cannot reach inside the blob — EVERY new field (climbType, gradeScale, difficulty, climbUUID, attemptTimestamps, startedAt/endedAt) MUST be Optional/defaulted or decoding old sessions throws.
- status taxonomy: boulder = flash/sent/project/attempt (existing KilterAscentStatus). Route statuses (onsight/redpoint/pinkpoint, top-rope flag) are NET-NEW — KilterAscentStatus has no onsight/redpoint case today — so route TYPEs degrade to the boulder taxonomy until those cases ship; isSend (flash|sent, plus onsight|redpoint when added) is preserved for the pyramid.

**Live stats**

- NO live stats render INSIDE the add-sheet (it is a creation form — anti-clutter discipline; FOCUS stays on TYPE/GRADE/NAME/GYM).
- The canvas BEHIND the sheet shows the always-on hero strip the new card feeds: 'Sends N · hardest <grade> · M attempts' (KilterSessionStats total/hardestSendGrade), recomputed live the instant the first attempt is seeded from the CTA. First climb of the day: the strip reads 'No sends yet · log your first attempt' rather than zeros.
- Recent-grades chips are derived LIVE from the session's already-logged grades for the current TYPE, so the rail reflects what you've climbed today; empty on the first climb ('none yet — pick a grade below').
- Once back on the canvas the new parent .snappetCard() shows its own rolled-up running stats: status badge, 'N attempts', and total time-on-climb (endedAt − startedAt) — '2:—' while a project is still open.

**Rationale.** TYPE is the first control as a segmented picker because 'TYPE drives the grade SCALE and the status set' is the single biggest modeling gap (Kilter V/Font toggle, TopLogger toprope/lead flag, Vertical-Life ascent-style-first). The user's desired direction #1 — enter Climbing → ADD A CLIMB first (TYPE, NAME, GRADE, optional GYM), then log attempts UNDER it — maps 1:1 onto this sheet creating a PARENT before any attempt exists: the entity-then-attempt spine that fixes 'cannot group 3 tries on one V4'. GRADE is a constrained scale-aware discrete strip + recent chips, never the current freetext TextField('Grade (e.g. V4, 6c)') at FreeformPlayerView line 868, per 'grade entry is never freetext'; it stores a Double ordinal so KilterSessionStats pyramid + hardestSend are exact. NAME/GYM are optional with smart suggestions + recents per 'mostly-optional, sensible defaults, fast' and 'location captured once, inherited' (KAYA free-text + recents, not a catalog gate). The two-detent friction-light sheet keeps the costly form to ONCE-at-creation so later attempts are one gesture. Last-time prefill (type, grade, gym, default outcome) plus the provenance hint drives 'default action is CONFIRM not type', collapsing the warm path to ~2 taps — but the wireframe now shows the COLD first-climb state as a teaching form (empty recents rail with a prompt, not a void) so the ~2-tap claim isn't oversold. The refinements that matter: (1) 'Add climb only' is promoted from a buried text link to a real outline button because logging a project to return to is the second-most-common action; (2) the selected rung uses a filled chip + bold weight, not a coral underline alone, for color-blind / Reduce-Transparency users; (3) the data-capture is corrected to the REAL persistence — SetLog/SessionExercise are Codable composites, so climbType/gradeScale/difficulty/climbUUID/attemptTimestamps/startedAt/endedAt are all NET-NEW and MUST be optional or old sessions throw on decode; (4) route grading (YDS/French rungs) and route statuses (onsight/redpoint) are flagged as net-new modeling that degrades to the proven boulder path until they ship, instead of being claimed as existing reuse; (5) edge cases are shown — first-ever climb, empty gym recents, project-vs-flash seeding, and a no-HR command bar — so the sheet is robust rather than only demonstrated in its happy path. Dismiss creates nothing, so no confirm dialog is needed (instant-action + reversible). The whole thing is ~1:1 reuse of the KilterLogEntry shape promoted out of the Kilter-only path into SetKind.climbAttempt, exactly as the pattern library recommends.

**Reuses (existing Snappet):** `KilterLogEntry shape (climbUUID, climbName, gradeLabel, difficulty, statusRaw, attempts, attemptTimestamps[], startedAt/endedAt, note) — promoted from the Kilter-only @Model into the freeform SetKind.climbAttempt parent (as optionals on the SetLog/SessionExercise Codable composites, since those are blobs inside @Model WorkoutSession, not rows)`, `KilterAscentStatus (flash|sent|project|attempt, isSend) at KilterModels.swift:222 — the boulder status taxonomy reused directly; onsight/redpoint for routes are NET-NEW cases to add here`, `SetKind.climbAttempt (WorkoutModels.swift:180) + SetLog{climbGradeLabel, climbStatusRaw, climbAttempts} + SessionExercise{kindRaw} — the existing freeform climb-attempt persistence the seeded first attempt commits through`, `KilterCatalog.gradeScale() / the '6a/V3' combined-label convention for the V/Font toggle — extended with NET-NEW YDS/French rung tables for route types`, `KilterSessionStats.compute (totalClimbs/sends/projects/hardestSendGrade/pyramid[]) wired live into the canvas hero strip behind the sheet`, `SnappetCard.swift .snappetCard()/.snappetTile() for the parent climb card + grade/recents chips`, `SnappetColor tokens — Pulse Coral #FF5A4D CTA, Kilter amber/sandstone climb accent (SnappetColor.swift:58), surfaceMuted chip rails, hairline dividers`, `Snappet Pulse 4pt grid + radius sm10/md16/lg24 so every row clears 44pt`, `Docked command bar (elapsed | HR/zone/recovery chip | Finish) on the canvas behind`, `presentationDetents([.medium, .large]) sheet idiom already used by LogSetSheet (corrected from .medium-only)`, `SetMeasure.climbName(...) name trim/'Climbing' fallback + the freeform.climbName leaf-TextField pattern`, `Voice/mic affordance (fast-follow) consistent with the command-bar capture goals; CelebrationBurst reserved for the LOGGING moment on the canvas, not this sheet`

---

<a id="4"></a>
## 4. Climbing — Climb detail with attempts (expanded climb card inside the running Quick Session / FreeformPlayerView)

*Type: climbing*

**Purpose.** Make a single climb the unit of work: one named, typed, graded PARENT whose efforts are logged underneath it in a single gesture. This is the expanded state of a climb's .snappetCard() on the running session canvas — header (type chip, color-AND-glyph-banded grade, name, gym), an attempts timeline (outcome + duration + timestamp, newest-first), per-climb mini-stats (tries / best / time-on-this-climb), and TWO unmistakable bottom-thumb-zone ways to log the next effort: "Log attempt" (quick, untimed, pick an outcome inline) and "Timed attempt" (full-cover count-UP live timer). The expensive form (type/name/grade/gym) happened ONCE at creation, so from here every effort collapses to a single confirm tap — one-tap Repeat-last and inline outcome edit kill the re-opened-sheet antipattern. Repeat-last is suppressed once a send closes the climb; logging another go then becomes an explicit reopen so we never silently append to a finished climb.

~~~text
LEGEND  ┃V5┃ grade pill (colour band + scale)   ⚡flash ✓sent ◐project ○attempt
        duration "—" = untimed effort    •recovery dot    Zn = colour-coded HR zone

────────────────────────────────────────────────────────────────
STATE A · POPULATED — boulder, OPEN project, 2 tries, HR live
┌──────────────────────────────────────────────┐
│ 9:41                                  •••  87%│
├──────────────────────────────────────────────┤
│ ‹ Session            44:08               ⋯    │ ← elapsed only; HR lives once, in the bar below
├──────────────────────────────────────────────┤
│ ╭──────────────────────────────────────────╮ │ ← .snappetCard (expanded)
│ │ △ Boulder    ┃ V5 ┃ amber         ⌃ hide  │ │   type chip + grade pill · hide=collapse
│ │ Cave Roof                                 │ │   name on its own line (Dynamic-Type safe)
│ │ 📍 The Spot · SF                          │ │
│ │ ───────────────────────────────────────── │ │
│ │  TRIES        BEST          ON THIS CLIMB │ │ ← labels above values, reflow at large type
│ │   2          0:38 ◐             4:12       │ │   BEST = fastest timed effort (tabular)
│ ╰──────────────────────────────────────────╯ │
│                                                │
│  ATTEMPTS                          newest ↑    │
│ ╭──────────────────────────────────────────╮ │
│ │ ◐ Project     0:52    9:40 · try 2     ›  │ │ ← tap row → inline outcome editor (› chevron)
│ │ ○ Attempt     0:38    9:33 · try 1     ›  │ │   swipe ← row = Delete (Undo snackbar)
│ ╰──────────────────────────────────────────╯ │
│   last: V5 · project · 2 tries                │ ← faint prefill source line
│                                                │
│ ╭──────────────────────────────────────────╮ │
│ │   ↻  Repeat last  ·  Project              │ │ ← one tap = another Project effort, untimed
│ ╰──────────────────────────────────────────╯ │
│                                                │
├──────────────────────────────────────────────┤
│ [   + Log attempt   ] [  ◷ Timed attempt   ]  │ ← two CTAs, bottom thumb-zone, ≥48pt
├──────────────────────────────────────────────┤
│ ⏱ 44:08    ♥ 138 ·Z3• Z3=orange   [ Finish ] │ ← docked command bar (single HR home)
└──────────────────────────────────────────────┘

"+ Log attempt" → outcome strip slides up from BOTTOM (inline, not a full sheet):
   ┌──────────────────────────────────────────┐
   │ Outcome — Cave Roof                       │  (header names the climb)
   │  ⚡ Flash    ✓ Sent    ◐ Project   ○ Attempt│ ← boulder set (type-aware)
   │ Flash/Sent close the climb · Project &    │
   │ Attempt keep it open and +1 the count.    │
   │              [  Cancel  ]                  │ ← dismiss control in thumb zone, not a corner ✕
   └──────────────────────────────────────────┘

Tap a row's › → inline outcome editor (no sheet); switching to Flash/Sent
warns it will close the climb & collapse the count to 1:
   │ ◐ Project → [⚡][✓][◐•][○]   try 2    ✓done │

────────────────────────────────────────────────────────────────
STATE B · EMPTY — climb just created, ZERO attempts, NO HR yet
┌──────────────────────────────────────────────┐
│ ‹ Session            44:01               ⋯    │
├──────────────────────────────────────────────┤
│ ╭──────────────────────────────────────────╮ │
│ │ ◇ Top-rope   ┃ 5.11a ┃ blue       ⌃ hide  │ │ ← TR → YDS scale (net-new modelling)
│ │ Blue #3                                   │ │
│ │ 📍 The Spot · SF              (inherited)  │ │
│ │ ───────────────────────────────────────── │ │
│ │  TRIES        BEST          ON THIS CLIMB │ │
│ │   0            —                0:00       │ │ ← em-dash, not 0:00, for "no timed effort"
│ ╰──────────────────────────────────────────╯ │
│                                                │
│   No attempts yet.                             │ ← teach-the-loop, not a void
│   Log your first effort below — every          │
│   attempt stacks under this climb.             │
│                                                │
│   ╭─────────────────╮   ╭─────────────────╮   │
│   │ ○  First go      │   │ ◷  Time it       │   │ ← map 1:1 to the two CTAs
│   │    quick, untimed│   │    live timer    │   │
│   ╰─────────────────╯   ╰─────────────────╯   │
│                                                │
├──────────────────────────────────────────────┤
│ [   + Log attempt   ] [  ◷ Timed attempt   ]  │
├──────────────────────────────────────────────┤
│ ⏱ 44:01    ♡ no HR — pair watch    [ Finish ] │ ← NO-HR state: muted, tappable to pair
└──────────────────────────────────────────────┘

────────────────────────────────────────────────────────────────
STATE C · CLOSED — flashed (single attempt), climb done, 2-hr session
┌──────────────────────────────────────────────┐
│ ‹ Session          1:44:08               ⋯    │ ← elapsed rolls to h:mm:ss past 1 hr
├──────────────────────────────────────────────┤
│ ╭──────────────────────────────────────────╮ │
│ │ △ Boulder    ┃ V4 ┃ amber   ✓DONE  ⌃ hide │ │ ← DONE badge once closed
│ │ Slab Arête                  🎉 First V4!   │ │ ← inline milestone (reduce-motion = no burst)
│ │ 📍 The Spot · SF                          │ │
│ │ ───────────────────────────────────────── │ │
│ │  TRIES        BEST          ON THIS CLIMB │ │
│ │   1          0:21 ⚡            0:21       │ │
│ ╰──────────────────────────────────────────╯ │
│                                                │
│  ATTEMPTS                          newest ↑    │
│ ╭──────────────────────────────────────────╮ │
│ │ ⚡ Flash      0:21    9:18 · try 1      ›  │ │
│ ╰──────────────────────────────────────────╯ │
│   Sent first try. Nice.                        │ ← closed-climb copy replaces last/Repeat
│                                                │
│ ╭──────────────────────────────────────────╮ │
│ │  ＋ Log more on this climb (reopen)        │ │ ← explicit reopen — never silent re-log
│ ╰──────────────────────────────────────────╯ │
│                                                │
├──────────────────────────────────────────────┤
│ [   + Log attempt   ] [  ◷ Timed attempt   ]  │ ← disabled until reopen (or reopen + log)
├──────────────────────────────────────────────┤
│ ⏱ 1:44:08  ♥ 96 ·Z1• Z1=teal      [ Finish ] │
└──────────────────────────────────────────────┘
~~~

**Interactions**

- Tap the climb-card header ⌃ hide → collapse to a rolled-up one-line summary on the canvas (type icon + name + grade pill + status badge + 'N tries' + total time). Tap again to re-expand inline (pushes layout down). The disclosure morph is gated under Reduce Motion (cross-fade, no slide).
- Tap '+ Log attempt' → outcome strip slides UP from the bottom thumb zone (inline panel, not a full cover; slide replaced by fade under Reduce Motion). Pick Flash/Sent/Project/Attempt → row appends instantly with a success haptic, panel auto-dismisses. Outcome couples to count: Flash/Sent → attempts implied + climb closes (sessions.closeActiveClimb(), card flips to ✓DONE); Project/Attempt → climb stays open, attemptTimestamps gets a new entry. Untimed rows show '—' for duration; no min/sec entry.
- Tap '◷ Timed attempt' → full-cover StopwatchView FOCUS (count-UP, fill ring, session stats hidden, Glass HUD). Full-width ≥64pt STOP bottom-center → capture endedAt−startedAt → outcome strip → auto-collapse back to this surface with the new timed row at the top. Ring direction (filling) signals count-UP unambiguously vs the count-DOWN used by timed-exercise repeaters.
- Tap '↻ Repeat last · <outcome>' (only shown while the climb is OPEN) → one tap re-logs another effort with the prior outcome prefilled — the dominant re-log path is a single confirm. Hidden entirely once a send closes the climb; replaced by 'Log more on this climb (reopen)'.
- Tap a row's › → the row's outcome morphs in place into a Flash/Sent/Project/Attempt chip strip (inline, never a sheet). Choosing a send (Flash/Sent) on a multi-attempt row surfaces a one-line warning that it closes the climb and collapses the count to 1 before committing. Pick → row + mini-stats + live session pyramid recompute; an Undo snackbar appears.
- Swipe a row's leading edge → Delete; the row removes instantly with an Undo snackbar (instant-action + Undo, never a confirm dialog). Deleting the only send reopens the climb.
- Tap a timed row's duration → reopens the timed-attempt timer to re-measure just that row (optional correction path).
- Tap '＋ Log more on this climb (reopen)' in the CLOSED state → reopens the climb (status back to project), re-enables the two CTAs, and restores Repeat-last — the explicit, reversible alternative to silently appending onto a finished climb.
- Tap ⋯ overflow → menu: Rename climb / Change grade (scale-aware discrete picker) / Change type (with a warning it remaps the grade scale) / Edit gym / Add note / Delete climb. Delete climb is the only confirm-gated action and warns when it would erase a celebrated milestone.
- Empty-state mini-cards 'First go (quick, untimed)' / 'Time it (live timer)' map 1:1 to the two CTAs for a frictionless first effort.
- Logging a genuine history-derived best (new hardest send, first-ever send of this grade, flash) fires CelebrationBurst inline on the new row + a pinned '🎉 First V4!' chip in the header at the instant the outcome is picked — success haptic, auto-dismiss, gated behind Reduce Motion (haptic + static chip only, no confetti) and a mute setting.
- Tap the command-bar HR chip → opens the expandable LiveMetricsPanel (zones, recovery ring, calories). When no HR source is connected the chip reads '♡ no HR — pair watch' and taps through to the pairing/connect flow instead.

**Data captured**

- climbName → KilterLogEntry.climbName (set once at creation; promoted into the freeform SetKind.climbAttempt parent)
- climbType (boulder / top-rope / lead / sport) → NEW field on the climb parent; drives gradeScale + the status taxonomy (Kilter is boulder-only today — the modelling gap introduced here). Persisted as climbTypeRaw on the parent + mirrored onto SetLog for migration-safety.
- gradeScale (V/Font for boulder · YDS/French for TR/lead/sport) → NEW, derived from climbType, sticky per type across the session
- gradeLabel → KilterLogEntry.gradeLabel ('V5', '5.11a', '6c'); difficulty float → KilterLogEntry.difficulty for exact pyramid / hardest-send math (from a scale-aware discrete picker, replacing today's 'V4, 6c' freetext at FreeformPlayerView.swift:868)
- gym/location → session-level field inherited onto the climb (recents quick-pick); net-new to freeform — KilterLogEntry has no gym today
- per-attempt outcome → KilterLogEntry.statusRaw via KilterAscentStatus (flash/sent/project/attempt); persisted per row in SetLog.climbStatusRaw
- attempt count → KilterLogEntry.attempts (mirrored to SetLog.climbAttempts); each effort appends to KilterLogEntry.attemptTimestamps[]
- timed-attempt duration → KilterLogEntry.startedAt / endedAt (time-on-climb = Σ(endedAt−startedAt)); per-effort duration → NEW SetLog.durationSec on the .climbAttempt row (today durationSec exists only for .duration sets — extend it to climb rows)
- completedAt per row → SetLog.completedAt (the wall-clock timestamp shown 'try 2 · 9:40', localised 12h/24h)
- isSend (flash|sent) → KilterAscentStatus.isSend; feeds the sends counter + sessions.closeActiveClimb(); deleting the only send reopens the climb
- note → KilterLogEntry.note (optional, from ⋯ Add note)
- HR window per timed attempt → HRPoint series sliced by startedAt/endedAt → ClimbEffort.peakBpm/peakHRR for the completion summary; absent when no HR source is connected (surfaces a no-HR placeholder, never a fabricated 0)

**Live stats**

- Per-climb mini stats, recomputed on every log event: TRIES (KilterLogEntry.attempts / attemptTimestamps.count), BEST (fastest TIMED effort — '—' until at least one effort is timed), ON THIS CLIMB (Σ time-on-climb = endedAt−startedAt)
- Session hero in the command-bar context: Sends count (or hardestSendGrade chip once a hard send lands) from KilterSessionStats.compute
- Live grade pyramid + sends/projects/totalAttempts + sendsPerHour accrue on every effort (KilterSessionStats) — surfaced in the session expand layer, NOT stacked on this card (anti-clutter cap)
- Live HR chip in the command bar: bpm + Z1–Z5 zone (color-coded dot) + recovery dot — OR a muted no-HR state when latestHR is nil (Apple Watch not paired / band off)
- Milestone flags computed live against FULL history (not just session): new hardest send, first-ever send of a grade ('First V5!'), flash — drive the inline CelebrationBurst + the pinned header chip

**Rationale.** The spine of the redesign is the entity-then-attempt hierarchy: this surface IS the parent climb with its efforts underneath, directly fixing the documented Snappet pain point ('you cannot group 3 tries on the same V4 project' / 'flat attempt rows with no parent'). I verified the gap against the code: SetLog (WorkoutModels.swift:226) carries only climbGradeLabel/climbStatusRaw/climbAttempts for .climbAttempt, and the current add-sheet (FreeformPlayerView.swift:868) is the exact antipattern — a free-text 'Grade (e.g. V4, 6c)' TextField + native Picker + native Stepper. The refinement promotes the already-shipped KilterLogEntry shape (KilterModels.swift:251 — climbName/gradeLabel/difficulty/statusRaw/attempts/attemptTimestamps/startedAt/endedAt/note) and KilterAscentStatus (.flash/.sent/.project/.attempt + isSend, KilterModels.swift:222) out of the Kilter-only path — ~1:1 reuse, not new modelling. Changes from the input version, each fixing a concrete defect I found: (1) DE-DUPLICATED HR — the input rendered HR in BOTH the nav bar ('H 138·Z3') and the command bar ('♥ 138 Z3 ◔'); the live command bar (FreeformPlayerView.swift:342) is already the single HR home, so the nav now shows elapsed only, honoring the at-most-three-elements cap. (2) NO-HR EDGE CASE — latestHR is Optional and the chip conditionally renders, so State B shows the real '♡ no HR — pair watch' state instead of fabricating a bpm; dataCaptured notes peakBpm is absent without a source. (3) 2-HOUR SESSION — elapsed now formats h:mm:ss ('1:44:08') past an hour rather than overflowing 'mm:ss'. (4) COUNT-UP vs COUNT-DOWN — the brief's explicit concern: climbing timed attempts are always open efforts, so the FOCUS timer is count-UP with a FILLING ring, called out as distinct from the count-DOWN draining ring used by timed-exercise repeaters. (5) REPEAT-LAST SAFETY — the input's '↻ Repeat last · Project' could nonsensically re-log onto a closed climb after a send; State C suppresses Repeat-last when closed and replaces it with an explicit 'Log more (reopen)', so we never silently append to a finished climb, and the two CTAs disable until reopen. (6) BEST CLARITY — 'BEST' is defined as the fastest TIMED effort and shows '—' (not '0:00') when nothing is timed, fixing the all-untimed dead-stat. (7) DYNAMIC TYPE — the 3-up mini-stats row puts labels above values and the climb name sits on its own line, so nothing truncates at XXL; grade meaning is carried by the TEXT label (V5/5.11a), not colour alone, with an outcome GLYPH (⚡✓◐○) beside every status so colour-blind users read outcomes pre-attentively (color-and-shape, not color-only). (8) REDUCE MOTION — the disclosure morph, the bottom outcome-strip slide, the inline-edit morph, and CelebrationBurst all degrade to fade/haptic/static-chip. (9) THUMB ZONE — the outcome strip's dismiss is a bottom 'Cancel', not a top-right ✕ out of reach; both CTAs + Finish stay below the midline. (10) EDIT-vs-DELETE CLARITY — tapping a row opens an inline outcome editor via a '›' chevron (a real 44pt target) rather than a cramped '✎', leaving the leading swipe free for Delete; switching a multi-attempt row to a send warns before collapsing the count to 1 (preventing the 'Flash with 5 attempts' nonsensical state), per the type-aware send-status coupling. State coverage now spans empty (first-ever climb, no HR, inherited gym), populated-open (multi-try project), and closed (single-attempt flash + milestone + long session) so first-climb, single-attempt, no-gym-yet, and count-direction edge cases are all visible. Card-based progressive disclosure, the faint 'last: V5 · project · 2 tries' prefill line, instant-action+Undo, and the live mini-stats (KilterSessionStats.compute is pure and ready to wire) are preserved.

**Reuses (existing Snappet):** `.snappetCard() — each climb parent is an elevated card with a rolled-up header that expands inline`, `StopwatchView (mode: .countUp) — wall-clock-backed, success haptic; drives the full-cover Timed-attempt FOCUS screen with a FILLING ring (count-down draining ring reserved for timed-exercise repeaters)`, `Glass HUD kit (#111928@72%, white@14% hairline, SF Rounded tabular digits) — the timed-attempt cover chrome and HR overlay`, `Docked command bar (⏱ elapsed | ♥ HR bpm + zone + recovery dot | Finish) at FreeformPlayerView.swift:330 — kept verbatim as the SINGLE HR home; HR is removed from the nav to avoid duplication`, `CelebrationBurst — inline milestone overlay fired on the new row at the logging moment; Reduce-Motion → static chip + haptic`, `KilterLogEntry @Model (KilterModels.swift:251 — climbUUID/climbName/gradeLabel/difficulty/statusRaw/attempts/attemptTimestamps[]/startedAt/endedAt/note) — promoted into the freeform SetKind.climbAttempt parent`, `KilterAscentStatus (KilterModels.swift:222 — flash/sent/project/attempt + isSend) — the shared outcome vocabulary and the send/close coupling`, `KilterSessionStats.compute (sends/projects/totalAttempts/hardestSendGrade/sendsPerHour/pyramid[]/timeline[]/medianTimeOnClimb) — wired to recompute live on the freeform session`, `SetLog climb fields (climbGradeLabel/climbStatusRaw/climbAttempts/completedAt at WorkoutModels.swift:226), extended with durationSec on .climbAttempt rows + a mirrored climbTypeRaw — per-row persistence inside the freeform WorkoutSession`, `sessions.closeActiveClimb() — invoked when an outcome with isSend lands; reopen reverts the climb to .project`, `ClimbEffort (peakBpm/peakHRR via the engine) — per-timed-attempt HR window for the completion summary`, `Custom +/- steppers and KeypadDoneToolbar (FreeformPlayerView.swift:736) — for any bounded count / numeric entry in the climb-creation and grade-edit paths, instead of native UIStepper/Picker`

---

<a id="5"></a>
## 5. Climbing — Live timed attempt screen (full-cover FOCUS)

*Type: climbing*

**Purpose.** A full-screen, glanceable, one-handed FOCUS surface that times a single climbing attempt while the climber is mid-effort under a boulder. It is the COLLAPSE-on-stop third state of the PEEK→FOCUS→COLLAPSE flow: the session canvas (PEEK) hands off here when an attempt is timed, all session stats recede, exactly one hero metric (a count-UP stopwatch) dominates, and a giant bottom STOP button captures duration + start/stop timestamps. On Stop, an inline outcome prompt (Flash / Send / Fall / Project) writes the attempt under its parent climb and auto-returns to the canvas with zero re-entry of name, grade, or duration. Calm, dark, minimal chrome — you are mid-effort under a boulder, gripping the phone with chalky fingers. Untimed attempts skip this surface entirely (one tap on the card).

~~~text
Inner content width ~44 cols. Climbing is BOULDER-only in the model today
(Font/V scale); TR/lead/sport + YDS are net-new and NOT shown here.

STATE A — RUNNING  (timed attempt live · populated)
+--------------------------------------------+
| 9:41                            ·5G    86% |
+--------------------------------------------+
|  ⌄ Peek canvas                  try 3 of 3 |
|                                            |
|  ╭────────────────────────────────────╮   |
|  │ ▲ BOULDER           The Spot·Bishop │   |
|  │ Cave Roof                           │   |
|  │ [ V4 ] · Font 6c                    │   |
|  ╰────────────────────────────────────╯   |
|                                            |
|             ATTEMPT  ELAPSED               |
|                                            |
|                 0:42                       |
|        SF Rounded · tabular · 56pt         |
|                                            |
|       started 9:40 AM · counting up        |
|                                            |
|      ╭──────────────────────────╮          |
|      │  ♥ 142 bpm    ● Z3        │ glass    |
|      ╰──────────────────────────╯          |
|                                            |
|                                            |
|       ╭──────────────────────────╮         |
|       │       ⏹  S T O P         │ ≥64pt   |
|       ╰──────────────────────────╯         |
|         hold STOP to discard ⌫             |
+--------------------------------------------+
hero = the clock; HR demoted to a chip; ALL session
stats hidden. No nav bar, no command bar. Keep-awake on.

STATE A′ — RUNNING, NO HR + FIRST-EVER ATTEMPT
(no band paired / first climb of the session)
+--------------------------------------------+
|  ⌄ Peek canvas                       try 1 |
|  ╭────────────────────────────────────╮   |
|  │ ▲ BOULDER                  (no gym) │   |
|  │ Cave Roof                           │   |
|  │ [ V4 ] · Font 6c                    │   |
|  ╰────────────────────────────────────╯   |
|             ATTEMPT  ELAPSED               |
|                 0:08                       |
|       started 9:40 AM · counting up        |
|         (HR chip omitted — no signal)      |
|       ╭──────────────────────────╮         |
|       │       ⏹  S T O P         │         |
|       ╰──────────────────────────╯         |
+--------------------------------------------+
HR chip is REMOVED (not "♥ --"), reclaiming space.
"try 1" (no "of N"); gym line hidden when unset.

STATE A″ — LONG ATTEMPT / 2-HR SESSION (digit roll-over)
|             ATTEMPT  ELAPSED               |
|               1:04:18                      |   ← rolls M:SS → H:MM:SS past 59:59
|       started 8:37 AM · counting up        |   so 56pt digits never clip the frame

STATE B — STOPPED → inline outcome prompt
(slides up over the frozen 0:51; clock greyed, not gone)
+--------------------------------------------+
|  Cave Roof · V4                            |
|  attempt #3 · 0:51                          |
|  9:40 → 9:41 AM  (51s captured)            |
|  ╭────────────────────────────────────╮   |
|  │  How did it go?                     │   |
|  │                                     │   |
|  │   ┌──────────┐   ┌──────────┐       │   |  ← thumb-FARTHEST row =
|  │   │ ✗  Fall  │   │ ◷ Project│       │   |    "keep climb open"
|  │   └──────────┘   └──────────┘       │   |
|  │   ┌──────────┐   ┌──────────┐       │   |  ← thumb-NEAREST row =
|  │   │ ✓  Send  │   │ ⚡ Flash  │       │   |    "close climb" (most common)
|  │   └──────────┘   └──────────┘       │   |    each ≥44pt
|  │                                     │   |
|  │  Send / Flash → close climb         │   |
|  │  Fall / Project → keep open  ↻      │   |
|  ╰────────────────────────────────────╯   |
|                                            |
|  ╭──────────────────────────╮  ╭────────╮  |
|  │  Save as attempt (skip)  │  │  Undo  │  |  ← both in thumb zone,
|  ╰──────────────────────────╯  ╰────────╯  |    full-width, ≥44pt
+--------------------------------------------+
Swipe-down on this sheet == "Save as attempt" (never discards).
At large Dynamic Type the 2×2 grid reflows to one column.

STATE B′ — SEND that is a genuine history best
(CelebrationBurst overlay, then auto-return to canvas)
+--------------------------------------------+
|            ✦  First V4 send!  ✦            |  ← static text ALSO shown
|              ·· auto-dismiss ··            |    when Reduce Motion is on
+--------------------------------------------+
success haptic · reduce-motion + mute gated · fires
ONLY on real history bests, computed vs full history.

STATE C — PEEK-BACK (tapped "⌄ Peek canvas", clock still runs)
+--------------------------------------------+
|  ◀ Cave Roof · timing 0:48 …      ↩ back   |  ← slim returning banner,
+--------------------------------------------+    tabular ticking digits
|  Session                       Sends  2    |
|  ╭──────────────────────────────────────╮ |  canvas visible underneath;
|  │ ▲ Cave Roof  [V4]  · timing now…     │ │  tap banner to re-enter FOCUS.
|  │ ▲ Slab Start [V2]  ✓ sent · 2 tries  │ │  STOP not reachable from here —
|  ╰──────────────────────────────────────╯ │  banner is the only way back.
+--------------------------------------------+
~~~

**Interactions**

- ENTER: tapping the timed '▶ Start attempt' footer on the climb card pushes this full-cover (FOCUS) and AUTO-STARTS the StopwatchView — the screen opens already running, startedAt stamped, HR/HealthKit already warm from the session (no separate Start tap)
- Count-up runs hands-off: digits self-update off the wall clock (correct across backgrounding / lock); keep-awake prevents a re-unlock mid-effort
- TAP '⌄ Peek canvas' (top strip): collapses to State C to glance at the canvas WITHOUT stopping — the clock keeps running in the slim returning banner; tap the banner (or 'back') to re-enter FOCUS
- TAP giant ⏹ STOP (bottom-center): freezes the clock, captures elapsed (0:51) + endedAt, greys (does not remove) the frozen digits, and slides the State B outcome prompt up over them (COLLAPSE begins)
- LONG-PRESS STOP (hold-to-discard): a visible hold-progress fill arms a single confirm; completing it discards the attempt with an Undo and returns to the canvas with no row written — reserved because discarding a bid is destructive and hard to reverse
- TAP an outcome in State B (single ≥44pt tap): Flash → attempts=1, status=.flash, closes climb; Send → status=.sent, folds the accumulated attemptTimestamps[], closes climb; Fall → status=.attempt, appends this attemptTimestamp, climb stays OPEN (re-arm for try #4); Project → status=.project, stays open
- On a Send/Flash that is a genuine history best → CelebrationBurst fires inline ('First V4 send!') with a success haptic, auto-dismisses, then auto-returns to the canvas (Strava-style auto-return-on-finish); on Fall/Project no celebration, just auto-return
- On return the parent climb card now reads e.g. '3 attempts · 2:14 on climb' and KilterSessionStats recomputes live (Sends, hardest-send chip, pyramid accrue on the canvas)
- TAP 'Save as attempt (skip)' OR swipe the State B sheet down → saves the timed attempt as a bare .attempt (climb stays open) and returns — NEVER blocks on the picker, NEVER silently discards the captured duration
- UNDO after return (instant-action, not a confirm dialog) lets the user fix a mis-tapped outcome inline via the grade/status chip — no sheet re-open; reserve confirmation only for the destructive hold-to-discard
- VoiceOver: focus order is climb-context → ATTEMPT ELAPSED (announced as the live hero) → STOP; the frozen duration and captured-seconds are announced in State B before the outcome grid

**Data captured**

- climbUUID — parent climb identity (KilterClimbLog.climbUUID) so this timed bid groups under Cave Roof with prior tries
- climbName — 'Cave Roof' (KilterClimbLog.climbName), shown read-only, captured once at climb creation
- gradeLabel + difficulty — 'V4' primary label + 'Font 6c' scale label (KilterClimbLog.gradeLabel) with difficulty: Double (KilterClimbLog.difficulty) for exact pyramid / hardest-send math
- climbType / gradeScale — boulder + Font/V; NET-NEW persisted fields (the @Model KilterClimbLog does not store these today — boulder/Font-V is the only modeled type, so TR/lead/sport must be added before this screen can show them)
- startedAt — wall-clock stamp when the cover opened and the stopwatch auto-started (KilterClimbLog.startedAt)
- endedAt — wall-clock stamp at STOP (KilterClimbLog.endedAt); duration = endedAt − startedAt = 51s, captured with zero manual entry
- attemptTimestamps[] — this bid appended on STOP; Fall/Project keep accumulating, Send folds the whole array in (KilterLogEntry.attemptTimestamps)
- attempts — incremented per bid; Flash forces attempts=1 (prevents 'Flash with 5 attempts')
- status — KilterAscentStatus from the 2×2 picker: flash | sent | project | attempt (Fall→.attempt; confirmed the enum has no onsight/redpoint, so none are offered for boulder); isSend = flash|sent
- hrPoints / peak %HRR — HR samples streamed during the attempt for the chip and KilterSessionStats peak-HRR (HRPoint composite); absent gracefully when no band is paired
- gym/location — 'The Spot · Bishop' inherited from session/first-climb (display-only here, never re-entered; line hidden when unset)
- note — optional per-climb note (KilterLogEntry.note) NOT captured on this focus surface; left to an inline edit on the canvas to keep the live screen chrome-free

**Live stats**

- ATTEMPT ELAPSED — the hero: count-UP in 56pt SF Rounded tabular digits, the single dominant metric during FOCUS; rolls M:SS → H:MM:SS past 59:59
- Live HR — 142 bpm with zone label Z3 and a redundant zone-colored dot (pre-attentive cool→warm); omitted entirely when no HR signal
- Attempt number — 'try 3 of 3' / 'try 1', so you know which bid this is without leaving FOCUS
- HIDDEN-during-attempt (un-hide on return): KilterSessionStats recompute — running Sends counter, hardestSendGrade chip, live grade pyramid — deliberately suppressed in FOCUS to protect glanceability, accrue on the canvas after COLLAPSE

**Rationale.** Single hero metric + thin strip + peek-to-expand (Zwift/Apple Watch/WHOOP): exactly ONE metric is hero — the count-up clock at 56pt — HR is demoted to a thin glass chip and ALL session stats (pyramid, sends, recovery, calories) are HIDDEN during the attempt to protect glanceability mid-effort (anti-clutter; Zwift's four-field cap). Three-state PEEK→FOCUS→COLLAPSE (Strava Live Segments): canvas is PEEK, this timed attempt is FOCUS, STOP is COLLAPSE — capture duration, show the picker, auto-return. I added an explicit State C returning-banner because the original schema described 'v Hide' but never drew the peek-back state, leaving its behavior ambiguous. Two timer mentalities never blurred: this is an OPEN single effort so it counts UP (StopwatchView.countUp), never a countdown. The timer measurement IS the log: on STOP the attempt is auto-created with measured duration flowing into attemptTimestamps[]/startedAt-endedAt — no manual min/sec. Entity-then-attempt hierarchy: the parent card is read-only because identity was captured ONCE at climb creation; this screen owns only the child's timing+outcome — the highest-leverage fix for the flat-attempt-rows pain point. Refinements over the input: (1) I REORDERED the 2×2 outcome grid so Send/Flash — the most-frequent, climb-CLOSING actions — sit on the thumb-NEAREST bottom row, with Fall/Project (keep-open) on the far row, because the original put the two commonest closers farthest from the thumb. (2) The 'Skip outcome' link became a full-width, bottom-thumb-zone 'Save as attempt' button and swipe-down is bound to the same save, so a captured 51s is never silently lost on dismiss. (3) EDGE CASES the input omitted: no-HR REMOVES the chip rather than showing '♥ --'; the first-ever bid reads 'try 1' (no 'of N') and the gym line hides when unset; long attempts roll M:SS→H:MM:SS so a 2-hour session's 56pt digits never clip. (4) ACCESSIBILITY: the zone dot is redundant to the 'Z3' text (never color-only); under Reduce Motion the 'First V4!' milestone text still appears statically (motion suppressed, not the message); the 2×2 grid reflows to one column at large Dynamic Type; VoiceOver order is context→hero→STOP. (5) hold-to-discard gains a visible hold-progress fill so a chalky over-hold doesn't discard by surprise. Type-aware status: the 2×2 is boulder's taxonomy (flash/sent/project/attempt — confirmed KilterAscentStatus has exactly these four, no onsight/redpoint), Flash forces attempts=1 and closes; Fall→.attempt reuses the enum 1:1. VOCABULARY NOTE: the picker shows the user's verb 'Fall' but the canvas chip on return reads 'Attempt' (the enum's name) — a deliberate, documented divergence to keep the live verb natural while persisting the existing status. Instant-action + Undo: outcomes log instantly with inline chip edit on return; the only confirm is the destructive hold-to-discard. Milestone at the LOGGING moment: CelebrationBurst fires the instant Send is picked for a genuine history best, computed vs full history, never per attempt (Hevy genuine-bests-only). Live stats wire KilterSessionStats.compute (already pure) on return per 'show live climbing stats as data accrues.' Visual: dark glassmorphic cover (Glass HUD #111928@72%, white@14% hairline) with raised opacity behind digits, never thin-on-thin (NN/G Liquid-Glass-Cracked).

**Reuses (existing Snappet):** `StopwatchView / StopwatchViewModel (.countUp, wall-clock backed, success haptic, SF Rounded tabular digits) — the hero clock; onStop(elapsed) already hands back captured seconds to persist (confirmed signature: init(mode:onStop:), .countUp default, returns TimeInterval)`, `Glass HUD kit (#111928 @72%, white @14% hairline, SF Rounded tabular) — the context card + HR chip chrome`, `Live-HR chip pattern from the docked command bar (bpm + zone + zone-colored dot) — kept visible mid-attempt, gracefully removed when no signal`, `KilterClimbLog @Model + KilterLogEntry shape (climbUUID, climbName, gradeLabel, difficulty, status, attempts, attemptTimestamps[], startedAt/endedAt, note) — the parent+child model promoted out of the Kilter-only path into freeform SetKind.climbAttempt (SetKind already declares .climbAttempt in WorkoutModels.swift)`, `KilterAscentStatus { flash, sent, project, attempt } with isSend = sent||flash (confirmed in KilterModels.swift line 222-233) — drives the 2×2 picker 1:1 (Fall→.attempt)`, `KilterSessionStats.compute (pure: sends, projects, totalAttempts, hardestSendGrade, sendsPerHour, pyramid[], timeline[], peak %HRR) — recomputed live on return to the canvas`, `isFirstSendOfGrade milestone logic (KilterModels.swift line ~242: status.isSend && priorSendCountAtGrade==0) + CelebrationBurst — inline best celebration, reduce-motion + mute gated`, `color-banded grade chip + .snappetCard()/.snappetTile() surfaces, 4pt spacing grid, radii sm10/md16/lg24, Pulse coral/ember/Kilter-amber accents`, `Haptics.success() (already fired by StopwatchView on stop) for the stop + send confirmation`, `SetMeasure.formatDuration (used by ClimbAttemptTimerTests to render the frozen M:SS readout) — reuse for the frozen-duration header, extended to H:MM:SS roll-over`

---

<a id="6"></a>
## 6. Climbing — live in-session stats: a one-line "stat ribbon" docked just above the freeform climb cards, plus a tap-to-expand Live-stats sheet. Read-only/ambient; logging stays on the climb cards below it.

*Type: climbing*

**Purpose.** Make the freeform climbing session feel like it is building. ONE hero number (Sends, which momentarily flips to a Hardest-send grade chip the instant a harder send lands), a thin always-on tail, and a 4-bar mini pyramid sparkline sit in a single ribbon above the climb cards. One tap opens a Live-stats sheet (.medium then .large) with the accruing grade pyramid, sends/tries/projects, sends-per-hour, time-on-wall vs rest, and an effort/HR strip. The surface CAPTURES nothing — it is a derived read-model over the session's logged climbs. Honest-state-first: it renders nothing until the first attempt is logged, shows a "send one to start your pyramid" coachmark before the first send, gracefully DROPS the time-on-wall and HR rows when those signals are absent (untimed session / no Watch / simulator), and never bluffs data it does not have. Crucially the redesign FIXES a real data-model gap I confirmed in code: freeform climbs persist as flat SetLogs (WorkoutModels.swift L226) carrying only climbGradeLabel (free text), climbStatusRaw, climbAttempts, optional durationSec — NO climbUUID, NO float difficulty, NO per-climb startedAt/endedAt, NO attemptTimestamps[]. The original schema's claim of reading KilterSessionStats.make via KilterClimbLog.from(_:) is wrong: from(_:) maps a KilterLogEntry, which the freeform path never creates. So "1:1 reuse, no new modeling" is false. The load-bearing new work is a pure SetLog->KilterClimbLog adapter plus a grade-string->float parser; everything downstream (pyramid order, hardest-send, sends/hr) then reuses KilterSessionStats unchanged.

~~~text
LEGEND  (B)=boulder (TR)=top-rope   #=filled bar  .=rest/empty   o=zone dot   v=expand chevron
inner content width = 44 cols

STATE A — POPULATED  (stat ribbon docked above the climb cards)
+--------------------------------------------+
| 9:41                              ...   87% |
+--------------------------------------------+
| <  Climbing          Bishop Boulders    ... |
+--------------------------------------------+
| +-- LIVE STATS ------------------------+ v  |   <- whole ribbon = ONE 44pt tap target
| |  SENDS  7    hardest V5 . 14 tries   |    |      hero numeral · context tail
| |  ## ##  #### ###  ##                  |    |      4-bar mini pyramid (tallest=hardest)
| |  V2  V3  V4  V5   tap for full stats  |    |
| +-------------------------------------- + v |
|                                            |
| +-(B) Cave Roof       [V5]   v SENT ----+   |   <- climb cards (logging lives here,
| |  3 tries . timed 6:12             >   |   |       NOT on the stat surface)
| +---------------------------------------+   |
| +-(B) Blue #3         [V4]   PROJECT ---+   |
| |  5 tries . 8:40 on wall          >    |   |
| |  [   +1 try   ]     [  Log send  v ]  |   |
| +---------------------------------------+   |
| +-(TR) Slab Arete   [5.10a]  v FLASH ---+   |
| |  1 try                           >    |   |
| +---------------------------------------+   |
|            (+) Add climb                    |
+--------------------------------------------+
| (S) 41:12   (H) 142  Z3 o     [ Finish ]    |   <- docked command bar (reused verbatim)
+--------------------------------------------+
  ^elapsed    ^bpm+zone+recovery-dot   ^always-on
  o = recovery dot, tinted green(ready)/orange(resting)


STATE B — EXPANDED  (tap ribbon -> sheet at .medium, drag grabber -> .large)
+--------------------------------------------+
|  ====                      Live stats   (x) |   grabber + dismiss
+--------------------------------------------+
|   SENDS        HARDEST       SENDS / HR     |
|     7            V5            4.1          |   3 hero tiles (metric() pattern)
|  ----------   ----------   -------------    |
|  14 tries     3 projects   median 2:10     |
|                                            |
|  GRADE PYRAMID   (sends, easy -> hard)     |
|   V5  ##                        * new PR   |   horizontal BarMark (kilter amber)
|   V4  ####                                 |   *badge only on a genuine best
|   V3  ###                                  |
|   V2  ##                                   |
|                                            |
|  TIME ON WALL vs REST    (timed climbs)    |   <- ROW HIDDEN ENTIRELY when no
|   [#### wall 12:30 ##][.. rest 28:42 ...]  |      climb was timed (honest state)
|     31% on wall            69% rest         |
|   based on 2 of 4 climbs you timed         |   <- disclaimer: not whole session
|                                            |
|  EFFORT / HEART RATE     via Apple Watch   |
|   avg 138   max 171   redline 18%  Z4+     |
|   [Z1|Z2|##Z3##|###Z4###|#Z5#]  in zone    |   ZoneBar (reused)
|   recovery (o) 72%  Ready                  |   recovery ring (reused)
|                                            |
|   full pyramid + timeline in the summary   |
+--------------------------------------------+


STATE C — EARLY  (>=1 attempt, 0 sends — pyramid not started yet)
+--------------------------------------------+
| <  Climbing          Bishop Boulders    ... |
+--------------------------------------------+
| +-- LIVE STATS ------------------------+ v  |
| |  TRYING                              |    |   hero swaps to current effort
| |  Cave Roof  V5  .  try 2             |    |
| |  Send one to start your pyramid -->  |    |   teach, do not show an empty chart
| +--------------------------------------+    |
|                                            |
| +-(B) Cave Roof       [V5]   trying ---+    |
| |  2 tries . 1:48 on wall          >   |    |
| |  [   +1 try   ]     [  Log send  v ] |    |
| +--------------------------------------+    |
|            (+) Add climb                    |
+--------------------------------------------+
| (S) 3:21    (H) 128  Z2 o     [ Finish ]    |
+--------------------------------------------+


STATE D — NO HR / SIMULATOR / UNTIMED  (ribbon shrinks, no bluffing)
+--------------------------------------------+
| +-- LIVE STATS ------------------------+ v  |
| |  SENDS  4    hardest V4 . 9 tries    |    |   sends/hr DROPPED (session < ~6 min,
| |  ## ##  ####  ###                     |    |   cadence not yet meaningful)
| |  V2  V3   V4                          |    |
| +--------------------------------------+    |
+--------------------------------------------+
   ...command bar shows (S) timer + [Finish]
   only (HR chip ABSENT — no live source);
   expanded sheet hides the whole EFFORT row
   and the TIME ON WALL row (no timed climbs).
~~~

**Interactions**

- App opens straight onto the running freeform canvas — no setup wizard. The StatRibbon is HIDDEN until the first attempt is logged; it appears (fade/slide, reduce-motion -> instant) the moment exercise.sets first becomes non-empty, so an empty session shows the existing teach-the-loop hero, not an empty stat box.
- Every log event (+1 try, Log send, Add climb) re-runs the pure adapter + KilterSessionStats and animates the hero numeral and the mini-pyramid bars with a quick spring + .contentTransition(.numericText()) so numbers TICK, they do not pop. Recompute is debounced/cached against session.exercises so the ~1 Hz command-bar re-render does not re-scan every tick (mirrors recomputePrefills()).
- Tap anywhere on the ribbon OR the chevron -> LiveClimbingStatsSheet to .medium (hero grid + full pyramid). Drag the grabber up -> .large reveals time-on-wall (if any timed climbs) + the effort/HR strip (if a live source). Swipe down or (x) -> back to canvas.
- Hero-swap rule: ribbon shows SENDS by default; the instant a logged send is the session's hardest, the hero label flips to HARDEST with the color-banded grade chip for ~3s (a single timed transition, reduce-motion -> no animation but still swaps), then settles back to SENDS. Before the first send the hero shows TRYING + the current climb (State C).
- Milestone: when an outcome logged is a genuine HISTORY-derived best (new hardest-ever send, first-ever send of a grade, a flash), CelebrationBurst fires on THAT climb's card with a success haptic, and a '* new PR / First V5!' badge appears on the matching pyramid bar in the sheet. Reduce Motion -> haptic only (no confetti); a mute setting suppresses both. Never fires on a plain repeat send.
- Tap the command-bar HR chip -> opens the existing full LiveMetricsPanel (bpm, zones, recovery ring, calories, rest timer). The effort strip in the stats sheet is the peek; the panel is the deep dive. On the simulator / no source, the chip is absent and the sheet's effort row is hidden — the panel's own no-source state covers the edge case.
- FOCUS suppression: while a TIMED attempt's full-cover StopwatchView is up, the ribbon AND the sheet are hidden (PEEK -> FOCUS); on Stop they auto-return (-> COLLAPSE), matching Strava Live Segments. (Note: with the current code an attempt timer lives inside the LogSetSheet, so FOCUS = that sheet being presented; the ribbon is naturally covered. If timed attempts graduate to a full-cover, this rule keeps holding.)
- Read-only discipline: there are NO destructive or value-changing actions on this surface, so no confirmations and no Undo here. Correction happens on the climb card below (swipe-to-delete an attempt, inline-edit a grade chip) where instant+Undo already lives; the ribbon simply recomputes.
- One-handed reach: the ribbon sits in the upper canvas (a READ zone) and its only affordance is a forgiving full-width expand tap; every load-bearing action (Finish, Add climb, +1 try, Log send) stays in the bottom thumb zone on the command bar and card footers. The expanded sheet's only control (x / drag) is reachable at the sheet's top edge or by the standard swipe-down.

**Data captured**

- This surface CAPTURES nothing — it is a derived read-model recomputed live on every log event.
- DATA-MODEL FIX (verified against WorkoutModels.swift): freeform climbs persist as SessionExercise(kind: .climbAttempt) whose sets are flat SetLogs carrying ONLY climbGradeLabel (free text), climbStatusRaw, climbAttempts, optional durationSec. They do NOT carry climbUUID, float difficulty, startedAt/endedAt, or attemptTimestamps[]. Therefore KilterClimbLog.from(_:) (which maps a KilterLogEntry) CANNOT be used as the original schema claimed.
- Required new pure pieces: (1) FreeformClimbStats.logs(from: session) -> [KilterClimbLog], synthesizing climbUUID = exercise.id, status = KilterAscentStatus(rawValue: climbStatusRaw), attempts = climbAttempts ?? 1, and per-climb start/end from the attempts' completedAt extents; (2) GradeScale.parse(label) -> Double for V/Font/YDS so pyramid order + hardestSend math are exact instead of relying on a stored float that freeform never had.
- Hero/secondary numbers then read from KilterSessionStats.make(from: adaptedLogs, start: session.startedAt, end: .now, hrSeries: liveMergedBuffer, maxHR, restHR): .sends, .hardestSendGrade (+ a parsed difficulty for the chip color band), .totalAttempts, .projects, .sendsPerHour, .medianTimeOnClimb.
- Mini + full pyramid read KilterSessionStats.pyramid[] (GradeCount.gradeLabel, .difficulty, .sends), easiest->hardest; the difficulty now comes from GradeScale.parse, not a persisted float.
- Time-on-wall vs rest reads ONLY climbs with a known per-climb window (a timed attempt's durationSec, mapped into startedAt/endedAt by the adapter): wall = sum(timeline[].timeOnClimb where present), and the bar carries the 'N of M timed' count. For a fully untimed session timeOnClimb is nil everywhere, so the row is omitted (not shown as 0/100).
- Effort/HR strip reads the same live merged buffer LiveMetricsPanel uses: LiveHRMerge.merge(watch, ble) -> LiveMetricsSummary/WorkoutHRStats (avg/max bpm, redlineFraction, ZoneBar stats) + RecoveryReadiness.evaluate(currentBpm, restBpm, maxBpm). All gated on hasData -> the entire strip is hidden with no live source (simulator) and shows the panel's no-source copy on deep-dive.
- Milestone derivation reads full WORKOUT HISTORY, not just the session (FreeformSummary.milestones / a hardest-ever comparison + first-send-of-grade check over history), so 'First V5!' reads bigger than a session best — reusing the path already wired into the completion summary.

**Live stats**

- Sends — hero numeral, ticks up the instant a flash/sent outcome is logged (KilterSessionStats.sends over the adapted logs).
- Hardest send — color-banded grade chip (V5 / 6c / 5.11a); momentarily becomes the hero when a new hardest lands (.hardestSendGrade + a GradeScale.parse difficulty for the band color).
- Total tries — running effort count across all climbs (.totalAttempts), in the context tail.
- Sends per hour — live cadence (.sendsPerHour); SUPPRESSED until the session has run long enough (~6 min) to make it meaningful, so it never reads a jumpy 12/hr on the first send.
- Projects — climbs still open (.projects), in the sheet's secondary row.
- Live grade pyramid — sends-by-grade bars that accrue (.pyramid[], ordered by GradeScale.parse difficulty); 4-bar sparkline (top grades, '+N' for older) in the ribbon, full horizontal BarMark in the sheet.
- Time on wall vs rest — a two-segment split computed ONLY from timed climbs (sum timeOnClimb vs the timed window), with a 'N of M timed' caption; the whole row is omitted when no climb was timed.
- Median time-on-climb — .medianTimeOnClimb, in the sheet (nil-safe: hidden when no climb recorded a duration).
- Live HR / effort — current bpm + zone pill + recovery dot on the command bar (always-on, hidden with no source); avg/max/redline + time-in-zone ZoneBar + recovery ring in the sheet's effort strip and the full LiveMetricsPanel — entire strip hidden on the simulator / no-source.
- Session peak %HRR — .sessionPeakHRR, only when a max-HR bound exists; otherwise absent (bpm-only state), never shown as 0%.

**Rationale.** Refined against the actual code, keeping what worked and fixing what did not. KEPT: the single-hero + thin-strip + peek-to-expand spine, the capped always-on layer (one hero + tail + 4-bar sparkline; pyramid/HR/zones demoted to the sheet), live recompute on every log event, the inline history-derived milestone burst, and the reuse of metric()/ZoneBar/RecoveryReadiness/command-bar. FIXED: (1) The biggest flaw — the original schema asserted '1:1 KilterSessionStats reuse, no new modeling' and that it reads KilterClimbLog.from(_:). I verified in WorkoutModels.swift that freeform climbs are flat SetLogs with no climbUUID/float-difficulty/per-climb timing, and that from(_:) maps a KilterLogEntry the freeform path never creates. So I named the real required work: a pure SetLog->KilterClimbLog adapter + a GradeScale.parse free-text->float (also fixing the free-text-grade antipattern at the math layer). (2) Time-on-wall was shown confidently populated, but it depends on per-climb timing that only exists when the user used the optional attempt timer — so I made that row CONDITIONAL, added a 'based on N of M timed' disclaimer, and a state where it is dropped entirely; this prevents the bluff of a 55/45 split a fully-untimed (common) session cannot support. (3) The effort/HR strip is device-only (LiveMetricsPanel shows a no-source state on the simulator), so I added State D and made the whole strip + the command-bar HR chip self-hide with no live source, instead of rendering a flat empty ZoneBar. (4) Added a true EMPTY rule: the ribbon does not exist until the first attempt is logged (no empty stat box competing with the existing teach-the-loop hero), plus State C for >=1 try / 0 sends that teaches 'send one to start your pyramid' rather than showing an empty chart. (5) Accessibility: combined the ribbon into one VoiceOver element, kept minimumScaleFactor on the hero tiles for Dynamic Type, made the hero-swap + number-tick + celebration all reduce-motion gated (animation off but the value still swaps), and used color+shape (zone tint + ring + badge) so nothing is color-only. (6) One-handedness: the ribbon's only affordance is a full-width tap in the read zone; all load-bearing actions stay in the bottom thumb zone. (7) Perf/edge cases for a 2-hour session: recompute is debounced/cached against session.exercises (mirroring recomputePrefills) and sends-per-hour is suppressed below ~6 min so it does not read a meaningless 12/hr early. (8) Made the sheet a detented sheet, NOT a fullScreenCover, so it never occludes the docked command bar. Wireframe upgraded to four states (populated, expanded, early, no-HR/untimed) with aligned 44-col boxes and real sample data, showing exactly where rows DROP.

**Reuses (existing Snappet):** `KilterSessionStats.make(...) — the pure stats engine (sends, hardestSendGrade, projects, totalAttempts, sendsPerHour, pyramid[], timeline[], medianTimeOnClimb, sessionPeakHRR); reused unchanged once fed adapted logs.`, `FreeformPlayerView.commandBar (L330) — the docked elapsed | HR chip (bpm + Zx pill + zone-tinted recovery dot, hidden when latestHR==nil) | Finish bar, used verbatim as the always-on layer and entry to the metrics panel.`, `LiveMetricsPanel + LiveMetricsSummary / WorkoutHRStats + LiveHRMerge.merge — the full HR/zone/recovery/calorie deep-dive behind the HR chip; the sheet's effort strip is its peek; its hasData/no-source gating is reused so the strip self-hides off-device.`, `ZoneBar — the time-in-zone stacked color bar (reused from LiveMetricsPanel / KilterSessionDetailView.hrSection).`, `RecoveryReadiness.evaluate(...) ring/dot — zone-tinted recovery readout, reused from the command bar + LiveMetricsPanel.`, `Swift Charts pyramid (KilterSessionDetailView.pyramidSection BarMark) — reused for the full pyramid in the sheet; a lightweight capsule HStack for the 4-bar ribbon sparkline.`, `metric(value,label,icon,tint) hero-tile + .snappetCard()/.snappetTile() + SnappetColor (workout ember / kilter amber / surfaceMuted) + SnappetRadius/Spacing — the visual kit (note minimumScaleFactor(0.6) already in metric() handles Dynamic Type).`, `CelebrationBurst via .celebrates(on:) — inline milestone burst + success haptic, reduce-motion gated (owned by the climb card).`, `FreeformSummary.milestones / SetMeasure.isSend / SetMeasure.climbName — existing freeform climb helpers reused for milestone gating and send detection, so the stat surface and the completion summary agree.`, `HeartRateChart — the smoothed zone-colored HR trend, reused if the effort strip is pulled to full in the sheet.`

---

<a id="7"></a>
## 7. Timed exercise — pick or create

*Type: timed*

**Purpose.** When the user taps "Timed" inside a live Quick Session (FreeformPlayerView), this medium-detent bottom sheet is the single entry point for choosing WHICH timed exercise to log — mirroring the climb-add hierarchy. Instead of today's dead-end "Timed exercise" row + flat "Add set" sheet, the user first picks/names a reusable PARENT (Dead hang, Plank, Wall sit, 7:3 repeaters, Hollow hold, Bar hang, or a custom), then logs timed SETS underneath it. It leads with a searchable catalog (favorites + recents first, then category groups) with "Create new" pinned at top. The create path captures NAME + STRUCTURE (count-up / count-down target / repeaters) via protocol-preset chips, with a SINGLE live "Total" readout that makes a structured spec legible before commit — persisting customs to a small SwiftData TimedExerciseCatalog so they survive across sessions and flow through the same stats aggregation as seeded ones. The expensive form happens exactly once here; every subsequent set is one gesture.

~~~text
LEGEND  [Coral]=#FF5A4D CTA · {ember}=WORK phase · SELECTED segment shown in <caps> · inner width 44

STATE A — PICK · medium detent · catalog-first (the 90% path)
+--------------------------------------------+
| 9:41                                  100% |
+--------------------------------------------+
|             ====  drag up for more         |
|  Add a timed exercise                  (X) |
|  +--------------------------------------+  |
|  | (Q) Search or name an exercise…      |  |
|  +--------------------------------------+  |
|                                            |
|  +--------------------------------------+  |
|  | (+)  Create new timed exercise    >  |  | pinned·[Coral]
|  +--------------------------------------+  |
|                                            |
|  RECENTS                                   |
|  +--------------------------------------+  |
|  | (timer) 7s max hang     DOWN 7s   >  |  |
|  |   ↳ last 7.4s · 3d ago · best 8.1s ★ |  |
|  +--------------------------------------+  |
|  | (timer) Dead hang       UP    —   >  |  |
|  |   ↳ last 0:42 · yesterday          ☆ |  |
|  +--------------------------------------+  |
|  HANGBOARD                                 |
|  | (grid)  7:3 repeaters   7:3×6     >  |  |
|  | (grid)  Bar hang        UP    —   >  |  |
|  CORE                                      |
|  | (figure)Plank           DOWN 1:00 >  |  |
|  | (figure)Hollow hold     DOWN 0:30 >  |  |
|  LEGS                                      |
|  | (figure)Wall sit        DOWN 1:00 >  |  |
|  +--------------------------------- (scrolls)
+--------------------------------------------+
|(T)12:30  (♥)138 Z2•   [   Finish   ][Coral]|  command bar (live, behind sheet)
+--------------------------------------------+
  Tap row → sheet dismisses → parent card lands in
  canvas, pre-named, ready for its first set.

STATE A′ — SEARCH yields no match → inline create (0 extra taps)
|  +--------------------------------------+  |
|  | (Q) wall sit hold|                   |  |
|  +--------------------------------------+  |
|  +--------------------------------------+  |
|  | (+) Create “wall sit hold”        >  |  | [Coral]
|  +--------------------------------------+  |
|  Wall sit  · LEGS · DOWN 1:00         ☆ >  | (fuzzy match still shown)

STATE B — CREATE · sheet auto-expands to large detent · STRUCTURE=Count down
+--------------------------------------------+
|             ====================           |
|  (‹) New timed exercise                (X) |
|                                            |
|  NAME                                      |
|  +--------------------------------------+  |
|  | 10s max hang                         |  |
|  +--------------------------------------+  |
|  CATEGORY   <Hangboard> Core  Legs  Other  |
|                                            |
|  STRUCTURE                                 |
|  +-----------+-------------+------------+  |
|  | Count up  |<Count down> | Repeaters  |  | segmented
|  +-----------+-------------+------------+  |
|  Preset  <Max hang 10s> ( Tabata ) (Custom)|  chip rail →
|                                            |
|  TARGET                                    |
|     ( – )       00 : 10       ( + )        |  ±44pt steppers
|                min     sec                 |  (tap digits = keypad)
|                                            |
|  Lead-in   ( – ) 3s ( + )   Cue ◖Sound◗ ▾  |
|  +--------------------------------------+  |
|  | Total  0:13  ·  1 hold               |  | live pill
|  +--------------------------------------+  |
|  [✓] Save to my exercises (reuse later)    |
|                                            |
|  +--------------------------------------+  |
|  |          Add to session              |  | ≥44pt·[Coral]
|  +--------------------------------------+  |
+--------------------------------------------+

STATE B2 — CREATE · STRUCTURE=Repeaters (fields morph · total recomputes live)
+--------------------------------------------+
|  STRUCTURE                                 |
|  | Count up  | Count down |<Repeaters>  |  |
|  Preset <Repeaters 7:3×6> (Tabata)(Custom) |
|                                            |
|  WORK     ( – )  7s  ( + ) {ember}         |
|  REST     ( – )  3s  ( + )                  |
|  ROUNDS   ( – )  6   ( + )                  |
|  SETS     ( – )  3   ( + )                  |
|  REST/SET ( – ) 60s  ( + )                  |
|                                            |
|  Lead-in  ( – ) 3s ( + )   Cue ◖Haptic◗ ▾  |
|  +--------------------------------------+  |
|  | Total  5:00 · 6 reps × 3 sets · ↻ runner| live pill
|  +--------------------------------------+  |
|  [✓] Save to my exercises                  |
|  +--------------------------------------+  |
|  |          Add to session              |  | [Coral]
|  +--------------------------------------+  |
+--------------------------------------------+

STATE C — EMPTY CATALOG (first-ever timed exercise · teach-the-loop, not a void)
+--------------------------------------------+
|  Add a timed exercise                  (X) |
|  +--------------------------------------+  |
|  | (Q) Search or name an exercise…      |  |
|  +--------------------------------------+  |
|  +--------------------------------------+  |
|  | (+)  Create new timed exercise    >  |  | [Coral]
|  +--------------------------------------+  |
|                                            |
|     ⏱  Pick one to start, log holds under  |
|        it. Sets stack on the same card.    |
|                                            |
|  SUGGESTED                                 |
|  | (timer) Dead hang       UP    —   >  |  | seeded
|  | (grid)  7:3 repeaters   7:3×6     >  |  | (tap = adopt
|  | (figure)Plank           DOWN 1:00 >  |  |  the seed)
|  | (figure)Wall sit        DOWN 1:00 >  |  |
+--------------------------------------------+
~~~

**Interactions**

- Tap the 'Timed' button in FreeformPlayerView's Add-exercise confirmationDialog → sheet presents at .medium over the live session; session keeps running, command bar visible behind
- Type in search → live tokenized filter (ExerciseSearch-style) across name + category; favorites/recents float to top; no exact match offers an inline 'Create "<text>"' row while still showing fuzzy matches
- Tap a catalog row → sheet dismisses; a parent snappetCard() appends to the canvas pre-named with target/structure inherited; its first 'Add set' launches the structured runner (repeaters/tabata/emom), StopwatchView count-DOWN (target hold), or count-UP (open hold)
- Tap a row's favorite star → toggles favorite instantly (no confirm); favorites pin to top
- Swipe-left on a CUSTOM row → Edit / Delete (Delete instant + Undo snackbar); seeded rows offer Edit-as-copy only, never Delete, so the seed catalog can't be stranded
- Tap 'Create new' or the inline create → sheet animates to .large; inline create pre-fills NAME from the typed text
- Tap a STRUCTURE segment → field set morphs in place; live Total recomputes; Count up hides the min:sec field and shows 'Total — · open hold'
- Tap a preset chip → pre-fills relevant fields; nudging any stepper flips the chip to 'Custom' (never silently snapped back — anti-Tindeq)
- Tap/hold +/- steppers → increment/decrement with light haptic and press-hold accelerate; bounds enforced (work 1–600s, rounds/sets 1–50, rest 0–600s); Total updates on every change
- Tap the min:sec digits → numeric keypad (KeypadDoneToolbar); a 0:00 count-down target disables 'Add to session' with a gentle inline hint
- Toggle 'Save to my exercises' OFF → added to this session only, not persisted
- Tap 'Add to session' (Coral) → creates the parent card AND, if Save on, upserts the TimedExerciseCatalog row; sheet dismisses to the running session
- Drag grabber down / tap X / swipe down → dismiss without adding, no confirm
- Tap the back chevron in CREATE → returns to PICK preserving search text and scroll position

**Data captured**

- name → TimedExerciseCatalog.name + parent SessionExercise.displayName (mirrors KilterLogEntry.climbName as parent identity)
- category → TimedExerciseCatalog.category (list grouping key)
- structure mode → NEW shared TimedExerciseSpec.mode in ios/App/Shared (.openCountUp / .maxHang / .repeaters / .tabata / .emom)
- target duration → TimedExerciseSpec.workSec (count-down target) or nil for open count-up
- work:rest×rounds×sets → TimedExerciseSpec.workSec / restSec / reps / sets / restBetweenSetsSec
- lead-in → TimedExerciseSpec.leadInSec (default 3; warms the HR/HealthKit pipeline)
- cue mode → TimedExerciseSpec.cue (.sound / .haptic / .silent)
- favorite + recency → TimedExerciseCatalog.isFavorite / lastUsedAt (favorites-then-recents ordering)
- parent kind → SessionExercise.kindRaw = SetKind.duration.rawValue; the spec rides on the parent as an OPTIONAL, migration-safe field so child SetLog{durationSec} efforts inherit the timer mentality
- prefill source → last SetLog.durationSec for this named exercise via LastSetLookup (re-adding '7s max hang' defaults to its last/best hold)

**Live stats**

- The single 'Total' readout inside the CREATE form ('Total 5:00 · 6 reps × 3 sets · ↻ runner' or 'Total 0:13 · 1 hold', or 'Total — · open hold' for count-up) — recomputed on every field change; the only live number ON this sheet, present to make a structured spec legible before commit
- Each catalog row's last-time subline ('last 7.4s · 3d ago · best 8.1s') — a glanceable read of accrued per-exercise history pulled via LastSetLookup; best hold seeds the live PR for CelebrationBurst later
- The session command bar behind the sheet keeps its always-on stats live (elapsed 12:30 · HR 138 Z2 · zone-tinted recovery dot) — this sheet never blocks the running session's HUD

**Rationale.** This sheet implements the pattern library's highest-leverage move — Entity-then-attempt hierarchy — for timed work, and answers the user's note #2. Corrections vs the input version, each tied to a found problem:

DATA-MODEL MISMATCH (most important). The input says StopwatchView/StopwatchTiming is the engine "the chosen STRUCTURE feeds into" for ALL modes. I verified ios/.../StopwatchTiming.swift: Mode is only .countUp / .countDown(targetSec:). Repeaters/Tabata/EMOM are multi-phase sequences (lead-in + per-round work/rest + rest-between-sets); there is NO phase machine and NO TimedExerciseSpec/TimedExerciseCatalog/runner anywhere (grep empty). So the structured runner is NET-NEW, not 1:1 reuse. I split reuse accordingly and noted the spec must be an OPTIONAL field on SessionExercise because SetLog/SessionExercise are Codable composites inside the @Model session (the same lightweight-migration constraint the code documents for kindRaw/durationSec).

CONSISTENCY WITH SIBLINGS. FreeformPlayerView already adds exercises via a confirmationDialog and ExercisePickerView/ExerciseBrowserView (ExerciseSearch/ExerciseFilters) for lifting. The refined catalog reuses that sectioned tokenized-search idiom so the timed picker and the lifting picker feel identical, rather than inventing a new filter.

EDGE CASES the input ignored (now in wireframe/interactions): first-ever timed exercise (STATE C teach-the-loop with SUGGESTED seeds, not a void); no-match search (STATE A′ inline create plus retained fuzzy matches); count-up has no target (Total '— · open hold', min:sec hidden — removes the '0:00 target' nonsense state); 0:00 count-down guard (CTA disabled + hint, no silent default — anti-Tindeq); seeded rows non-deletable (Edit-as-copy) so the catalog can't be stranded; press-hold stepper accelerate for a 50-round set.

ACCESSIBILITY. Three cue toggles collapsed to one Sound/Haptic/Silent menu (less Dynamic-Type overflow); favorite star given a discrete ≥44pt sub-target separate from the row tap; chip rail horizontally scrollable so it reflows at large type instead of truncating; zone feedback stays color+shape (tinted dot); Total is text (VoiceOver-readable), not a graphic.

ONE-HANDEDNESS. Search, Create row, and Coral CTA sit in the bottom thumb zone; CTA is pinned to the safe area so it never scrolls away in the large detent (the input let it sit below a scrolling form).

ANTI-CLUTTER. Removed running session stats from the sheet (the command bar behind already carries them); the sheet's only live number is the Total. The preset chip rail is scoped to the selected STRUCTURE so it never offers Repeaters chips in Count-up.

Kept everything that worked: medium-then-large detents, pinned Create, recents-first, presets-never-snap, last-time prefill, instant favorite/delete + Undo.

**Reuses (existing Snappet):** `SetKind.duration ('Time') as the parent kind the timed-exercise card adopts (ios/App/Snappet/Features/WorkoutTracker/WorkoutModels.swift) — reused as the hierarchy parent, replacing today's flat 'Timed exercise' row added by FreeformPlayerView.addExercise(kind:.duration,…)`, `SetLog.durationSec — the child timed-set field each effort writes under the parent (WorkoutModels.swift); LastSetLookup.swift supplies the 'last 7.4s · best 8.1s' prefill subline`, `FreeformPlayerView as the already-running grow-as-you-go container; this sheet replaces the 'Timed exercise' confirmationDialog button's flat-row action and presents over the session, reusing its .sheet plumbing (FreeformPlayerView.swift)`, `snappetTile() for catalog rows and snappetCard() for the resulting parent card (ios/App/Snappet/DesignSystem/SnappetCard.swift)`, `ExerciseSearch tokenized name/category matching + the ExerciseBrowserView/ExercisePickerView search-and-section idiom (ios/App/Snappet/Features/WorkoutTracker/ExerciseCatalog.swift, ExerciseBrowserView.swift) — the catalog list mirrors the lifting picker so the two siblings feel identical`, `StopwatchView + StopwatchTiming.Mode (.countUp / .countDown(targetSec:)) — reused 1:1 ONLY for .openCountUp and .maxHang/count-down target holds (ios/App/Snappet/Features/WorkoutTracker/StopwatchView.swift, StopwatchTiming.swift)`, `Custom +/- steppers and KeypadDoneToolbar from the #158 freeform rework for the bounded fields and the min:sec target`, `Persistent docked command bar (elapsed · HR/zone chip · Finish) shown behind the sheet (FreeformPlayerView.swift command-bar section)`, `CelebrationBurstView seeded by the per-exercise 'best' shown here — fires later on a PR hold time (ios/App/Snappet/DesignSystem/CelebrationBurst.swift)`, `KilterSessionStats.compute pattern (ios/App/Snappet/Features/Kilter/KilterSessionStats.swift) reused as the template for aggregating timed parents into the completion 'Hold time' headline so customs are not stat dead-ends`

---

<a id="8"></a>
## 8. Timed exercise — live timed-set screen (full-screen FOCUS cover)

*Type: timed*

**Purpose.** The dedicated eyes-off live timer that runs ONE timed effort under a named timed-exercise parent (e.g. "7s Max Hang", "Plank", "Repeaters 7:3") and turns the measurement itself into the log. It presents as a full-screen FOCUS cover — the middle state of PEEK→FOCUS→COLLAPSE — so the freeform command bar and session stats recede and exactly one thing matters: the count. It handles both timer mentalities unambiguously and visibly: count-DOWN drains a ring (ember WORK / muted REST) with a terminal success haptic for a structured target (a fixed 10s hang, a 7:3 repeater work phase); count-UP for an open effort (max dead-hang to failure, AMRAP) shows the count growing with a thin progress arc vs your last best. A configurable 3-2-1 lead-in gets the user into position AND stamps startedAt early to warm the HR/HealthKit pipeline so the first samples land inside the set. Distinct per-phase audio + haptic cues let a climber read the timer peripherally mid-hang; the HR chip degrades gracefully to an inert gray pill when there is no source. On Stop / auto-finish the measured hold time (or completed reps×sets) flows straight into a pre-filled SetLog with one confirm tap — replacing today's manual Min/Sec entry as the PRIMARY path — then auto-collapses to the freeform canvas where live stats update and an optional remembered rest countdown starts in the command bar.

~~~text
Inner width = 44.  Phase color is stated to the right of each cover; it is NOT a literal background in code.

STATE B — LEAD-IN (3·2·1, opens every STRUCTURED run; .maxHang/.openCountUp can skip this)
+--------------------------------------------+
| 9:41                              ··· 100% |
+--------------------------------------------+
|  ✕ Cancel        7s Max Hang        ♥ ··  |  HR warming (no
+--------------------------------------------+   sample yet → ··)
|                                            |
|              Get into position             |
|                                            |
|                 .-'''''-.                  |  coral pulse ring
|               /           \                |  + 3·2·1 beeps
|              |      3      |                |  (Reduce-Motion:
|              |  starting…  |                |   no pulse, digit
|               \           /                |   only)
|                 '-.....-'                  |
|                                            |
|         Set 1/3 · Rep 1/6 · HANG 7s        |
|                                            |
+--------------------------------------------+
|            (   ✕   Cancel   )              |  one dismiss verb
+--------------------------------------------+   shared w/ run

STATE A — COUNT-DOWN, mid-WORK (repeater / fixed target)        ember-orange ring
+--------------------------------------------+
|  ✕ Close         7s Max Hang       ♥ 142  |
+--------------------------------------------+
|  Set 2/3 · Rep 3/6          next ▸ REST 3s |  now / next chip
|                                            |
|                .-'''''''-.                 |
|              /             \               |  draining ring
|             |    H A N G    |              |  (ember WORK)
|             |               |              |
|             |     0:04      |              |  56pt SF Rounded
|             |               |              |  tabular digits
|              \             /               |
|                '-.......-'                 |
|                                            |
|   ▓▓▓▓▓▓▓▓▓▓░░░░░░  total 1:18 left        |  draining bar
|                                            |
|  ♥ 142 · Z3 Aerobic  ● recover    🔊 cues  |  zone-tinted dot
+--------------------------------------------+
|   ( ‖ Pause )            (  ■  STOP  )     |  STOP ≥64pt,
+--------------------------------------------+   thumb zone

STATE A' — REST phase (telegraphs BEFORE the beep)             muted-surface ring
+--------------------------------------------+
|  ✕ Close         7s Max Hang       ♥ 138  |
+--------------------------------------------+
|  Set 2/3 · Rep 3/6          next ▸ HANG 7s |
|                                            |
|                .-'''''''-.                 |
|              /             \               |  draining ring
|             |    R E S T    |              |  (muted/calm)
|             |     0:03      |              |
|              \             /               |
|                '-.......-'                 |
|   ▓▓▓▓▓▓▓▓▓▓▓▓░░░░  total 1:11 left        |
|  ♥ 138 · Z3 Aerobic  ● recover    🔊 cues  |
+--------------------------------------------+
| ( ‖ Pause ) ( ▸▸ Skip )  (  ■  STOP  )     |  STOP stays
+--------------------------------------------+   widest/dominant

STATE C — COUNT-UP open effort (max dead-hang to failure)      filling thin arc
+--------------------------------------------+
|  ✕ Close         Dead Hang         ♥ 151  |
+--------------------------------------------+
|  Hang to failure          best so far 0:38 |  (first-ever: no
|                                            |   "best" line)
|                .-'''''''-.                 |
|              /  filling…   \               |  count-UP: digits
|             |               |              |  grow; thin arc
|             |     0:42      |              |  fills toward
|             |  ▲ +0:04 best |              |  last best
|              \             /               |
|                '-.......-'                 |  (no last best →
|                                            |   no delta line)
|  ♥ 151 · Z4 Threshold  ● push     🔊 cues  |
+--------------------------------------------+
|  ( ♦ RPE )              (  ■  STOP  )      |
+--------------------------------------------+

STATE D — STOP → COLLAPSE capture card (the measurement IS the log)
+--------------------------------------------+
|  ✕ Close         7s Max Hang               |
+--------------------------------------------+
|  ✦ Done — 6 × 7s · Set 3/3                 |
|                                            |
|  +--------------------------------------+  |
|  | TUT      0:42      best rep   7.1s   |  |  pre-filled,
|  | Reps×set 6 × 7s    completed  6/6    |  |  measured — no
|  | ♥ avg    144       peak 158 · Z4     |  |  manual entry
|  |                                      |  |
|  | RPE     ◀ 1 ·· [7] ·· 10 ▶  (skip)   |  |  bounded slider,
|  |                                      |  |  not 10 chips
|  | + Add note                           |  |
|  +--------------------------------------+  |
|                                            |
|   ( ↺ Redo )            [   Log set   ]    |  coral CTA
+--------------------------------------------+
| ↩ Logged "7s Max Hang" · rest 0:18 ·  Undo |  Undo snackbar
+--------------------------------------------+   (auto-rest)

STATE C-empty — FIRST-EVER timed exercise, no HR source, single max-hang
+--------------------------------------------+
|  ✕ Close         Plank             ♥ —     |  no source →
+--------------------------------------------+   inert gray pill
|  Open hold                                 |  (no Set/Rep row:
|                .-'''''''-.                 |   single effort)
|              /  filling…   \               |
|             |     0:08      |              |
|              \             /               |
|                '-.......-'                 |
|  (HR unavailable — connect a band)         |  honest, not Z1
+--------------------------------------------+
|  ( ♦ RPE )              (  ■  STOP  )      |
+--------------------------------------------+
~~~

**Interactions**

- ENTER: from the parent timed-exercise card's '+ Start set' footer → this cover slides up (FOCUS); the freeform command bar + session stats recede behind it; screen Keep-Awake engages for the whole run
- AUTO lead-in: a structured run (.repeaters/.tabata/.emom or any count-DOWN target) opens in STATE B (3-2-1) automatically; .openCountUp/.maxHang skip straight to a primed STATE C
- Lead-in: 3·2·1 beeps + final-3s haptic; the SINGLE dismiss verb is 'Cancel' (full-width); at 0 it auto-advances to the first WORK phase with a distinct work-start tone. Under Reduce Motion the coral pulse is suppressed — digit only
- Count-DOWN WORK (STATE A): ring drains via the existing StopwatchViewModel (final-3s beeps, success haptic at 0 — checkZero, already built); at 0 it auto-advances to REST (A') with a distinct rest-start tone + watch wrist-tap
- Phase color telegraphs BEFORE the beep (ember WORK → muted REST); the 'next ▸' chip previews the upcoming phase + duration so the climber reads it peripherally mid-hang
- '▸▸ Skip' appears in REST only and jumps to the next WORK; on the FINAL rest it instead finishes the run (no jump to a non-existent phase). 'Pause' freezes the CURRENT segment via StopwatchViewModel.stop()-banking, the runner clock holds, label flips to Resume; wall-clock keeps it correct across backgrounding (NET-NEW: the multi-segment runner owns which segment is paused — StopwatchViewModel only knows one segment)
- Count-UP (STATE C): digits grow; a live '▲ +0:04 best' delta appears the instant you pass your last-best hold — and is OMITTED entirely on a first-ever effort (no history) so there is no phantom 'best'. Optional inline RPE before stopping
- STOP (full-width ≥64pt, bottom-center, dominant in every state): freezes the timer, captures elapsed via onStop(elapsed), transitions FOCUS→COLLAPSE (STATE D) with the measured value pre-filled — no manual Min/Sec
- Tap the cue pill to cycle 🔊 sound → 〰 haptic → 🔇 silent (sticky per user, survives across sessions)
- STATE D capture card: drag the BOUNDED RPE slider (1-10, defaults unset/skippable — a bounded range gets a slider/stepper, not 10 separate ≥44pt chips that overflow) and/or '+ Add note'; 'Redo' discards and re-arms the SAME spec; coral 'Log set' commits
- COMMIT (one tap 'Log set'): writes the SetLog (kind .duration) under the parent timed exercise, fires CelebrationBurstView only on a genuine history PR (success haptic, reduce-motion + mute gated), auto-collapses to the canvas, and optionally auto-starts the remembered per-exercise rest countdown in the command bar
- UNDO: snackbar 'Logged … · rest 0:18 · Undo' offers instant Undo (removes the set, cancels the rest) — instant-action over a confirm dialog
- CLOSE: the SAME '✕' verb top-left in every running state (no 'Close' vs 'Cancel' split). Mid-run it confirms ONLY if a measured value would be lost; in the capture card or with nothing measured it dismisses straight to canvas
- ACCESSIBILITY: VoiceOver announces the live count and phase ('Hang, 4 seconds') on each phase change, not every tick; at AX Dynamic Type sizes the cue/HR strip wraps below the ring and the hero numeral caps so it never clips; the count-down ring already snaps under Reduce Motion (StopwatchView rule)

**Data captured**

- SetLog.durationSec ← measured hold time / total time-under-tension from StopwatchViewModel.stop() (the existing duration funnel via SetMeasure.formatDuration/splitDuration) — the PRIMARY path, replacing manual Min/Sec
- SetLog.completedAt ← stamped on append (appendLog owns the real stamp; the capture card clears it via the SetMeasure.duplicate idiom so appendLog re-stamps .now)
- SetLog kind = SetKind.duration, logged UNDER the named parent timed exercise (entity-then-effort hierarchy)
- Parent identity (NET-NEW): the timed-exercise name/displayName + its TimedExerciseSpec, persisted to a small SwiftData TimedExerciseCatalog so '7s Max Hang' survives across sessions and prefills next time
- Completed structure: reps×sets actually finished (e.g. 6×7s) + best-rep seconds — derived from the runner's phase progression; for a single open effort these are simply absent
- RPE 1-10 — DATA-MODEL GAP TO FIX: SetLog has NO rpe field today (only actualReps/actualWeight/weightUnit/durationSec/completedAt/climb*). Add an additive Optional `rpe: Int?` to SetLog (additive Optionals are migration-safe — SetLog is a Codable composite, a missing key decodes nil). Do NOT claim an existing field
- SetLog.notes — DATA-MODEL GAP TO FIX: SetLog has NO notes field today either. Add an additive Optional `notes: String?` to SetLog (same migration-safe rule). The earlier 'reuses SetLog.notes' claim is incorrect — there is no such field to reuse
- HR rollup for the set window: avg/peak bpm + dominant HeartRateZone (from app.liveWorkout HR sampled across startedAt→endedAt, mapped via HeartRateZone.forBpm using the session's resolved maxHR); when no samples landed, the rollup row is omitted rather than showing a fake Z1
- Lead-in window stamps the effort's startedAt early enough to warm HR/HealthKit so the first samples fall inside the set

**Live stats**

- The single hero metric: the count itself — remaining (count-DOWN) or elapsed (count-UP) in 56pt SF Rounded tabular digits; ring DIRECTION (draining vs filling) disambiguates the mode
- Set/Rep progress 'Set 2/3 · Rep 3/6' + a draining total-time-left bar — shown ONLY for structured multi-interval runs; hidden for a single open effort so a max-hang isn't cluttered with 'Set 1/1 · Rep 1/1'
- next-phase preview 'next ▸ REST 3s' / 'next ▸ HANG 7s' chip (structured runs only)
- Live HR chip '♥ 142 · Z3 Aerobic' + recovery/effort dot, zone-color tinted, persistent through all states; degrades to inert gray '♥ —' + 'HR unavailable' when no source — never a misleading zone
- Count-UP only: live '▲ +0:04 best' delta the instant you pass your last-best hold (history-derived, fires the PR feel at the logging moment) — entirely OMITTED on a first-ever effort
- Capture-card rollup: TUT 0:42 · best rep 7.1s · ♥ avg 144 · peak 158 · Z4 — computed for the just-finished set window; HR rollup line omitted when no HR was captured
- DELIBERATELY HIDDEN during FOCUS: session-level stats (sets count, total hold time, pyramid) recede behind the cover and reappear on COLLAPSE — anti-clutter / one-hero discipline. Decorative dots and 'hold to fail? no' noise from the prior draft are removed

**Rationale.** Refined against the verified codebase, not just the brief. Adversarial findings folded in: (A) DATA-MODEL MISMATCH — the prior schema claimed `SetLog.notes` and an existing RPE field; in `WorkoutModels.swift` SetLog carries only actualReps/actualWeight/weightUnit/completedAt/durationSec/climb* — neither notes nor rpe exists. Both are now flagged as NET-NEW additive Optionals (migration-safe because SetLog is a Codable composite, not an @Model, so a missing key decodes nil — exactly the decisions.md rationale for the additive optional pattern). (B) COMPONENT-NAME MISMATCH — the type is `CelebrationBurstView`, corrected. (C) COMPONENT-CAPABILITY MISMATCH — `StopwatchView` count-UP renders DIGITS ONLY (no ring); only count-DOWN has the 220pt draining ring and the at-zero success haptic. The filling/'growing' ring for count-up is therefore NET-NEW, and the phase/repeater state machine, lead-in, cue toggle, and runner clock are ALL net-new — StopwatchView/StopwatchViewModel knows exactly one segment, so the multi-interval runner must own which segment is paused/skipped. The schema no longer overstates reuse. Design pivots still ride the pattern library: (1) PEEK→FOCUS→auto-COLLAPSE (Strava Live Segments) — full-cover FOCUS, session stats hidden, Stop auto-returns. (2) Two timer mentalities never blurred (Box Timer/Seconds Pro) — count-DOWN drains with a terminal cue, count-UP grows; ring direction makes it unambiguous mid-hang. (3) The timer measurement IS the log (hang!/Crimpd) — Stop pre-fills the SetLog so logging is one confirm tap, killing manual Min/Sec as the primary path. (4) now/next/progress runner + per-phase cues + 3-2-1 lead-in (Seconds Pro/Intervals Pro) — and the lead-in warms HealthKit. (5) One hero + thin strip + capped (Zwift/Apple Watch) — removed the prior draft's decorative '·····' dots and 'hold to fail? no' line. (6) One-handed bottom-thumb-zone (Hoober ~75% rely on their thumb) — STOP stays ≥64pt and DOMINANT even in REST where Pause+Skip flank it (the prior 3-button REST row shrank STOP below spec — fixed). (7) Instant action + Undo, celebration only on genuine history PR. EDGE CASES newly handled: no-HR/no-source → inert gray pill + honest 'HR unavailable' (HeartRateZone.none, never a fake Z1); first-ever timed exercise → no 'best so far' / no '+best' delta; single max-hang → Set/Rep row suppressed; 2-hour AMRAP → formatDuration already emits H:MM:SS; Skip-rest on the FINAL rest finishes instead of jumping to a nonexistent WORK; count-up RPE rail replaced by a BOUNDED 1-10 slider (the match-control-to-range principle — 10 separate ≥44pt chips overflow the width). CONSISTENCY: a single '✕' dismiss verb across lead-in AND run (the prior 'Cancel' vs 'Close' split is gone), matching the sibling climb-attempt timer. ACCESSIBILITY: Reduce-Motion drops the lead-in pulse and the ring already snaps; VoiceOver announces phase changes not ticks; AX Dynamic Type wraps the cue/HR strip below the ring and caps the hero numeral so nothing clips. Honors the standing rule that timing math stays pure (StopwatchTiming) with HR/audio I/O at the view edge, and that TimedExerciseSpec lives in Shared/ so a future watchOS repeater renders identical phases/haptics.

**Reuses (existing Snappet):** `StopwatchView + StopwatchViewModel — the count-DOWN engine in full: wall-clock-backed (StopwatchTiming, correct across backgrounding), 220pt draining ring already built, success haptic at zero via checkZero already fires the terminal cue; onStop(elapsed) hands back the captured seconds; onRunningChange gates mode/teardown. NOTE the limits: count-UP is digits-only (no ring) and there is no phase/lead-in concept — those are net-new`, `StopwatchTiming (pure) — elapsed-with-pause, count-down clamp, reachedZero; keeps timing math device-free and unit-tested (the repo's pure-logic-at-a-thin-edge rule)`, `SetMeasure — formatDuration (M:SS, and H:MM:SS past an hour) for the hero digits + capture rollup, splitDuration as the inverse funnel into the manual Min/Sec state, and duplicate()'s completedAt-clearing idiom for the capture card so appendLog owns the real stamp`, `SetLog / SetKind.duration — the effort logs through the existing Codable SetLog (durationSec, completedAt) embedded in the @Model session — BUT rpe and notes are NET-NEW additive Optionals on SetLog, not reused fields`, `Glass HUD kit — #111928 @72% translucent dark base, white @14% hairline, SF Rounded tabular digits (the HR-overlay styling), now the FOCUS cover chrome; honors the raised-opacity-behind-digits legibility lesson`, `HeartRateZone (Shared/) — forBpm + pillLabel + color drive the persistent HR chip and the capture-card zone rollup, same mapping as watch/widget/reel; .none drives the honest inert 'HR unavailable' pill`, `CelebrationBurstView (DesignSystem/) — the inline auto-dismissing milestone overlay, fired only on a genuine history PR at the logging moment (correct type name)`, `FreeformPlayerView command bar — the docked elapsed timer · HR chip · Finish this cover collapses back onto, and where the auto-started rest countdown surfaces`, `LiveMetricsPanel — the peek-to-expand HR-zone/recovery layer this FOCUS surface intentionally suppresses while running and restores on collapse`, `Snappet Pulse tokens — Workout ember-orange #F2761E (WORK), Pulse Coral #FF5A4D (lead-in pulse + 'Log set' CTA), surfaceMuted (REST), 4pt grid, radii sm10/md16/lg24, custom +/- steppers (≥44pt) for the TimedExerciseSpec builder`

---

<a id="9"></a>
## 9. Strength — quick set logging (freeform session: exercise card with a sets list + fast reps×weight entry)

*Type: strength*

**Purpose.** Make logging a working set the single fastest interaction in the app, using the same entity→child grammar as the climb-first redesign. Tap "Strength" → pick or create a named EXERCISE (a parent .snappetCard), then log SETS underneath it. The dominant per-set interaction collapses to ONE tap because reps×weight + unit are prefilled from history (LastSetLookup) and surfaced as a "Same as last" repeat — wiring directly to the EXISTING repeatLastSet/SetMeasure.duplicate path, not new modeling. Big +/- steppers (the shipping QuickAddRow controls) handle bounded reps and ±2.5 weight; a numeric keypad (KeypadDoneToolbar) handles odd/unbounded weight; an inline plate calculator and a sticky session unit live without leaving the field. Committing a set is instant (with Undo) and OPTIONALLY auto-starts a remembered per-exercise rest timer (persisted on the already-present SessionExercise.targetRestSeconds) in the command bar. The hero stat is live Volume. This UPGRADES today's freeform strength path — which already has the inline QuickAddRow steppers + a "Repeat set" button but lacks a parent card, grouped sets list, rest timer, plate calc, and inline edit — into a scannable, grouped, prefilled exercise→sets logbook that mirrors the climb→attempts and timed→sets cards.

~~~text
┌──────────────────────────────────────────────┐
│ EMPTY — first strength entry of the session    │
├──────────────────────────────────────────────┤
│ 9:41                               •••   100% │
│                                                │
│  ‹ Back        Strength        0:08      •••  │  nav: back · type · session clock
│ ────────────────────────────────────────────  │
│                                                │
│                  ╭───╮                         │
│                  │ ⦿ │   Build your session    │
│                  ╰───╯                         │
│        Add an exercise, then log sets          │
│        under it. Reps & weight prefill         │
│        from last time — confirm in one tap.    │
│                                                │
│  ┌──────────────────────────────────────────┐ │
│  │  +   Add exercise                        │ │  Pulse Coral CTA (≥44pt)
│  └──────────────────────────────────────────┘ │
│                                                │
│  Recent · tap to re-add                        │
│  ╭─────────╮╭──────────────╮╭──────────╮       │
│  │Back Squat││ Bench Press  ││ Deadlift │  ›   │  horiz-scroll chip rail
│  ╰─────────╯╰──────────────╯╰──────────╯       │
│                                                │
├──────────────────────────────────────────────┤
│  ⏱ 0:08    ♡ 78  Z1 ●        [   Finish   ]   │  command bar (no rest yet)
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│ POPULATED — Back Squat expanded, mid-rest      │
├──────────────────────────────────────────────┤
│  ‹ Back     Vol 4,320 kg · 11 sets       •••  │  hero = live Volume · set count
│ ────────────────────────────────────────────  │
│ ┌────────────────────────────────────────────┐│
│ │ 🏋 Back Squat                  3 sets   ▲  ││  parent card · expanded
│ │    Last time:  3×8 @ 60 kg                 ││  LastSetLookup hint
│ │  ┌──────────────────────────────────────┐  ││
│ │  │ 1   8 × 60 kg            ✓   rest 0:24│  ││  logged set rows
│ │  │ 2   8 × 62.5 kg         ✓   rest 0:31│  ││  (swipe ← to delete)
│ │  │ 3   6 × 65 kg     🏆PR   ✓   resting…│  ││  PR flag on this row
│ │  └──────────────────────────────────────┘  ││
│ │  Next set ·····················  Same as last ▸││  1-tap repeat (coral text)
│ │   Reps              Weight                  ││
│ │   ╭───╮      ╭───╮  ╭───╮       ╭───╮       ││
│ │   │ − │  8   │ + │  │ − │ 65 kg │ + │       ││  big steppers (reps±1 / wt±2.5)
│ │   ╰───╯      ╰───╯  ╰───╯       ╰───╯       ││
│ │                    ⌨ keypad   ⊞ plates      ││  keypad · plate calc affordances
│ │  ┌──────────────────────────────────────┐  ││
│ │  │            ✓   Log set                │  ││  coral commit (≥44pt)
│ │  └──────────────────────────────────────┘  ││
│ └────────────────────────────────────────────┘│
│ ┌────────────────────────────────────────────┐│
│ │ 🏋 Bench Press   3×8 @ 47.5 kg   3 sets  ▼ ││  collapsed card · rolled-up
│ └────────────────────────────────────────────┘│
│  ┌──────────────────────────────────────────┐ │
│  │  +   Add exercise                        │ │
│  └──────────────────────────────────────────┘ │
├──────────────────────────────────────────────┤
│ ⏱ 28:14   ⟳ 1:12  ♡112 Z3●   [   Finish   ]  │  auto-rest chip live in bar
└──────────────────────────────────────────────┘
   ╭─────────────────────────────────────╮
   │ ⤺  Set 3 logged — Back Squat   Undo │  instant + Undo toast (auto-dismiss)
   ╰─────────────────────────────────────╯

┌──────────────────────────────────────────────┐
│ PLATE CALC — inline popover over weight field  │
├──────────────────────────────────────────────┤
│  Per side for 65 kg   ·   bar 20 kg    [kg|lb]││  bar weight editable · sticky unit
│   20    10    ·    ·    2.5    =  65.0 kg      ││
│  ╭────╮╭────╮            ╭────╮                 ││
│  │ 20 ││ 10 │            │2.5 │   ✓ exact match││  per-side plate stack
│  ╰────╯╰────╯            ╰────╯                 ││
│           [ Use 65 kg ]                         ││  writes back, never leaves field
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│ FIRST-EVER exercise (no history → no prefill)  │
├──────────────────────────────────────────────┤
│ │ 🏋 Bulgarian Split Squat        0 sets  ▲ │  │
│ │    First time — log your opening set      │  │  no "Last time" line; teach copy
│ │   Reps              Weight                 │  │
│ │   │−│  8  │+│       │−│  Body  │+│  ⌨      │  │  weight defaults "Body" (bodyweight)
│ │   ┌──────────────────────────────────────┐ │  │
│ │   │            ✓   Log set                │ │  │  no "Same as last" until set 1 exists
│ │   └──────────────────────────────────────┘ │  │
└──────────────────────────────────────────────┘
~~~

**Interactions**

- Tap Strength → running canvas, no wizard; empty state + recents rail
- Add exercise / recents chip → picker → appended card auto-expands
- Header tap expand/collapse; one active card at a time
- Steppers reps±1 / weight±2.5, prefilled from history
- Keypad for odd weight; plates popover writes back via 'Use N kg'
- Log set → instant commit + haptic + live Volume + optional auto-rest + Undo toast
- 'Same as last' → one-tap identical set via repeatLastSet
- Swipe-left delete (+Undo); tap value chip → inline edit, no sheet
- Rest hits 0 → tone/haptic; tap to +30s/skip; remembered per exercise; hidden when off
- Genuine full-history PR → inline CelebrationBurst + 🏆 badge, gated; never on baseline-less first set
- HR chip → LiveMetricsPanel; no-HR degrades to connect hint
- Unit toggle once → sticky kg/lb; logged sets keep their unit
- Finish → Volume/Duration/Sets summary + PR cards; empty session → discard confirm

**Data captured**

- SessionExercise.kindRaw = repsWeight
- SessionExercise.exerciseId / displayName (custom persisted)
- SetLog.actualReps
- SetLog.actualWeight (nil ⇒ bodyweight)
- SetLog.weightUnit (sticky, stamped per set)
- SetLog.completedAt (stamped on commit)
- SessionExercise.targetRestSeconds (existing field; remembered rest preset, default off)
- LastSetLookup prefill reps/weight/unit + hint
- Session defaultUnit, startedAt/elapsed, hrSeries
- Derived live Volume = Σ reps×weight, set count, est-1RM for PR detection
- No HR data captured when unpaired — sets unaffected

**Live stats**

- Hero: live Volume (Σ reps×weight, 'Vol 4,320 kg') in the nav/title bar — Activity-aware hero
- Set count ('11 sets') as the secondary rolled-up figure
- Per-card rolled-up summary ('3×8 @ 47.5kg') on each collapsed exercise header
- Live HR chip in the command bar: bpm · zone color dot · recovery dot — degrades to '♡ —' with no band
- Auto-rest countdown chip (mm:ss) in the command bar, shown ONLY while resting
- PR flags computed live at the log moment (heaviest set / rep-PR-at-weight / est-1RM PR vs full history) → inline 🏆 + CelebrationBurst
- Completion summary: Duration / total Sets / Volume headline + PR milestone cards

**Rationale.** The highest-leverage move is the entity-then-attempt hierarchy, and the critique sharpened HOW it lands: today's freeform strength path is NOT a flat 'Add set' row (the original schema overstated this) — FreeformPlayerView ALREADY ships the inline QuickAddRow [−]value[+] steppers seeded from LastSetLookup AND a 'Repeat set' button (SetMeasure.duplicate). The real gaps are (1) no parent .snappetCard grouping, (2) no auto-rest timer, (3) no plate calc, (4) no inline value-chip edit (only swipe-delete today), and (5) no Undo affordance. So the refined surface is an UPGRADE that wraps shipping controls in a card, not a rewrite — framing it honestly keeps the build ~1:1 reuse. Critical correction: SessionExercise.targetRestSeconds ALREADY exists on the model, so 'remembered per-exercise rest' is wiring, not new modeling — and rest defaults OFF (chip hidden) until armed once, fixing the edge case where an unwanted countdown nags a user doing untimed straight sets. The dominant interaction is engineered to ONE tap via 'Same as last' bound to the existing repeatLastSet path ('Default action is CONFIRM, not type'; Strong/Hevy PREVIOUS column). Input controls match value range (custom steppers for bounded reps, keypad for unbounded weight, ≥44pt per NN/G), reusing the exact shipping QuickAddRow controls. The plate calc + sticky kg/lb satisfy 'plate/unit awareness' and 'pick once, never per set' without leaving the field. Edge cases the original under-served and this fixes in the wireframe: FIRST-EVER exercise (no 'Last time' line — show a teach line, hide 'Same as last', default weight to 'Body'); NO HR (chip shows '♡ —', panel offers connect, sets unaffected); single set / mid-rest / PR-on-row states are all drawn. PR celebration fires at the LOGGING moment against FULL history (not session) and explicitly never on a baseline-less first set (avoids a meaningless burst). Instant-action-plus-Undo and inline value edit follow the anti-confirm-everything pattern, with the ONE allowed destructive confirm reserved for discarding an empty session. Hero = Volume follows 'single hero metric + thin strip' and the ground-truth completion rule. Bottom-thumb Log/Finish honors '~75% rely on their thumb'. The surface is deliberately the strength sibling of the climb→attempts and timed→sets cards so the Quick Session reads as one consistent grammar.

**Reuses (existing Snappet):** `QuickAddRow custom [−] value [+] steppers (reps ±1, weight ±2.5, sticky WeightUnit) — ALREADY in FreeformPlayerView; the card just hosts them`, `repeatLastSet + SetMeasure.duplicate — the EXISTING one-tap 'Repeat set' path, relabeled 'Same as last' on the divider`, `LastSetLookup.lastTime — pure cross-session prefill + 'Last time: 3×8 @ 60 kg' hint formatting (returns nil → drives the first-time teach line)`, `SetMeasure.summary / formatWeight — the one place a 'reps × weight' row renders (logged rows + collapsed-card summary)`, `SetKind.repsWeight + SetLog (actualReps/actualWeight/weightUnit/completedAt) + SessionExercise composite — existing migration-safe Codable models (all additive-optional)`, `SessionExercise.targetRestSeconds — ALREADY on the model; reused to remember the per-exercise rest preset (no new field)`, `ExercisePickerView + ExerciseCatalog (exercises.json) + WorkoutProgress customByID — shipping picker, bundled catalog, and persisted custom-exercise store (custom entries already flow through stats)`, `FreeformPlayerView session canvas + safeAreaInset(.bottom) command bar (elapsed timer · HR chip · Finish)`, `StopwatchView (count-down, wall-clock-backed, success haptic) — drives the auto-rest countdown chip`, `KeypadDoneToolbar — for unbounded/odd weight keypad entry`, `.snappetCard() (elevated parent) and .snappetTile() (flat sub-tiles / type cards / chips)`, `Live HR chip with zone color dot + recovery dot, and the expandable LiveMetricsPanel`, `CelebrationBurst — inline PR burst, already reduceMotion-gated in FreeformPlayerView`, `FreeformSummary completion screen (Duration / Sets / Volume headline + milestone cards) + FreeformSummary.repeatLabel for the value-labelled repeat button`, `WeightUnit (kg|lb) with .display + WorkoutMath kg/lb conversion for the plate calc and mixed-unit hint`

---

<a id="10"></a>
## 10. Running — quick log / live run (freeform session)

*Type: running*

**Purpose.** Make running a first-class but LIGHT member of the grow-as-you-go freeform session — same auto-started dated shell, same docked elapsed|HR-chip|Finish command bar, same StopwatchView / LiveMetricsPanel / CelebrationBurst / completion-summary vocabulary as climbing/timed/strength — with NO GPS. Two coherent paths off one screen, both honest about what is actually measured device-side: (1) QUICK LOG — a medium-detent sheet to type distance + duration (pace auto-derived) for a run that already happened, capturing in <=3 taps; (2) LIVE RUN — a minimal one-hero HUD whose ONLY device-measured live value is DURATION (count-up StopwatchView) + live HR; distance is entered at Stop (or typed in for a treadmill that shows it), and pace is computed once distance is known. The running session's headline stat is Distance (mirroring climbing=Sends / strength=Volume / timed=Hold-time) — but during a no-GPS live run the LIVE hero is Duration, because that is the only thing actually accruing; Distance becomes the headline at capture. The whole point is type COMPLETENESS and coherence: a runner gets the identical card/HUD grammar so all five Activity types feel like one app, and a future real-GPS run slots into the same card/HUD/splits by simply filling distanceMeters/HRPoint live instead of at Stop — no redesign.

~~~text
STATE 1 — EMPTY (tap "Running" on the canvas → choice)
+------------------------------------------------+
|  ‹ Running              Session 0:00       •••  |
+------------------------------------------------+
|                                                |
|                  ◉  figure.run                 |
|                  Log a run                      |
|     Type a run you finished, or track one      |
|     now — legs & splits log underneath it.     |
|                                                |
|  +---------------------+ +------------------+   |
|  |  ✎  QUICK LOG       | |  ▶  LIVE RUN     |   |
|  |     Type it in      | |     Track now    |   |
|  +---------------------+ +------------------+   |
|     ^Coral filled CTA      ^ember outline      |
|                                                |
|   Recent ›  [ 5K easy ]  [ Tempo 6.4 km ]      |
|             tap to clone your last run         |
|                                                |
|   (no recents yet → row hidden entirely)       |
+------------------------------------------------+
|  ⏱ 0:00            ♡ —  no HR      [ Finish ]   |
+------------------------------------------------+
   ^ same docked command bar as every type


STATE 2 — QUICK LOG (medium detent · capture-now)
+------------------------------------------------+
|  ‹ Running              Session 0:00       •••  |
| · · · · · · · · · ·  dimmed  · · · · · · · · ·  |
| ╭────────────────────────────────────────────╮ |
| │  ▁▁▁ grabber                               │ |
| │  Log a run                        [ Save ] │ │ ← Coral
| │                                            │ |
| │  DISTANCE              DURATION            │ |
| │  ┌────────────┐        ┌────────────────┐  │ |
| │  │  5.00  km▾ │        │  27:14   m:s   │  │ |
| │  └────────────┘        └────────────────┘  │ |
| │   keypad · unit sticky   KeypadDone toolbar │ |
| │                                            │ |
| │  Pace   5:27 / km        ← auto, derived   │ |
| │  Avg HR   + add          ← optional, tappable│
| │                                            │ |
| │  ─────  pull up for more  ─────            │ |
| │  Name    [ River loop________ ]            │ |
| │  Effort   ◌  ◍  ●    easy · mod · hard     │ |
| │  Note    [ felt strong___________ ]        │ |
| ╰────────────────────────────────────────────╯ |
+------------------------------------------------+
  Save → appends one run card, success haptic,
  sheet dismisses. Distance 0 or blank → Save off.


STATE 3 — LIVE RUN HUD (Glass · Duration hero, no GPS)
+------------------------------------------------+
|  ‹ Running         River loop    •  REC        |
+------------------------------------------------+
| ░░░░░  Glass HUD  #111928 @72%  ░░░░░░░░░░░░░░  |
|                                                |
|                 D U R A T I O N                |
|                                                |
|                  12:38                         | ← hero, SF Rounded tabular
|                  ↑ counting up                 |
|                                                |
|   ┌──────────────────────────────────────┐    |
|   │  DISTANCE     PACE        HR          │    |
|   │   tap to set    —      142 ● Z3       │    |
|   └──────────────────────────────────────┘    |
|        no-GPS → distance set at Stop           |
|        HR dot warms cool→ember by zone         |
|                                                |
|   Manual splits                                |
|   [ ⊕ Mark lap ]   Lap 1  4:21   Lap 2  4:30   |
|                                                |
|   ✦ Longest run yet — keep going!   ← burst    |
|                                                |
+------------------------------------------------+
|     ( ‖ Pause )           (  ◼  STOP  )         | ← STOP ≥64pt circular,
+------------------------------------------------+    thumb zone; Pause secondary
   2-hr run → hero reads 1:42:08 (h:mm:ss)


STATE 4 — POPULATED canvas (after logging a run)
+------------------------------------------------+
|  ‹ Running             Session 41:12       •••  |
+------------------------------------------------+
| LIVE  Distance 5.00 km · Pace 5:27 · Runs 1    | ← accruing stats strip
+------------------------------------------------+
|  ╭──────────────────────────────────────────╮  |
|  │ 🏃 River loop            5.00 km      ⌄  │  │ ← snappetCard header
|  │    27:14 · 5:27/km · ♡ 148 ●Z3           │  │
|  │    last time · 4.8 km · 5:31/km          │  │ ← faint prefill line
|  ╰──────────────────────────────────────────╯  |
|     ◂ swipe edit            delete swipe ▸      |
|                                                |
|  ╭ (expanded) ────────────────────────────╮    |
|  │  Lap 1   4:21      Lap 2   4:30         │    |
|  │  Lap 3   5:02 ✦PR  (no HR on this lap)  │    |
|  ╰──────────────────────────────────────────╯  |
|                                                |
|  [ ⊕ Add run ]                                 |
+------------------------------------------------+
|  ⏱ 41:12     ♡ 142 ●Z3 ◴      [   Finish   ]   |
+------------------------------------------------+
   ^ tap HR chip → LiveMetricsPanel (Z1–Z5 bar)
~~~

**Interactions**

- Tap 'Running' type card on the freeform canvas → session is already auto-started (lazy on first log, no wizard) → shows the QUICK LOG / LIVE RUN choice. No setup step before you can log.
- Tap a 'Recent' chip (e.g. '5K easy') → clones the last run's distance/pace into the QuickLog sheet pre-filled → one Save = a re-logged run in ~1 tap (last-time prefill). Chip row absent on first-ever run.
- QUICK LOG: tap QUICK LOG → sheet opens at medium detent, DISTANCE field focused → type distance (keypad, unit chip sticky for the session) → type duration (mm:ss, auto-promotes to h:mm:ss over an hour) → Pace auto-computes live as you type and is never an editable field → Save (Coral) enables once both numbers are > 0 → success haptic, sheet dismisses, run card appends. 3 taps + 2 numbers, no GPS.
- Pull the QuickLog sheet to large detent → reveals optional Name, Effort segmented (easy/mod/hard), Note — capture-now, enrich-later; none of these block Save.
- LIVE RUN: tap LIVE RUN → full-cover Glass HUD (FOCUS), session stats recede; StopwatchView count-UP drives the DURATION hero and the command-bar elapsed; HR chip stays visible if a band is paired. NO auto-distance and NO auto-splits (no GPS) — the strip shows Distance as 'tap to set'.
- Tap the 'Distance · tap to set' strip cell mid-run → a tiny inline keypad (treadmill readout) sets a running distance; Pace then computes live from that distance ÷ elapsed. Optional — most users set it once at Stop.
- Tap '⊕ Mark lap' → stamps the current elapsed into a duration-only lap chip; if that lap's elapsed beats the fastest lap in history, CelebrationBurst fires inline at that moment ('Fastest lap! 4:21'), success haptic, reduce-motion + mute gated.
- Tap Pause → StopwatchView pauses (wall-clock-backed; icon flips to pause.fill, hero tints yellow per the existing command-bar convention); tap again resumes. Auto-pause is NOT claimed (no motion sensing wired).
- Tap STOP (≥64pt, bottom-center) → opens a one-field 'How far?' distance capture (prefilled if distance was set mid-run; Skip allowed) → captures total duration + distance + laps into the run card → auto-COLLAPSE back to the canvas (Strava Live Segments auto-return).
- On the canvas, swipe a run card left → Edit (inline distance/duration correction reopens the sheet); swipe right / .onDelete → instant delete with an Undo toast (no confirm dialog).
- Tap a run card chevron → expands inline to its lap list (per-lap split time, PR flag, HR if present); tap collapses.
- Tap the command-bar HR chip → LiveMetricsPanel slides up (Z1–Z5 stacked bar, recovery ring, calories). Chip is inert and non-tappable when no HR data exists.
- Tap Finish (ember, command bar) → completion summary: Duration / Runs / Distance headline (or Duration headline if no run had distance) + any PR milestone card. Done saves & opens detail; Keep going returns; Discard is the only confirm dialog (destructive).

**Data captured**

- Run parent = a SessionExercise with kindRaw = new SetKind.run (additive enum case; legacy data unaffected because kindRaw is optional and decodes to .repsWeight). Adding .run also requires its display/symbol/addLabel arms — flagged as a real, small code touch, not free. displayName = route/run name ('River loop'), defaulted from recent run names.
- Each run / lap = one SetLog child. NET-NEW additive OPTIONAL fields on SetLog (Codable-optional, migration-safe per WorkoutModels D4 — verified: SetLog is a Codable composite, not an @Model, so synthesized Codable decodes a missing key as nil): distanceMeters: Double?, paceSecPerKm: Double? (DERIVED, never entered), avgBpm: Double?, effortRaw: String? (easy|moderate|hard), unitRaw: String? (km|mi, sticky per session).
- durationSec: Double? (REUSED from the existing .duration SetKind — verified present on SetLog) = the run/lap elapsed; StopwatchView's stop value flows straight in with zero re-entry.
- completedAt: Date? stamped on Save / STOP (REUSED — verified present on SetLog).
- Laps = an array of SetLog children under the run parent, each carrying durationSec (and distanceMeters only in a future GPS build) and the derived paceSecPerKm when distance exists — same parent→child grammar as climb→attempts, so a session reads as a scannable list.
- Live HR series → HRPoint[] (t seconds-from-startedAt, bpm, optional rrIntervalsMs) on the WorkoutSession, reused verbatim from the command-bar HR pipeline (verified present); avgBpm per run computed from the HRPoints within its [startedAt,endedAt] window. NO-HR runs simply carry an empty series and the card/strip drop the HR token.
- Session-level: a new Activity.running case is REQUIRED — there is no Activity/WorkoutType.running in the freeform path today (the prior schema's 'already exists' was wrong); freeform classifies by SetKind, and FreeformSummary's headline (Volume/Sends/Hold-time) must gain a Distance arm. Sticky distance unit (km|mi) picked once per session, inherited by every run.
- Pace is ALWAYS computed (distanceMeters ÷ durationSec) and stored as paceSecPerKm so pace/PR math is exact — never a free-text field. Pace is nil (shown '—') whenever distance is unknown; the UI never fabricates a pace from duration alone.

**Live stats**

- Duration — THE live hero during a no-GPS live run (count-up StopwatchView / session.startedAt), tabular, promotes to h:mm:ss past an hour. The only value actually measured live.
- Distance — the session HEADLINE (parallels Sends/Volume/Hold-time); accrues in the canvas stats strip from logged runs and becomes known at Stop (or via the optional treadmill keypad). Not a live-accruing value without GPS — shown 'tap to set' until captured.
- Pace (avg) — derived distanceMeters ÷ durationSec, shown once distance exists; '—' until then. Never entered by hand, never fabricated from duration alone.
- HR + zone — latest HR through HeartRateZone, dot warms cool→ember (color+shape); Z1–Z5 stacked time-in-zone bar on expand. Token disappears entirely when no band is paired.
- Laps — manual 'Mark lap' duration-only chips with a PR flag when a lap beats the fastest in history; become true distance splits in a future GPS build.
- Runs count — number of run cards logged this session (the 'Sets'-equivalent completion cell).
- Recovery readiness dot — ready/strained, from RecoveryReadiness on the HR chip (only when HR present).
- Calories — surfaced in the expanded LiveMetricsPanel only (capped, not always-on).

**Rationale.** Grounded in the verified codebase: SetKind today is exactly repsWeight|duration|climbAttempt (WorkoutModels.swift:180) and SetLog has actualReps/actualWeight/durationSec/climb* but NO distance/pace/avgBpm — so running is a genuine modeling gap, and crucially there is NO Activity.running in the freeform path (the prior schema falsely said it 'already exists'; freeform routes off type cards + SetKind, and FreeformSummary.swift only knows Volume/Sends/Hold-time). I therefore add one SetKind.run case (which also needs its display/symbol/addLabel arms) plus a Distance headline arm and a handful of OPTIONAL SetLog fields — the minimum to make Distance/pace first-class — and the optional-field choice matches the repo's own documented WorkoutModels D4 rule (SetLog is a Codable composite, not an @Model, so a missing key decodes to nil and old sessions are untouched). The single biggest correctness fix over the prior schema is HONESTY ABOUT NO GPS: with no GPS nothing measures distance live, so the prior 'Distance hero accruing live' + 'auto every 1.00 km splits' + 'current pace' are impossible. I make the LIVE hero DURATION (the only device-measured live value via the existing count-up StopwatchView, verified at StopwatchTiming.swift), set Distance at Stop (or via an optional treadmill keypad), replace auto-km splits with manual 'Mark lap' (duration-only) chips, and show Pace as '—' until distance is known — the strip never displays an unmeasured value. Distance is still the session HEADLINE (parallel to Sends/Volume/Hold-time in FreeformSummary), satisfying 'single hero metric + thin strip' (Zwift/Apple) without the no-GPS lie, and the 3-cell strip (down from 4) keeps Dynamic Type from overflowing. Edge cases are handled explicitly: first-ever run hides the Recent rail and teaches the loop; no HR drops the HR token everywhere rather than rendering an empty '♡ —' and makes the chip inert (LiveMetricsPanel unreachable not empty); a 2-hour run promotes mm:ss → h:mm:ss in both hero and keypad; a single distance-less run falls the completion headline back to Duration; Save is gated on distance>0 AND duration>0 so a zero run can't be logged. Accessibility: count-up is labelled '↑ counting up' so it can't be confused with a count-down (the library's 'never blur the two mentalities'); zone feedback is color+shape (dot tint + Z1–Z5 stacked bar) so it reads without numbers; CelebrationBurst is reduce-motion + mute gated and fires only on genuine history-derived bests (fastest lap, longest run/duration), not every lap. One-handedness: STOP is ≥64pt circular bottom-center in the thumb zone with Pause demoted to a smaller secondary pill so the recover-from action isn't fat-fingered, and delete is instant-with-Undo (only Discard-session confirms). The user's brief asked only to 'fit the type into the same session model + HUD language so all types feel coherent' — this adds ZERO new HUD vocabulary (command bar, StopwatchView, snappetCard, LiveMetricsPanel, CelebrationBurst, completion summary all reused verbatim, every reuse verified to exist) and the net-new surface is one SetKind case + optional SetLog fields. A future real-GPS run fills the same distanceMeters/HRPoint/laps live instead of at Stop and turns 'Mark lap' into true 1km splits — same card, same HUD, no redesign.

**Reuses (existing Snappet):** `StopwatchView(mode: .countUp) + StopwatchTiming.reading (verified StopwatchTiming.swift) — wall-clock-backed count-up + success haptic drives the LIVE RUN Duration hero and feeds durationSec on Stop`, `Docked command bar (FreeformPlayerView safeAreaInset(.bottom)) — stopwatch elapsed (tabular) · tappable HR chip · ember Finish, reused verbatim for the running canvas`, `HeartRateZone.forBpm(_:maxHR:) + .color + Zn capsule — the zone-tinted HR chip and dot, same as every other type; gracefully absent when no band`, `LiveMetricsPanel(session:) (verified LiveMetricsPanel.swift) — Z1–Z5 stacked time-in-zone bar + recovery ring + calories, opened from the HR chip`, `RecoveryReadiness.evaluate — the green/orange recovery dot on the HR chip`, `snappetCard() / snappetTile() — the run parent card and the QUICK LOG / LIVE RUN choice tiles`, `CelebrationBurst / .celebrates(on:) (verified CelebrationBurst.swift) — inline PR burst on a fastest lap / longest run / longest duration, reduce-motion + mute gated`, `FreeformSummary (verified FreeformSummary.swift) completion summary: checkmark.seal.fill + statCell trio + milestone headline — gains a Distance headline arm alongside the existing Volume/Sends/Hold-time`, `HRPoint[] live-HR series on WorkoutSession (verified WorkoutModels.swift:267) — reused to compute per-run avgBpm and the time-in-zone bar`, `KeypadDoneToolbar (verified present) — numeric distance/duration entry in the QuickLog sheet`, `SetLog Codable-optional additive-migration pattern (WorkoutModels D4, verified in the SetLog doc comment) — how the new run fields are added without breaking old data`, `Glass HUD kit (#111928@72%, white@14% hairline, SF Rounded tabular digits) — the LIVE RUN cover chrome`, `SnappetColor.workout (ember-orange) for the running session accent + Finish tint; Pulse Coral for the single sheet CTA`, `Existing .duration SetKind's durationSec/completedAt fields on SetLog — reused directly, no new keys for timing`

---

<a id="11"></a>
## 11. Shared live command bar / mini-HUD (docked, all session types) with peek-to-expand LiveMetricsPanel

*Type: all*

**Purpose.** The single, shape-identical docked instrument pinned to the bottom of every active freeform session (climbing/timed/strength/run/dance/other). COLLAPSED it is a glanceable strip capped at THREE information cells — elapsed timer | live HR chip (bpm + zone color + recovery dot) | one SetKind-aware HERO stat — flanked by the only two thumb-zone ACTIONS: a quick-add (+) and Finish. The hero, chip, and (+) menu are the ONLY parts that adapt per session; chrome, layout, and gestures never change shape between types. A swipe-up on the grab handle, or a tap on the HR chip, expands it IN PLACE into the LiveMetricsPanel (recovery ring, bpm+zone, Avg/Max/Redline/kcal, one stacked time-in-zone bar, live HR trend, optional rest timer, and a climbing-only deeper-peek pyramid/hardest-send row). It is the always-on layer of the layered HUD so the session canvas above stays uncluttered. Grounded in the real FreeformPlayerView.commandBar (today: timer | HR chip | Finish) and LiveMetricsPanel — this refinement adds the hero cell, relocates Add from the toolbar into the thumb zone, gives the chip a no-HR connect affordance, and makes pause reachable without leaving the bar.

~~~text
LEGEND  (s)=stopwatch  hr=heart  o=recovery dot  ~44pt taps
recovery o: green=Ready · amber=Resting · (hidden if unknown)
============================================================

A · COLLAPSED — climbing, populated  (DEFAULT)
+----------------------------------------------+
|  < Minimize   The Cave · Today    [||] [+]   | <- toolbar
|                                              |
|   .------------------------------------.     |
|   | (climb) Crimp Line     V5 · Sent  v |    |
|   |   3 attempts · 4:12 on climb        |    |
|   '------------------------------------'     |
|   .------------------------------------.     |
|   | (climb) Slab Project   V4 · Open  > |    |
|   '------------------------------------'     |
|         (canvas scrolls; bar is pinned)      |
+----------------------------------------------+
|  ====== grab handle · swipe up to expand === |
|  (s) 41:12   hr 142 Z3 o |  SENDS    4   (+) |
|  + - - - - - - - - - - - +    [   Finish   ] |
+----------------------------------------------+
   3 cells (timer · HR · hero) + 2 actions (+ · Finish)
   HR chip dot=amber here -> resting between burns

B · COLLAPSED — hero is the ONLY cross-type swap
  strength | (s)12:03  hr 138 Z3 o | VOL  4.2t | (+)
  timed    | (s)08:55  hr 121 Z2 o | HOLD 1:12 | (+)
  run      | (s)24:30  hr 159 Z4 o | DUR 24:30 |     (no +)
  dance    | (s)18:40  hr 134 Z3 o | DUR 18:40 |     (no +)
  other    | (s)05:02  hr  -- conn | DUR  5:02 | (+)

C · COLLAPSED — edge states
 NO HR src | (s)41:12  hr -- Connect | SENDS 4 | (+)
 PAUSED    | (||)41:12  hr 118 Z2 o | SENDS  4 | (+)
   timer glyph -> yellow pause; tap timer = resume
 REST live | (s)41:40  hr 118 Z2 o | REST 1:24| (+)
   rest co-opts hero slot: tap = skip · long-press = +30s
 0 sends   | (s)02:09  hr 132 Z3 o | SENDS  0 | (+)
   hero shows 0 (not blank) so it reads "logging works"

D · EXPANDED — swipe up / tap HR chip (LiveMetricsPanel)
+----------------------------------------------+
|  ====== swipe down / Done to collapse ====== |
|  Live metrics                          Done  |
|                                              |
|   hr 142 bpm            .--------.           |
|   [ Z3 · Aerobic ]     |   78%    |  ring    |
|   ! Adjust strap        | Ready  |           |
|                          '--------'          |
|                                              |
|   Avg    Max    Redline    kcal              |
|   131    168      6%       214               |
|                                              |
|   Time in zone                               |
|   |Z1|Z2--|Z3======|Z4---|Z5|                |
|    2:10 9:40  18:30   8:05 :47                |
|                                              |
|   Heart rate · last 20 min                   |
|     _.-^._.-^^-._.--^^-.__.-^-._              |
|                                              |
|   Climbing               Sends/hr  5.8       |
|   hardest V5   [ V3 V4 V5 ] pyramid          |
|                                              |
|   Rest    [1:00] [1:30] [2:00]               |
|                                              |
|  (s) 41:12  hr 142 Z3 o     [   Finish   ]   |
+----------------------------------------------+
 zone-bar widths = time-in-zone, cool->warm ramp
 ring = recovery buffer remaining (78% -> Ready)
 climbing row hidden for strength/timed/run/dance

E · EXPANDED — no HR source (sim / strap off)
+----------------------------------------------+
|  Live metrics                          Done  |
|                                              |
|        (heart.slash)                         |
|     No live heart rate                       |
|   Connect an Apple Watch or HR strap         |
|   to see live zones, recovery, kcal.         |
|                                              |
|        [  Connect a source  ]                |
|                                              |
|  (s) 41:12   hr -- --        [   Finish   ]  |
+----------------------------------------------+

F · QUICK-ADD (+) fans a menu (confirmationDialog)
+----------------------------------------------+
|             Add to session                   |
|          [  + Add a climb        ]           |
|          [  + Add timed exercise ]           |
|          [  + Add lifting        ]           |
|          [  (mic) Voice log      ]           |
|          [  Cancel               ]           |
+----------------------------------------------+
 row order follows the active type (climb first
 in a climbing session); selection opens the one
 medium-detent entity sheet (last type/gym/scale)
~~~

**Interactions**

- Tap HR chip -> expand to LiveMetricsPanel in place (showingMetrics = true) — same gesture target the chip has today.
- Swipe UP on grab handle -> expand to LiveMetricsPanel; swipe DOWN or Done -> collapse back to the strip (peek <-> focus). NEW handle; the chip-tap remains for users who never discover the swipe.
- Tap timer cell -> if paused, resume; LONG-PRESS timer -> pause (forgiving, reversible, glyph turns yellow). The existing top-bar Pause button is kept as a redundant, VoiceOver-discoverable target.
- Tap (+) -> fan a confirmationDialog (Add a climb / Add timed exercise / Add lifting / Voice log); selection opens the medium-detent entity-creation sheet (the one expensive form, last type/gym/scale prefilled). Hidden for pure run/dance.
- Tap hero stat WHEN it shows a running REST countdown -> skip the rest timer; long-press -> +30s. Otherwise the hero is a non-interactive label.
- Tap Finish -> finishTapped(): if completedSetCount > 0 open the completion summary cover, else exit silently (nothing to celebrate).
- In expanded panel: tap a rest preset chip -> start the wall-clock count-down; the chip rail collapses to a ring + Stop; success haptic at zero.
- No HR source -> chip shows greyed 'hr -- Connect'; tap opens the panel's connect state (heart.slash + 'Connect a source' CTA) rather than a void or a hidden chip.
- Auto-collapse / FOCUS handoff: starting a TIMED climbing attempt or a structured interval pushes a separate full-cover FOCUS timer and the command bar recedes; on Stop it auto-returns and the bar reappears collapsed (Strava Live Segments model). Untimed attempts skip FOCUS entirely.
- Throttled live refresh: a ~2s TimelineView recomputes the hero stat + HR chip + panel from FreeformSummary / LiveMetricsSummary / KilterSessionStats so numbers climb live without a 1Hz rescan of a long buffer.
- VoiceOver / leaf-only rule: timer and HR are labelled COMPOSITE leaves (read as one phrase each); (+), Finish, the timer (pause/resume), the chip, and the hero-as-rest are the only interactive elements. Hero label announces 'Sends, 4' etc.; rest variant announces 'Rest 1 minute 24 seconds, double-tap to skip'.

**Data captured**

- app.liveWorkout.latestHR -> HR chip bpm + HeartRateZone.forBpm(bpm, maxHR: profile.resolvedMaxHR ?? HeartRateZone.defaultMaxHR); nil -> greyed 'Connect' chip (not hidden).
- RecoveryReadiness.evaluate(currentBpm:restBpm:maxBpm:) -> recovery dot (green Ready / amber Resting, hidden on .unknown) and the expanded recovery ring fraction.
- session.startedAt -> elapsed timer (Text timerInterval); session.duration -> denominator for sends/hr + kcal estimate.
- app.userProfile.profile.resolvedMaxHR / restingBound -> zones, %HRR, recovery, calories (Keytel estimate for BLE; measured app.liveWorkout.energy for watch).
- FreeformSummary.sendCount(session) -> hero = SENDS (climbAttempt dominant); FreeformSummary volume -> hero = VOL (repsWeight); Σ durationSec -> hero = HOLD (duration); elapsed -> hero = DUR (run/dance/other). Dominant kind = the existing FreeformSummary.Dominant, NOT a separate Activity enum.
- KilterSessionStats.compute(...) — promoted out of the Kilter-only path to feed the expanded climbing row: sendsPerHour, hardestSendGrade chip, pyramid[]; full pyramid + timeline reserved for the completion summary.
- LiveHRMerge.merge(watch.samples, ble.samples) -> HRPoint[] for the trend chart + WorkoutHRStats avg/max/redline + time-in-zone widths.
- app.liveWorkout.energy / profile.estimatedKcal(forSeries:durationSec:) -> kcal cell (watch measured vs BLE estimated, never override the watch value).
- app.liveWorkout.isContactLost -> 'Adjust strap' warning in the panel headline.
- app.liveWorkout.isPaused -> timer glyph/color (pause vs stopwatch, yellow vs ember) across the bar and the Live Activity.
- Rest-timer preset (60/90/120s) + endDate -> wall-clock countdown surfaced in the hero slot; remembered per climb/type as a fast-follow.
- Quick-add (+) selection -> routes to a climbAttempt parent (KilterLogEntry-shape) / timed-exercise parent / lifting picker, reusing the existing addExercise / pickingLift mutators (keeps the freeform.addExercise id).

**Live stats**

- Hero stat (recomputed ~2s, SetKind-aware): SENDS (climbing) | VOL (strength) | HOLD (timed) | DUR (run/dance/other) — one cell, swaps label+value only.
- HR chip: current bpm + zone pill (Z1-Z5 colored) + recovery dot, live; greyed 'Connect' when no source.
- Running REST countdown co-opting the hero slot while active (tap=skip, long-press=+30s).
- Expanded: recovery ring (buffer remaining %), Avg / Max / Redline % / kcal, one stacked time-in-zone bar (Z1-Z5), live HR trend chart.
- Expanded climbing-only deeper peek: sendsPerHour, hardestSendGrade chip, live grade pyramid (full pyramid at completion) — hidden for non-climbing so the panel stays type-identical above this row.

**Rationale.** Anchored to 'single hero metric + thin always-on strip + peek-to-expand' (Zwift/Apple Watch/WHOOP): exactly THREE information cells (elapsed · HR · hero) plus the two thumb-zone actions, so glanceability survives. Crucially this corrects the source schema's miscount — it framed Finish as the third 'element' AND added a hero, which would have crowded the strip to five cells on a small phone; here the cap is three INFO cells with actions visually separated below the handle line. The hero swaps off FreeformSummary's existing dominant-SetKind logic (SENDS/VOL/HOLD/DUR), not a fabricated Activity enum with a distance hero freeform never captures — DUR is the honest fallback for run/dance/other. Three-state progressive disclosure (PEEK -> FOCUS -> auto-COLLAPSE) drives the swipe/tap-expand and the auto-return after a timed attempt (Strava Live Segments). Color-and-shape zone feedback stays pre-attentive: the chip dot/pill carries the Z1-Z5 color and the panel renders ONE stacked time-in-zone bar (Garmin In-Zone / Zwift Power Zone Bar), recovery framed as 'buffer remaining' (Gentler Streak). Live accruing stats wire FreeformSummary + KilterSessionStats into the running session so the hero number climbs on every log. Three fixes the source missed: (1) the no-HR chip now shows a greyed 'Connect' CTA instead of vanishing — today's code HIDES the chip entirely, a discoverability hole; (2) Add is relocated from the top toolbar into the bottom thumb zone (Hoober ~75% rely on thumb; the body is busy/chalky) while keeping the freeform.addExercise id so UITests pass; (3) pause/resume is reachable on the timer cell (long-press/tap) rather than only a top-bar button out of the thumb zone, with the toolbar button kept for VoiceOver. Rest co-opts the hero slot with tap-to-skip + long-press +30s (instant action + Undo, no confirm dialog). Edge cases are drawn explicitly: 0 sends shows '0' (not blank, so logging reads as working), paused, rest-running, and no-source. The shape is byte-identical across types per the brief — only hero label/value, the (+) menu order, and the climbing-only expanded row adapt. Glass-HUD chrome honors the NN/G 'raise opacity behind digits' legibility caveat over a dark base.

**Reuses (existing Snappet):** `FreeformPlayerView.commandBar — the existing docked timer | HR chip | Finish strip (lines 330-378), EXTENDED with the hero cell, the relocated (+), and a swipe-to-expand grab handle; keeps overallWorkoutTimer / freeform.hrChip / freeform.finish ids.`, `LiveMetricsPanel (whole sheet) — recovery ring, bpm+zone headline, Avg/Max/Redline/kcal grid, ZoneBar, HeartRateChart, RestTimerView reused as the expanded layer (already opened from the chip via showingMetrics).`, `HeartRateZone (Shared/) — forBpm + color/colorHex + pillLabel for the chip pill and zone bar; one source of truth across phone/watch/widget. Chip uses bare 'Z3'; panel uses 'Z3 · Aerobic' pillLabel.`, `RecoveryReadiness.evaluate / .fraction / .state — the chip's recovery dot and the panel's recovery ring (hidden on .unknown, matching the existing nudge).`, `LiveHRMerge.merge + LiveMetricsSummary + WorkoutHRStats — pure HR math feeding the chip, stat grid, trend, and time-in-zone widths.`, `FreeformSummary (sendCount / volume / holdTimeSeconds + Dominant) — the dominant-kind hero label/value and the completion headline; the SAME source the done-screen uses, so live hero and final summary never disagree.`, `KilterSessionStats.compute — promoted out of the Kilter-only path to feed the expanded climbing row (sends/hr, hardest send, pyramid).`, `StopwatchView (count-down, wall-clock backed, success haptic) — the rest countdown surfaced in the hero slot (RestTimerView already uses an end-Date countdown).`, `app.liveWorkout (latestHR / isPaused / isContactLost / energy / activeKind / watch.samples / ble.samples) — the live source already threaded into commandBar and LiveMetricsPanel.`, `addExercise / pickingLift / showingAddMenu mutators + the existing confirmationDialog('Add exercise') — reused for the relocated (+), preserving the freeform.addExercise id and the Lifting/Climbing/Timed routes.`, `Glass HUD kit (#111928@72%, white@14% hairline, SF Rounded tabular digits) + Snappet Pulse tokens (ember-orange #F2761E workout, Pulse Coral #FF5A4D CTA, 4pt grid, radii sm10/md16/lg24, .snappetCard()/.snappetTile()) — the bar/panel chrome.`, `CelebrationBurst + Haptics.success — milestone burst fired at the logging moment on the climb card (reduce-motion/mute gated), referenced from this surface.`

---

<a id="12"></a>
## 12. Session completion summary (type-adaptive) — the "Finish" destination of a Quick Session (FreeformPlayerView.doneScreen, re-laid-out)

*Type: all — climbing / timed / strength carry bespoke bodies; running / dance / other degrade to the shared Duration-hero shell*

**Purpose.** duplicate-removed

~~~text
Inner width = 44. Brand: seal/headline tint = ember #F2761E (climbing leans
Kilter amber #B45309); the SAVE CTA is Pulse Coral #FF5A4D (one coral per screen).

STATE A — CLIMBING, milestone landed, full data (default)
+--------------------------------------------+
|  < Keep going    Recap        [↑ Share]    |  back never destructive
+--------------------------------------------+
|              .*  *.   ( ✦ )   .*  *.       |  CelebrationBurst 1.5s,
|                  seal bounce ·1×            |  RM→haptic only, no confetti
|             First V5 send!                 |  ember headline
|        Boulder · Tue Jun 18 · 1h 02m       |  type · date · duration
|                                            |
|  +--------------------------------------+  |
|  |   8         V5          42m          |  |  HERO STRIP — 3 cells, capped
|  |  SENDS    HARDEST    ON THE WALL     |  |  tabular SF-Rounded
|  +--------------------------------------+  |
|                                            |
|  Grade pyramid                  11 climbs  |
|  +--------------------------------------+  |
|  | V5 ▓▓                            2   |  |  BarMark, amber→cool ramp,
|  | V4 ▓▓▓▓▓▓                        6   |  |  hardest at apex
|  | V3 ▓▓▓▓                          4   |  |
|  | V2 ▓▓▓                           3   |  |
|  +--------------------------------------+  |
|   7.8 sends/hr · 2:10 median · 18 tries    |
|                                            |
|  Effort                       peak 92% ▾   |
|  +--------------------------------------+  |
|  | ▓Z1▓│▓Z2▓│▓▓Z3▓▓│▓▓▓Z4▓▓▓│▓Z5▓ 142  |  |  single stacked ZoneBar
|  +--------------------------------------+  |  (NET-NEW component)
|   12m in Z4+ · recovery �in▭▭▭▭▭▭▭ ample   |  buffer-remaining framing
|                                            |
|  Timeline                          Show ▾  |  collapsed: top 4 of 11
|  +--------------------------------------+  |
|  | Cave Roof    [V5] Sent   3· 2:40     |  |
|  | Blue #3      [V4] Flash  1· 0:51     |  |  grade chip color-banded;
|  | Slab Arete   [V4] Sent   2· 1:38     |  |  status badge; tries· time
|  | Yellow Comp  [V3] Proj   5· 3:12     |  |
|  +--------------------------------------+  |
|                                            |
|  +--------------------------------------+  |
|  | ▶  Turn 4 clips into a reel        > |  |  Studio CTA — hidden if 0 clips
|  +--------------------------------------+  |
|                                            |
+--------------------------------------------+
|  [        Save session        ]   Discard  |  Coral primary · quiet discard
+--------------------------------------------+  bottom thumb zone, pinned

STATE A′ — CLIMBING, DEGRADED: no HR, no per-climb timing
(no startedAt on climbs ⇒ no time-on-wall/median; no maxHR ⇒ no Effort card)
+--------------------------------------------+
|  < Keep going    Recap        [↑ Share]    |
+--------------------------------------------+
|                  ( ✓ )  seal               |
|               Nice session                 |  neutral — no milestone
|        Boulder · Tue Jun 18 · 58m          |
|  +--------------------------------------+  |
|  |   5         V4          11           |  |  ON-THE-WALL cell DROPS to
|  |  SENDS    HARDEST    CLIMBS          |  |  Climbs when no per-climb time
|  +--------------------------------------+  |
|  Grade pyramid                   8 climbs  |
|  +--------------------------------------+  |
|  | V4 ▓▓▓▓▓                         5   |  |
|  | V3 ▓▓▓                           3   |  |
|  +--------------------------------------+  |
|   13 tries          (no median — untimed)  |  micro-stats degrade gracefully
|                                            |
|   (Effort card omitted — no HR recorded)   |
|                                            |
|  Timeline                          Show ▾  |
|  +--------------------------------------+  |
|  | Project Wall [V4] Sent   4· —        |  |  time shows — when untimed
|  | Comp Slab    [V3] Flash  1· —        |  |
|  +--------------------------------------+  |
+--------------------------------------------+
|  [        Save session        ]   Discard  |
+--------------------------------------------+

STATE B — TIMED (hold-time hero, per-exercise breakdown)
+--------------------------------------------+
|  < Keep going    Recap        [↑ Share]    |
+--------------------------------------------+
|                  ( ✦ )  seal               |
|           New PR · 14s dead hang           |
|         Timed · Tue Jun 18 · 28m           |
|  +--------------------------------------+  |
|  |  4:36        14s          12         |  |
|  | HOLD TIME    BEST        SETS        |  |
|  +--------------------------------------+  |
|                                            |
|  Per exercise                              |
|  +--------------------------------------+  |
|  | 7s max hang   6 sets  TUT 0:42  14s  |  |  name · sets · TUT · best
|  | Dead hang     3 sets  TUT 1:38  38s  |  |
|  | L-sit         3 sets  TUT 2:16  52s  |  |
|  +--------------------------------------+  |
|                                            |
|  Effort                       peak 78% ▾   |
|  +--------------------------------------+  |
|  | ▓Z1▓│▓▓Z2▓▓│▓Z3▓│Z4              128 |  |
|  +--------------------------------------+  |
|                                            |
|  +--------------------------------------+  |
|  | ▶  Turn 2 clips into a reel        > |  |
|  +--------------------------------------+  |
+--------------------------------------------+
|  [        Save session        ]   Discard  |
+--------------------------------------------+

STATE C — STRENGTH (volume hero + PRs)
+--------------------------------------------+
|  < Keep going    Recap        [↑ Share]    |
+--------------------------------------------+
|                  ( ✦ )  seal               |
|                  New PR!                    |
|        Strength · Tue Jun 18 · 47m         |
|  +--------------------------------------+  |
|  | 4,820 kg      18         2 PRs       |  |  unit sticky (kg/lb)
|  |  VOLUME      SETS                    |  |
|  +--------------------------------------+  |
|                                            |
|  Personal records                          |
|  +--------------------------------------+  |
|  | ⊕  Weighted pull-up    +20 kg × 5    |  |  trophy glyph, one per PR'd
|  | ⊕  Front lever row      32 kg × 8    |  |  exercise
|  +--------------------------------------+  |
|                                            |
|  Per exercise                              |
|  +--------------------------------------+  |
|  | Pull-up        4 sets    1,180 kg    |  |
|  | Bench          5 sets    2,000 kg    |  |
|  | Row            9 sets    1,640 kg    |  |
|  +--------------------------------------+  |
|   (Effort card omitted — no HR recorded)   |
+--------------------------------------------+
|  [        Save session        ]   Discard  |
+--------------------------------------------+

STATE D — EMPTY / nothing logged (no summary, no save)
+--------------------------------------------+
|  < Keep going    Recap                     |  no Share (nothing to share)
+--------------------------------------------+
|                                            |
|                  ( ~ )  seal               |  neutral, no bounce
|             Nothing logged yet             |
|     Add a climb or a set to build a        |
|              recap of your day.            |
|                                            |
|        [   Back to session   ]             |  primary — returns to canvas
|         Discard empty session              |  no dialog — nothing to lose
|                                            |
+--------------------------------------------+

NOTE: body is a ScrollView; hero + bottom action bar are pinned. At AX5 Dynamic
Type the hero strip's 3 cells reflow to stacked rows and chips wrap, never clip.
~~~

**Interactions**

- Arrive: tapping Finish in the command bar transitions the cover IN-PLACE to this recap (showingSummary = true, no new sheet). Milestones are computed ONCE against prior history at finishTapped (FreeformSummary.milestones(for:history:)); the seal bounces once and, if non-empty, CelebrationBurst plays with a success haptic. Under Reduce Motion the haptic still fires and confetti is suppressed.
- Empty path: if session.completedSetCount == 0, Finish skips the recap entirely and exits (matching today's finishTapped guard) — OR, if reached via an explicit 'review' entry, shows STATE D. Empty STATE D 'Back to session' returns to the canvas; 'Discard empty session' drops the lazy shell with NO dialog.
- Tap 'Keep going' (nav leading) -> instantly returns to the live session canvas, session still open, zero data loss — non-destructive, no confirm dialog (showingSummary = false).
- Tap Share glyph -> ShareLink renders the hero strip + pyramid (climbing) or per-exercise card (timed/strength) to an image for Stories/Messages. Disabled/hidden in the empty state.
- Tap a section header chevron (Effort, Timeline) -> expands that section's detail inline (zone breakdown, full timeline); layout pushes down within the ScrollView. Pyramid micro-stats are always visible (one line).
- Tap 'Show' on Timeline -> expands from the top 4 climbs to the full chronological list; each row tappable to scrub to that climb's clips ONLY when media exists for it.
- Tap the Studio CTA card -> opens the shared Studio editor scoped to the whole session (StudioEntry.resolveProject(for:media:context:)); back returns to the recap. Card absent when no clips.
- Tap 'Save session' (Coral) -> stamps endedAt, persists, dismisses the cover to Home with the new session card; brief success haptic. (This is today's 'Done' path, renamed for clarity; keep a 'View detail' route reachable via the saved Home card rather than a third bottom button.)
- Tap 'Discard' -> the ONLY confirmation dialog on the surface (destructive, irreversible): 'Discard this session?' with Discard / Keep going (mirrors today's confirmationDialog).
- Dynamic Type / accessibility: at AX sizes the hero 3-cell strip reflows to stacked rows, grade-chip rails and zone labels wrap rather than truncate, and the pinned bottom bar keeps both actions reachable. VoiceOver reads the hero as one grouped element ('8 sends, hardest V5, 42 minutes on the wall'); the ZoneBar exposes a text summary ('12 minutes in zone 4 and above, peak 142').
- Long-press the hero strip -> quick ShareLink of just the headline stat (fast-follow, not v1).

**Data captured**

- dominant kind -> FreeformSummary.dominant(for:) over SessionExercise.kind (repsWeight | duration | climbAttempt); .none drives the empty STATE D
- duration -> WorkoutSession.duration (endedAt − startedAt); shown as the subtitle '47m' / '1h 02m'
- sets -> WorkoutSession.completedSetCount
- climbing hero: sends -> FreeformSummary.sendCount; hardest -> KilterSessionStats.hardestSendGrade; on-the-wall -> Σ KilterSessionStats.TimelineItem.timeOnClimb — BUT timeOnClimb is nil unless each climb has SetLog startedAt/endedAt, so the 3rd hero cell falls back to totalClimbs ('Climbs') when no per-climb timing exists
- grade pyramid -> KilterSessionStats.pyramid [GradeCount{gradeLabel, difficulty, sends}] over SetLog.climbGradeLabel + climbStatusRaw (SetMeasure.isSend). NOTE: KilterSessionStats currently consumes KilterLogEntry, not freeform SetLog — wiring it to freeform is real adapter work, not 1:1 reuse, and is the load-bearing gap
- sends/hr -> KilterSessionStats.sendsPerHour (suppress when duration is implausibly small); median -> KilterSessionStats.medianTimeOnClimb (nil ⇒ drop the clause); tries -> KilterSessionStats.totalAttempts (Σ SetLog attempts / attemptTimestamps[])
- timeline -> KilterSessionStats.timeline [TimelineItem{climbName, gradeLabel, status, attempts, timeOnClimb, restBefore}]; timeOnClimb nil renders '—'
- timed hero: hold time -> FreeformSummary.holdTimeSeconds (Σ SetLog.durationSec); best -> max SetLog.durationSec; sets -> count
- timed per-exercise -> grouped by SessionExercise name/exerciseId: set count, TUT (Σ durationSec), longest durationSec
- strength hero: volume -> WorkoutMath.sessionVolumeKg + WorkoutMath.formatVolume(kg:unit:) with sticky unit; sets; PR-count (cell shown only when >0)
- strength PRs -> FreeformSummary.milestones .personalRecord(exerciseId, bestKg, reps) via WorkoutMath.topWeightedSet vs prior history; rendered with the sticky unit
- milestones -> FreeformSummary.milestones(for:history:) -> .firstSend(grade) (KilterMilestones.isFirstSend vs prior sends) | .personalRecord; FreeformSummary.milestoneHeadline for copy. history MUST be prior COMPLETED sessions (live session excluded by completedAt == nil)
- HR recap -> session.hrSeries -> WorkoutHRStats zones (Z1–Z5), redlineSeconds, maxBpm; peak %HRR -> KilterSessionStats.sessionPeakHRR; recovery -> TimelineItem.hrRecovery60. ENTIRE EffortCard omitted when hrSeries is empty OR no max-HR bound exists (peakHRR/zones uncomputable)
- media count -> session media for the Studio CTA; StudioProject via StudioEntry.resolveProject(for:media:context:); card hidden when count == 0

**Live stats**

- This is the END surface, but every figure shown is the same monotonic stat that accrued LIVE during the session (KilterSessionStats recomputed on each log event), so the recap is the final frame of the live HUD — no new math, no drift between the live command-bar hero and the summary hero
- Sends counter / hardest-send chip / grade pyramid all match what the climber watched climb during the session (the live-accrue principle)
- Hold-time / best-hang and Volume / set-count likewise mirror the running command-bar hero
- Milestones already fired inline at the logging moment; the summary re-STATES the session's bests rather than re-detecting them, so 'First V5!' here is consistent with the burst seen mid-session — milestones are computed once at Finish and passed in, not recomputed on every render
- Honest caveat: KilterSessionStats accrues live in the KILTER flow today; making the FREEFORM command-bar hero accrue the same way is a prerequisite for the 'final frame' claim to hold for Quick Sessions — until that wiring lands, the recap computes these once at Finish

**Rationale.** ADVERSARIAL FINDINGS, then the fix. (1) GROUND-TRUTH DRIFT: the prior schema claimed ZoneBar is 'reused' — it does NOT exist in the codebase (grep found zero hits); only WorkoutHRStats exists. ZoneBar is NET-NEW and I now mark it so, so an implementer doesn't go hunting for a phantom. (2) The prior schema invented 'Save session'/'Discard' as if they were the screen's only actions and DROPPED the real 'View detail' path; the actual doneScreen has Done / View detail / Discard and tints the seal/CTA with SnappetColor.workout (ember #F2761E), not Pulse Coral. I keep Coral for the SAVE primary (Pulse 'one coral CTA per sheet' rule) but tint the seal/headline ember (climbing leans Kilter amber), matching the shipped palette, and fold 'View detail' into the saved Home card instead of a third bottom button — keeping the bottom thumb zone to exactly two actions. (3) DATA-MODEL MISMATCH (the big one): KilterSessionStats is fed by KilterLogEntry/ClimbEffort, NOT freeform SetLog, and timeOnClimb / peakHRR / medianTimeOnClimb / hrRecovery60 are nil unless per-climb startedAt AND a max-HR bound exist. The prior wireframe showed 'On the wall 42m', 'median 2:10', and a full Effort card as if always present — that is the common-case LIE. I add STATE A′ (no HR, no per-climb timing) where the 3rd hero cell DOWNGRADES to 'Climbs', the median clause and Effort card DISAPPEAR, and timeline time reads '—'. This is the single most important correction: the default Quick-Session climb has no stopwatch, so untimed is the COMMON path, not an edge case. (4) EDGE CASES the prior missed: single attempt (tries· renders '1·'), 2-hour session (duration formats 'Nh MMm'), strength with zero PRs (hero collapses to 2 cells, PRCard hidden), no clips (Studio CTA hidden), and the empty state correctly drops Share + Save. (5) ACCESSIBILITY: prior schema was silent on Dynamic Type for a 3-cell tabular strip (clips at AX sizes) and on VoiceOver for a stacked ZoneBar; I specify reflow-to-stacked, wrapping chips, a grouped VoiceOver hero label, and a text summary for the zone bar — plus Reduce Motion keeps the haptic and drops confetti. (6) ONE-HANDEDNESS: the body is now an explicit ScrollView with hero + action bar PINNED, so Save/Discard stay in the bottom thumb zone no matter how long the timeline is (the prior 'all in one column' layout would push Save off-screen on a long climbing session). DESIGN PRINCIPLES PRESERVED: single hero + thin strip + peek-to-expand (Zwift/Apple/WHOOP) via the capped 3-cell strip and expandable Effort/Timeline; the grade pyramid as the signature climbing chart (KAYA/Bould) anchoring State A; milestone celebration only on genuine history-derived bests fired once, RM-gated (Hevy/Apple/Asana); color-and-shape zone feedback as ONE cool→warm bar not five readouts, whole-card-hidden when no HR (Garmin/Zwift); card-based progressive disclosure with rolled-up timeline rows (KAYA/Bould/Hevy); instant action + Undo with the ONLY dialog on irreversible Discard (Strong/Streaks); teach-the-loop empty state (NN/G). Net: ~1:1 reuse of FreeformSummary + WorkoutMath + CelebrationBurst, REAL adapter work to feed KilterSessionStats from freeform SetLog, and one net-new ZoneBar — re-laid-out from a flat 3-stat screen into a scrollable, degradation-honest, type-adaptive recap.

**Reuses (existing Snappet):** `FreeformSummary (dominant, stats, sendCount, holdTimeSeconds, milestones, milestoneHeadline) — the type-adaptive headline + milestone engine, used as-is (already pure, already unit-tested)`, `CelebrationBurstView / .celebrates(on:) — milestone confetti + success haptic, Reduce-Motion gated (already wired in doneScreen via celebrationTrigger)`, `WorkoutMath.sessionVolumeKg / formatVolume / topWeightedSet — strength volume + PR detection, used as-is`, `KilterMilestones.isFirstSend + SetMeasure.isSend / formatDuration / summary — first-send decision + value formatting for hero/timeline/per-exercise rows`, `WorkoutHRStats (Z1–Z5 zones, redlineSeconds, maxBpm) + HREffortBadge + KilterSessionStats.sessionPeakHRR / TimelineItem.hrRecovery60 — the DATA behind the Effort card (note: the ZoneBar VIEW itself is net-new; only the stats are reused)`, `Swift Charts BarMark pyramid layout — adapted from KilterHistoryView.pyramidSection / KilterSessionDetailView (the existing Kilter pyramid render)`, `StudioEntry.resolveProject + StudioEditorView / ReelView — the Studio reel path scoped to the session, used as-is for the Studio CTA`, `Snappet Pulse system: .snappetCard() / .snappetTile(), Pulse Coral (SnappetColor.brand) for the Save CTA, SnappetColor.workout ember for the seal/headline, color-banded grade chips, SF-Rounded tabular digits, 4pt grid, .symbolEffect(.bounce), success haptic`, `The in-cover done-screen scaffold from FreeformPlayerView.doneScreen (showingSummary / showingDiscard state, Keep going leading button, statCell, finishTapped's compute-milestones-against-history-then-show flow, the Discard confirmationDialog) — RE-LAID-OUT into the layered recap, not rebuilt`, `NEEDS NEW WORK (flagged honestly, NOT existing reuse): (a) a ZoneBar SwiftUI view — does not exist today; (b) an adapter feeding KilterSessionStats.make from freeform SetLog (today it consumes KilterLogEntry/ClimbEffort); (c) ShareLink image rendering of the hero/pyramid; (d) the scrollable pinned-hero/pinned-action-bar layout replacing the centered Spacer column`

---

