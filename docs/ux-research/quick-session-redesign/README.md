# Quick Session UX Redesign — Research & Wireframes

> **Snappet Mobile** · focus: **climbing + timed exercises** (covering all workout types) · 2026-06-18
>
> Produced by a 38-agent deep-research + design workflow: fan-out web research across climbing / strength / timed / live-stats / visual angles → adversarial fact-check (fabricated citations were detected and removed) → synthesized pattern library → 12 critiqued wireframe surfaces → end-to-end flow map. Every recommendation is mapped onto the **real** Snappet code (`FreeformPlayerView`, `KilterLogEntry`, `KilterSessionStats`, `StopwatchView`, the Glass-HUD kit).

### This folder

| File | What it is |
|------|------------|
| **README.md** (this file) | The design doc — problem, research-backed principles, per-type recommendations, the redesigned flow, data-model/implementation notes, phasing. |
| **[wireframes.html](./wireframes.html)** | **Open in a browser** — real-looking, styled iPhone mockups of the key climbing + timed flows. The visual deliverable. |
| **[wireframes.md](./wireframes.md)** | All 12 wireframe surfaces as detailed ASCII mockups (multiple states + edge cases) with interactions, captured data, and rationale. |
| **[research-appendix.md](./research-appendix.md)** | Full research provenance — 6 angles, every pattern's verdict (`confirmed`/`plausible`/`refuted`), and the claims that were thrown out. |

---

## TL;DR

**The problem.** Today, tapping *Climbing* in a Quick Session drops a single generic `climbAttempt` row, and every attempt is an undifferentiated flat entry (grade + outcome + attempts + an optional timer). There is **no named climb/route**, no climb **type** (boulder / top-rope / lead / sport), no scale awareness, and **no way to group three tries on the same V4 project**. *Timed* is even thinner — an unnamed "Timed exercise" row with no catalog and no way to name/reuse a hold like *7s hang*.

**The fix — one move above all others: an *entity-then-attempt* hierarchy.** You first create a named, typed, graded **parent** (a climb/route, or a named timed exercise), then log efforts **underneath** it. The parent owns identity (name / type / grade / location); children own outcome / timing / count. This single change unlocks grouping, last-time prefill, per-thing stats, and the grade pyramid — and it is **~1:1 reuse** of the `KilterLogEntry` / `KilterSessionStats` shapes that already exist for the Kilter board flow but were never wired into freeform.

**Everything else falls out of that:** the expensive form (type/name/grade) happens **once**; afterwards each attempt is a single gesture; a *timed* attempt promotes the existing count-up `StopwatchView` out of the cramped sheet into a full-screen FOCUS cover with a giant Stop button; live `KilterSessionStats` (sends · hardest · pyramid · sends/hr) become an ambient ribbon that builds as you climb; and milestones (*First V4!*) fire at the logging moment via `CelebrationBurst`.

> **Net-new work** is small and isolable: a climb *parent* in the freeform model, route **types + YDS/French scales** (the one genuine modeling gap), a persisted `TimedExerciseCatalog`, and a structured interval runner. See [§7](#7-data-model--implementation-notes).

---

## 1. Design principles (research-backed)

Distilled and de-duplicated from verified research across climbing logbooks (KAYA, Stokt, Kilter, TopLogger, 8a.nu/Vertical-Life, Bould), strength trackers (Strong, Hevy, Fitbod), timed/hangboard apps (Crimpd, Tindeq, Seconds Pro, HangTight), and live-stats/visual sources (WHOOP, Strava, Zwift, Garmin, Apple Fitness, David Smith's *Fresh Workouts*). Full provenance in [research-appendix.md](./research-appendix.md).

### 1. Entity-then-attempt hierarchy (the spine of the redesign)

Never log a bare attempt. The user first creates a named, typed, graded PARENT (a climb/route, or a named timed exercise like '7s hang'), then logs efforts UNDERNEATH it. Parent owns identity (name/type/grade/location); children own outcome/timing/count. A flat list of attempt rows blocks prefill, grouping, per-thing stats, and the grade pyramid — fix this first. For Snappet: promote the existing KilterLogEntry shape (climbUUID, climbName, gradeLabel, status, attempts, attemptTimestamps[], startedAt/endedAt, note) out of the Kilter-only path into a freeform SetKind.climbAttempt parent; do the identical thing for timed exercises. This is the single highest-leverage move and is ~1:1 reuse, not new modeling.

*Sources: KAYA, Stokt, Kilter, TopLogger, 8a.nu/Vertical-Life, Bould, Strong, Hevy (universal across set-loggers and climbing logbooks)*

### 2. Session is auto-started, dated, lazy on first log

Do NOT add a setup wizard at session start. The session is a grow-as-you-go dated shell created on the first log of the day; tapping a workout type goes straight to adding/picking the first ENTITY inside the already-running session. Snappet's FreeformPlayerView already IS this container — keep it, fix only the layer below.

*Sources: KAYA ('once you log your first climb of the day, KAYA creates a new logbook session'), Kilter day-view, TopLogger / Vertical-Life date+gym grouping*

### 3. Default action is CONFIRM, not type (last-time prefill)

Treat logging as high-frequency data entry: the dominant per-effort interaction must collapse to ONE confirm tap. Pre-fill grade, outcome, and count from the last entry of the same entity; show a faint 'last time: V4 · sent · 3 tries' line on each card; only type when something changed. For timed exercises prefill the last hold duration ('7s hang' defaults to 7s). Use tap-count as the design metric — re-logging another go of the same outcome = 1 tap.

*Sources: Strong (auto-populates previous weights), Hevy (PREVIOUS column + commit-on-checkmark), Fitbod, Setgraph*

### 4. One-tap / one-swipe attempt increment — the expensive form happens once

The costly form (type/name/grade) happens ONCE at entity creation. After that, each attempt and the closing send are a single gesture: a big '+1 attempt' footer tap (haptic, appends an attemptTimestamp) and a 'Send' action with flash/sent/project — no re-opened sheet. The current flat 'Add attempt' sheet that pops and dismisses per attempt is the antipattern. Swipe-to-log on the climb row is a natural secondary idiom.

*Sources: KAYA (swipe-left=attempt / swipe-right=send), Stokt (Quick Attempt increments by one), Bould, Strong*

### 5. TYPE is chosen first and drives the grade SCALE and status set

Climb TYPE (boulder / top-rope / lead / sport) is the FIRST field, rendered as a segmented control atop the 'Add a climb' sheet, because everything downstream depends on it. Type switches the grade scale (boulder → Font/V, matching today's '6a/V3' labels; TR/lead/sport → YDS/French — net-new modeling, introduce it here) and the available send statuses. Persist climbType + gradeScale on the climb. This is the biggest modeling gap.

*Sources: Kilter (V-scale/Font toggle), TopLogger (toprope/lead flag), Vertical-Life (3-button ascent style first), 8a.nu, Mountain Project*

### 6. Grade entry is a constrained, scale-aware discrete picker — never freetext

Grades are an ordered discrete set per scale; present a horizontal wheel/segmented picker showing valid rungs (V0..V17, Font 4..9a, 5.6..5.15d) plus a 'recent grades' chip rail for one-tap reuse. Store the ordinal/float so pyramid + hardest-send math is exact. Labeled discrete controls beat freetext and beat unlabeled sliders. (Do NOT cite Mountain Project grade-slider research — that evidence was fabricated; the principle still stands.)

*Sources: Kilter V/Font selector, Vertical-Life, TopLogger, KAYA, Bould; general UX principle (labeled discrete > freetext)*

### 7. Match the input control to the value's range

Steppers/segmented controls for small bounded ranges (Attempts 1-50, Outcome); a numeric keypad for unbounded values (weight); chips for short ordered sets (grade, outcome). Use Snappet's custom +/- steppers (sized to clear 44pt, NOT native UIStepper) for counts, and KeypadDoneToolbar for numbers. The bounded-vs-unbounded split keeps every field one fast gesture.

*Sources: Strong, Hevy, Setgraph, Weights; NN/G touch-target guidance*

### 8. Type-aware send-status taxonomy, coupled to attempt count

Drive the Outcome picker's options from the chosen TYPE: boulder = flash/sent/project/attempt; lead/sport adds onsight + redpoint (optionally pinkpoint) + a top-rope flag. Outcome IMPLIES count: Flash/Onsight sets attempts=1 and closes the climb; Project/Attempt keeps it open and increments the bid counter; logging Sent on an open project folds in the accumulated attemptTimestamps[]. Preserve isSend (flash|sent|onsight|redpoint = send). This prevents nonsensical states like 'Flash with 5 attempts'.

*Sources: 8a.nu/Vertical-Life (onsight/flash = first try, redpoint = after ≥1), Stokt (send pre-records prior attempts), Mountain Project, KAYA*

### 9. Single hero metric + thin always-on strip + peek-to-expand detail (layered HUD)

Elevate exactly ONE primary metric to hero size; demote everything else to a thin always-on command bar or a tap-to-expand layer. Make the hero Activity-aware: climbing → Sends (or the current climb's attempt count mid-attempt); strength → Volume; timed → total Hold time; running → Duration/distance. Command bar holds at most three elements (elapsed | HR/zone chip | hero stat) + Finish. Never stack pyramid + sends/hr + zones + recovery + calories on the always-on layer.

*Sources: Zwift (one large field + four capped), Apple Watch (dominant metric), WHOOP (Strain ring), Garmin*

### 10. Three-state progressive disclosure: PEEK → FOCUS → auto-COLLAPSE

Browsing/adding = PEEK (HUD minimal). Starting a timed attempt = FOCUS (full-cover live timer, everything else recedes, session stats hidden). Stop = COLLAPSE (capture duration, show outcome picker, auto-return to the session canvas). Untimed attempts skip FOCUS entirely (single tap). Mirror Strava Live Segments' auto-return-on-finish.

*Sources: Strava Live Segments (peek banner / focus comparison / auto-return), Zwift Hide Display*

### 11. Live, accruing session stats — watch the number climb as you contribute

Recompute a small set of derived, monotonically-growing stats on EVERY log event and surface them live: a running sends/attempts counter, hardest-send chip, and a live grade pyramid that accrues. KilterSessionStats.compute is pure and already produces totalClimbs/sends/projects/totalAttempts/hardestSendGrade/sendsPerHour/pyramid[]/timeline[]/medianTimeOnClimb — wire it to the freeform session. Show ONE stat as the context hero; reveal the rest only on expand. (Live recompute is Snappet's design goal — some source apps show these only at session end.)

*Sources: KAYA (build ascent pyramid, live intensity), WHOOP (Strain builds live), Zwift (zone bars accumulate), Apple rings; Snappet's own KilterSessionStats*

### 12. Automatic milestone celebration timed to the LOGGING moment

The first fire of each milestone happens at the instant the outcome is picked, not just end-of-session. Derive milestones live from history (not just session): new hardest send → 'New hardest send! V5'; first-ever send of a grade → 'First V4!'; flash → 'Flashed!'; PR hold time for timed. Fire CelebrationBurst inline on the climb row with a success haptic, auto-dismissing, gated behind reduce-motion and a mute setting, ONLY on genuine bests. Compute against full history so 'first V4 ever' reads bigger than a session best.

*Sources: Hevy Live PR (5 record types, set-completion timing, genuine-bests-only, off-switch), Apple trophy-case-at-milestone, Asana unicorn (fires sparingly)*

### 13. Color-and-shape encoded zone feedback (read without reading numbers)

Real-time HR/zone feedback should be pre-attentive: tint the HR chip's dot/background with the Z1-Z5 zone color (cool→warm); render time-in-zone as a stacked color bar in the expanded panel (Garmin/Zwift geometry), not five separate readouts. Frame the recovery ring as 'buffer/headroom remaining' (Gentler Streak) not raw %. Use Workout ember-orange / Kilter amber for warm zones to stay on-brand.

*Sources: Garmin In-Zone (whole-screen color + time-in-zone bar), Zwift Power Zone Bar, Apple rings, Gentler Streak readiness buffer*

### 14. Location captured once per session, inherited by every entity

GYM/location lives at the session level (or the first climb), defaulted onto subsequent climbs, with a 'recent gyms' quick-pick — never re-entered per attempt. Since Snappet is freeform with no curated catalog, allow free text + recents (KAYA-style) rather than a gym-network gate (TopLogger). 8a.nu/Vertical-Life is the cautionary case: route/crag creation is website-only, so don't bottleneck logging behind a catalog.

*Sources: TopLogger, KAYA, Vertical-Life/8a.nu (curated-catalog tension), Kilter*

### 15. Two timer mentalities, never blurred: count-UP (open effort) vs count-DOWN (structured target)

Count-UP (draining→filling ring) is for open single efforts — timing one climbing attempt, a max dead-hang to failure, AMRAP. Count-DOWN (draining ring + terminal beep/haptic) is for targeted work — a fixed 10s hang, a 7:3 repeater work phase. Make the mode unambiguous in the Glass HUD via ring direction + SF Rounded tabular digits. StopwatchView already does both; a TimedExerciseSpec.mode drives which style instantiates.

*Sources: Box Timer (codifies count-up for AMRAP/For-Time, countdown for timed, interval for HIIT/Tabata/EMOM), Seconds Pro, SmartWOD*

### 16. Catalog-select vs create-new as one low-friction entry decision

Adding a timed exercise leads with a searchable list: 'Create new' pinned at top, then saved exercises (seed '7s max hang', 'Dead hang', 'Plank', 'L-sit', 'Repeaters'), recents first. Selecting creates a parent card; 'Create new' captures NAME (+ optional default work/rest) and PERSISTS for reuse as a small SwiftData catalog model. Ensure custom entries flow through the stats aggregation so they don't become stat dead-ends (Fitbod's documented custom-exercise gap is the antipattern). For climbing the 'catalog' is lighter: recents of climbs you've logged + 'Add new climb'.

*Sources: Crimpd (75+ free / 200+ Crimpd+ workouts + custom builder), hang!, HangTight, Seconds Pro; Fitbod custom-exercise stat-gap caveat*

### 17. Friction-light bottom-sheet quick-entry with detents

Build 'Add a climb' and 'Add a timed exercise' as medium-detent bottom sheets (UISheetPresentationController), NOT full-screen covers. Detent 1 = essentials (TYPE segmented + NAME + GRADE) with the Pulse Coral CTA; pull-to-large reveals optional GYM, scale toggle, note. Pre-fill smart defaults (last type, last gym, session's prevailing scale). Keep rows on the 4pt grid so each clears 44pt. Capture-now, enrich-later.

*Sources: Apple iOS sheets, Strong, Strava, MyFitnessPal Quick Add, TopLogger; NN/G ≥44pt touch targets*

### 18. Custom timed builder uses protocol presets — never assemble from scratch

Define a TimedExerciseSpec in ios/App/Shared (phone/watch/widget agree): workSec, restSec, reps, sets, restBetweenSetsSec, leadInSec, mode (.repeaters/.tabata/.emom/.maxHang/.openCountUp). Offer protocol-preset chips (Repeaters 7:3×6, Max Hang 10s, Tabata 20:10×8, EMOM, Density) that pre-fill fields, with a live 'Total: 4:00 · 6 reps × 3 sets' readout. NEVER silently snap a user's entered value to a 'preferred' setting (Tindeq's verified failure: it rewrote a 10s timer to 20s and was panned) — surface a gentle hint instead.

*Sources: HangTight, hang!, Seconds Pro (compound timers), Crimpd; Tindeq (verified cautionary tale)*

### 19. 3-2-1 lead-in + distinct per-phase audio & haptic cues (eyes-off training)

Open every structured timer with a configurable lead-in (default 3s) — this both gets you into position AND warms up the HR/HealthKit pipeline. Layer DISTINCT cues: final-3s countdown beeps, different tones at work-start vs rest-start, and on watchOS distinct WKHapticType patterns per phase plus a wrist-tap at interval end. Offer sound / haptic / silent modes (loud gym vs quiet home). This is what makes a hangboard repeater usable, since you can't watch the screen mid-hang.

*Sources: Intervals Pro (3s prep 'allows Apple Health to warm up' + wrist-tap at interval end), Seconds Pro (TTS advance-warning), Tap Timer, HangTight*

### 20. Structured multi-interval runner = a now/next/progress instrument

For repeater/Tabata/EMOM runs build a dedicated full-cover (distinct from the freeform command bar): large phase label (HANG/REST) + draining count-down in tabular digits, a 'Set 2/3 · Rep 3/6' counter, a NEXT-phase preview chip, and a draining progress ring. Color telegraphs the phase BEFORE the beep — Workout ember-orange #F2761E for WORK, a muted surface tone for REST — so the climber reads it peripherally.

*Sources: Seconds Pro ('know what's coming before the beep'), Intervals Pro, SmartWOD, Box Timer, Crimpd*

### 21. The timer measurement IS the log (near-zero-tap result capture)

When a timed effort's count ends or Stop is tapped, auto-create the SetLog pre-filled with the measured hold time / completed reps·sets — one-tap confirm, no manual min/sec entry (replacing today's manual fallback as the PRIMARY path). Offer an optional RPE chip (1-10, à la hang!) and a note as a fast secondary layer. For climbing, the timed-attempt screen's measured duration flows straight into attemptTimestamps[]/startedAt-endedAt with zero re-entry.

*Sources: hang! (log RPE), Crimpd (on-finish log, name+completion%+notes history), Tindeq (time-under-tension), Seconds Pro*

### 22. Checkmark commits the effort AND auto-starts a remembered rest timer

Completing an attempt/set in one tap should optionally auto-start a rest countdown shown in the command bar next to elapsed + HR (StopwatchView count-down, wall-clock backed, success haptic). Make rest duration a remembered per-climb (or per-climb-type) preset — longer for a hard boulder project, shorter for laps on an easy top-rope. This is net-new for Snappet's freeform flow and directly reuses StopwatchView + the command bar.

*Sources: Hevy (checkmark completes set + triggers rest in one tap), Strong (auto-starts per-exercise rest)*

### 23. One-handed, bottom-thumb-zone controls (the body is busy)

~75% of users rely on their thumb and the comfortable zone is the bottom third. Dock the only two mid-session actions — Start/Stop attempt and Finish — in the bottom thumb zone with oversized, chalky-finger-forgiving hit areas; put the 'Add' action there too (bottom-anchored button or an expanding FAB fanning into 'Add climb / Add timed exercise'). The live-timer Stop button is full-width, bottom-center, ≥64pt. Everything load-affecting stays below the screen midline.

*Sources: Hoober thumb-zone research (~75% rely on thumb), Material FAB, iOS 26 shrinking tab bars, David Smith Fresh Workouts, Strong*

### 24. Instant action + Undo, not confirm-everything

Act immediately and offer Undo; reserve confirmation dialogs only for destructive, hard-to-reverse actions (discarding the whole session). Log and delete should be instant with an Undo affordance. Overused confirmations habituate users into dismissing them. Edit single values inline (grade chip, counter); use a sheet only for creating a new climb/timer.

*Sources: Strong, Streaks, general UX (instant + Undo > modal confirms)*

### 25. Card-based progressive disclosure with at-a-glance rolled-up state

Render each parent as a .snappetCard() whose COLLAPSED header shows type icon + NAME + color-banded grade chip + status badge + 'N attempts' + total time-on-climb — so a session scan reads as a list of outcomes without expanding. Tap expands inline (pushing layout down) to the attempt list with per-attempt outcome + duration; 'Add attempt' sits at the card footer. This directly fixes 'you cannot group 3 tries on the same V4 project' — the three tries are three children of one card.

*Sources: KAYA, Bould, Strava strength log, Hevy; expandable-card responsive UX*

### 26. Anti-clutter discipline: configurable but CAPPED, hide-by-default detail

Don't surface all of KilterSessionStats at once. Cap any configurable hero/secondary choice (Zwift caps fields at four; it deliberately REMOVED route/level-progress bars). During a timed attempt hide session stats entirely (FOCUS). Keep celebration copy warm and specific ('First V4!') not hype-spammy, and mutable (Gentler Streak restraint). Calmer feedback can motivate more than a maximal dashboard.

*Sources: Zwift (removed bars, four-field cap), Garmin (toggleable screens), Gentler Streak (restraint), Strava*

### 27. Sticky units & scales — pick once, never per attempt

Remember kg/lb for weight and the GRADE SCALE (V/Font/YDS/French) per climb type so the user picks scale once. Provide a small plate/added-load calculator reachable WITHOUT leaving the input (relevant to strength + weighted hangs/pull-ups, common in climbing training). Tabular-digit Glass HUD styling already exists for the numeric display.

*Sources: Strong (plate calculator in every working set), Hevy (Calculator button + sticky KG/LBS)*

### 28. Teach-the-loop empty states (no hard stats — the qualitative claim only)

A fresh session should TEACH the new hierarchy instead of showing a void: a friendly prompt + two big primary affordances ('Add your first climb' / 'Add a timed exercise') with a one-line subtitle explaining attempts log underneath. A blank container reduces confidence and slows the first action (NN/G). Do NOT cite the fabricated '~50% confusion reduction' or 'Gartner 75% micro-interactions' figures — the qualitative advice stands without them.

*Sources: NN/G empty-state guidance (blank container reduces confidence); Asana/Apple reserved-celebration motion*

### 29. Voice / Watch fast-capture as a fast-follow

Speech is ~3× faster than typing (Stanford) — offer a voice affordance on the command bar and a one-tap attempt/send on the watchOS companion so the climber logs without unlocking the phone (directly answering WHOOP's no-wrist-display gap). Keep the screen awake during an active session (Hevy 'Keep Awake') so you never re-unlock per attempt. Fast-follow, not v1.

*Sources: Stanford speech-vs-typing study, MyFitnessPal Voice Log, Hevy Keep-Awake, WHOOP (no wrist display = cautionary)*

---

## 2. Per-workout-type recommendations

### Climbing

- TAP 'Climbing' → straight into 'Add a climb' (no setup wizard). Medium-detent bottom sheet, Detent 1 = TYPE segmented (boulder / top-rope / lead / sport) + NAME + scale-aware GRADE picker; pull-to-large reveals optional GYM (session-inherited, recents quick-pick), scale toggle, note. Pulse Coral CTA.
- TYPE drives everything: boulder → Font/V grade scale (reuse Kilter '6a/V3' labels) + flash/sent/project/attempt; TR/lead/sport → YDS/French scale (net-new modeling — introduce here) + onsight/redpoint/pinkpoint + top-rope flag.
- Each climb is a parent .snappetCard() reusing the KilterLogEntry shape (climbUUID, climbName, gradeLabel, status, attempts, attemptTimestamps[], startedAt/endedAt, note). Collapsed header: type icon + name + color-banded grade chip + status badge + 'N attempts' + total time-on-climb. Expands inline to the attempt list.
- Attempt logging under a climb = two big footer taps: '+1 attempt' (haptic, appends attemptTimestamp) and 'Log outcome' (flash/sent/project). Outcome couples to count: Flash → attempts=1 + closes climb; Project/Attempt → stays open; Sent on an open project folds in accumulated attemptTimestamps[]. Reserve a sheet only for climb creation.
- TIMED attempt → full-cover FOCUS screen (reuse StopwatchView count-up + Glass HUD #111928@72%): climb name + grade chip + attempt # up top, giant tabular-digit count-up center, full-width ≥64pt circular STOP bottom-center, live-HR chip kept visible. On Stop → capture duration into attemptTimestamps[]/startedAt-endedAt → outcome picker → auto-collapse to canvas. UNTIMED attempts skip this entirely (single tap).
- Wire KilterSessionStats into the freeform session — recompute live on every attempt. Hero stat = Sends (or hardestSendGrade once a hard send lands). Live grade-pyramid mini-chart + sends/projects counter + sends-per-hour live in the expand layer; full pyramid + timeline in the completion summary.
- Fire CelebrationBurst inline on the climb row at the LOGGING moment for genuine, history-derived milestones: new hardest send, first-ever send of a grade ('First V4!'), flash. Success haptic, auto-dismiss, reduce-motion + mute gated.
- Add an optional remembered rest-timer per climb/type, auto-started on attempt completion, shown in the command bar — longer default for a hard project, shorter for easy top-rope laps.
- Grade chip rail of recent grades for one-tap reuse; prefill grade + sensible default outcome when re-adding the same climb so another go is a single confirm tap.
- LOWER PRIORITY: a 'circuit/laps' group wrapper (4×4 / ARC) that suppresses the auto-rest-timer WITHIN the group and starts it only after the last climb.

### Timed

- TAP 'Timed' → sheet whose FIRST control is a searchable list: 'Create new' pinned at top, then a seeded catalog ('7s max hang', 'Dead hang', 'Plank', 'L-sit', 'Repeaters', 'Max hang 10s', 'Wall sit'), recents/favorites first. Persist as a small SwiftData TimedExerciseCatalog so authored exercises survive across sessions.
- Selecting a catalog entry creates a parent timed-exercise card (mirrors the climb card); 'Create new' captures NAME + optional default work/rest and saves it. Timed SETS accrue under the parent — replacing today's flat 'Timed exercise' + 'Add set'.
- Define a shared TimedExerciseSpec in ios/App/Shared (phone/watch/widget): workSec, restSec, reps, sets, restBetweenSetsSec, leadInSec, mode (.repeaters/.tabata/.emom/.maxHang/.openCountUp). Custom builder uses the existing custom +/- steppers + protocol-preset chips that pre-fill fields, with a live 'Total: 4:00 · 6 reps × 3 sets' readout. NEVER silently snap an entered value (Tindeq antipattern).
- Mode picks the timer mentality: .maxHang/.openCountUp → count-UP StopwatchView (fill ring); .repeaters/.tabata/.emom → structured multi-interval runner full-cover with count-DOWN draining ring.
- Structured runner = now/next/progress instrument: large HANG/REST phase label + draining count-down (tabular digits), 'Set 2/3 · Rep 3/6' counter, NEXT-phase preview chip, WORK = ember-orange / REST = muted surface for peripheral reading.
- 3-2-1 lead-in (default leadInSec=3) before the first interval (also warms HR/HealthKit). Layer cues: final-3s beeps, distinct work-start vs rest-start tones, watchOS per-phase WKHapticType + wrist-tap at interval end; sound / haptic / silent toggle.
- The timer IS the log: on Stop/end auto-create the duration SetLog pre-filled with measured hold time / completed reps·sets (one-tap confirm, no manual min/sec). Optional RPE chip (1-10) + note as a fast secondary layer.
- Live stats strip: 'Sets 4 · TUT 1:10 · best 12s', recompute incrementally; completion summary 'Hold time' headline + PR cards (longest dead hang) from auto-computed totals.
- Prefill the last hold duration for a named exercise; plate/added-load calculator for weighted hangs/pull-ups with sticky kg/lb.

### Strength

- Two-level hierarchy exercise → sets (the same grammar as climb → attempts). Searchable catalog, recents-first, with inline 'Create custom exercise' that behaves like stock entries and flows through the stats aggregation (avoid Fitbod's custom-exercise stat dead-end).
- Last-time prefill so the default per-set action is a single confirm-checkmark; show a PREVIOUS column with prior weight/reps inline; type only when something changed.
- Checkmark commits the set AND auto-starts a per-exercise remembered rest timer (Strong/Hevy), shown non-blocking in the command bar with a tone/haptic at zero.
- Inline numeric entry with plate math reachable WITHOUT leaving the field; sticky kg/lb unit (pick once). Steppers for small ranges, keypad for weight.
- Hero metric = Volume; surface running volume/set count live. LOWER PRIORITY: supersets/circuits as a thin group wrapper that suppresses intra-group rest and starts it only after the last item.

### Running

- Hero metric = Duration/distance; thin always-on command bar with elapsed + HR/zone chip + Finish; peek-to-expand for splits/zones.
- Color-and-shape zone feedback: tint the HR chip dot with the Z1-Z5 zone color; stacked time-in-zone bar in the expand layer.
- Three-state HUD: minimal while running, an optional FOCUS surface for a timed segment/interval, auto-collapse on finish (Strava Live Segments model).
- Reuse the structured-interval runner + 3-2-1 lead-in + per-phase haptics for interval/track sessions; count-DOWN for work phases.
- Milestone celebration at the moment a PR/segment is beaten, reduce-motion gated.

### Dance

- Lightest-weight type: a freeform timed/open-effort session — hero metric = Duration; count-UP StopwatchView for an open routine, optional named 'routine' parent if the user wants to log multiple pieces.
- Keep the dark-first one-hero command bar + live HR/zone chip; reserve celebration for genuine milestones (longest session, streak), mutable and reduce-motion gated.
- Catalog-vs-create applies if routines become reusable named entities; otherwise default to a single open-effort timer to avoid imposing unnecessary hierarchy.

### Other

- Default to the simplest path: an open count-UP effort with Duration as the hero metric, no forced entity hierarchy — capture-now, enrich-later.
- Offer the generic entity-then-effort grammar (name an activity, log efforts under it) only if the user adds more than one thing, so the structure never gets in the way of a quick one-off.
- Reuse the shared command bar, StopwatchView, instant-action+Undo, and teach-the-loop empty state so 'other' feels consistent with the richer types.

---

## 3. Visual & interaction inspiration

Concrete, copyable patterns and aesthetics — all expressible in *Snappet Pulse* (Coral `#FF5A4D`, Workout ember `#F2761E`, Kilter amber `#B45309`, 4pt grid, radii sm10/md16/lg24, the Glass-HUD kit). Rendered in [wireframes.html](./wireframes.html).

- Dark-first, glassmorphic LIVE TIMER cover (David Smith's 2025 Fresh Workouts): a floating frosted-glass panel over an immersive dark base, controls arranged HORIZONTALLY at the bottom for larger targets, the most-pressed control (Stop) given circular emphasis ≥64pt bottom-center. Map directly onto StopwatchView + Snappet's Glass HUD kit (#111928@72%, white@14% hairline, SF Rounded tabular digits).
- iOS 26 Liquid/Frosted Glass for translucent dark HUD chrome — BUT honor the legibility lesson: Apple raised opacity across betas (NN/G 'Liquid Glass Is Cracked') and shipped a Clear/Tinted toggle in 26.1. Keep chrome readable: dark base, raised opacity behind digits, never thin-on-thin.
- The ASCENT/GRADE PYRAMID as the signature climbing-log chart (KAYA 'build your ascent pyramid', Bould grade pyramid + session volume): sends stacked by grade with the hardest at the apex. Render small/live in the expand layer, full-size in the completion summary — it's the highest-signal glanceable climbing visual.
- Time-in-zone stacked color bars with growing widths (Garmin In-Zone whole-screen color + bar, Zwift Power Zone Bar) — one bar, cool→warm ramp, instead of five separate readouts. Tint with Snappet's Workout ember-orange / Kilter amber for warm zones.
- Arc/ring fills for goal progress (Apple Fitness rings, three fixed colors) and the recovery 'buffer remaining' framing (Gentler Streak green-stripe + orange-heart readiness bar) — calm, restraint-first motivation over a maximal dashboard.
- Strava Live Segments peek banner with a real-time progress circle and green/red ahead-behind effort coding — the model for a timed-attempt FOCUS surface that slides in, centers the live effort, and auto-returns on finish.
- Card-based progressive disclosure (KAYA / Bould / Hevy): each parent climb a .snappetCard() with a rolled-up header (type icon + name + color-banded grade chip + status badge + attempt count) that expands inline to the attempt list — a session reads as a scannable list of outcomes.
- Now/next/progress structured-interval instrument (Seconds Pro full-background phase color + TTS advance-warning, Intervals Pro): large phase label, draining count-down, Set·Rep counter, NEXT-phase preview chip, ember-orange WORK vs muted REST telegraphing the phase before the beep.
- Pinterest/modern-fitness-UI vocabulary to lean into: large SF Rounded tabular hero numerals on a near-black surface, generous negative space, a single coral CTA per sheet, chip rails for recents (grades, gyms, exercises), color-banded grade pills, and a thin pinned bottom command bar — all already expressible in Snappet Pulse (Coral #FF5A4D, ember #F2761E, Kilter amber #B45309, 4pt grid, radii sm10/md16/lg24).
- Inline celebratory micro-motion reserved for real bests (Apple ring-close burst, Asana unicorn — fired sparingly): reuse CelebrationBurst as a small auto-dismissing overlay on the climb row, success haptic, reduce-motion gated.

---

## 4. Antipatterns to avoid

- Flat attempt rows with no parent entity — the current Snappet pain point. Logging every attempt as an undifferentiated row blocks grouping '3 tries on the same V4', prefill, per-thing stats, and the grade pyramid. The CLIMB layer that best apps separate is exactly what's missing.
- A pop-and-dismiss sheet PER attempt. Re-opening (and re-animating) a form for every bid is the opposite of one-tap logging. The expensive form happens once at entity creation; attempts after that are a single gesture.
- Free-text grade fields ('V4, 6c'). They can't power exact pyramid/hardest-send math and invite typos. Use a scale-aware discrete picker + recent-grade chips. (Note: do NOT justify this with the fabricated 'Mountain Project grade-slider research' — that citation was refuted; the principle stands on its own.)
- Silently snapping a user's entered value to a 'preferred' setting (Tindeq rewrote a 10s timer to 20s and was panned as 'too clunky to be useful'). Never override input — surface a gentle hint instead. Ship protocol-preset chips + a guided default so users don't assemble 7:3×6 from scratch.
- Flexibility without a guided default (Tindeq's custom-session builder). A powerful builder with no presets/recents is confusing; always lead with a catalog + 'Create new' and pre-filled protocol presets.
- An over-stuffed always-on HUD. Stacking pyramid + sends/hr + zones + recovery + calories on the always-on layer destroys glanceability. One hero + thin strip + peek-to-expand; cap configurable fields (Zwift caps at four and removed its route/level bars).
- Custom exercises that become stat dead-ends (Fitbod's documented gap: custom exercises don't influence recommendations). Ensure user-created climbs and timed exercises flow through the same KilterSessionStats-style aggregation as seeded ones.
- Re-entering gym/location (or units, or grade scale) per attempt. Capture once at session/first-entity level, inherit downstream, offer recents. Sticky scale/unit — pick once, never per attempt.
- Setup wizard at session start. The session is auto-started and lazy on first log; a config step before the user can log anything is friction the best logbooks deliberately avoid.
- Confirm-everything dialogs. Overused confirmations habituate users into reflexive dismissal; act instantly with Undo and reserve confirmation only for discarding the whole session.
- Blurring count-UP and count-DOWN timers. Open efforts must count up; targeted work must count down with a terminal cue. Mixing them makes the live screen ambiguous mid-hang.
- Blank/void empty states that don't teach the loop. A blank container reduces confidence and slows the first action — show the first action and explain that attempts log underneath. (Don't cite the unverifiable '~50% confusion reduction' or 'Gartner 75% micro-interactions' figures — both were refuted as fabricated/unsourced; keep only the qualitative claim.)
- Celebration spam — bursting on every logged attempt. It kills the meaning of the milestone. Fire only on genuine, history-derived bests, gated behind reduce-motion and a mute setting, with warm specific copy ('First V4!') not hype.
- Top-of-screen-only 'Add' / Stop buttons out of the bottom thumb zone. ~75% of users rely on their thumb; load-affecting actions belong below the midline with chalky-finger-forgiving hit areas. Don't bury the live-timer Stop in a nav bar.
- Modal sheets for single-value edits. Editing one grade chip or counter should be inline; reserve sheets for genuinely multi-step actions (new climb, new timer).
- Overstating one-handed framing as '75% single-thumb' (only ~49% use a true one-handed grip — 36% cradle, 10% two-thumb). The thumb-zone conclusion holds, but frame it as '~75% rely on their thumb', not '75% single-thumb'.

---

## 5. The redesigned experience

The redesign reframes the existing FreeformPlayerView ("Quick Session" internally = the routineless freeform logbook) around a climb-first / exercise-first hierarchy instead of the current flat attempt rows. Today, tapping Climbing drops a single generic SetKind.climbAttempt row and every attempt is an independent flat entry with just grade/outcome/attempts — there is no named route, no climb TYPE (boulder/top-rope/lead/sport), no scale awareness, and no way to group three tries on the same V4 project; Timed is even thinner, adding an unnamed "Timed exercise" row with no catalog. The new flow turns Quick Start into a launchpad/type chooser, then lets you ADD A CLIMB first (type · name · grade · optional gym) and log attempts UNDERNEATH that climb, so the project finally becomes one card with its attempt history rather than scattered rows. Attempts can be UNTIMED (quick outcome + attempts stepper) or TIMED, and the timed path promotes the existing count-up StopwatchView out of the cramped LogSetSheet into a full-cover FOCUS screen that shows the climb's details and a clear Stop button before you pick the outcome. Timed exercises get the same climb-like hierarchy plus a select-from-catalog/create-new dropdown (e.g. "7s hang", "Plank", "Dead hang") so reusable holds stop being retyped every session, with their own full-screen live-set FOCUS cover. Live climbing stats become ambient: a one-line stat ribbon docks just above the climb cards (sends · attempts · hardest grade · sends/hr) and taps to expand into a read-only Live-stats sheet reusing the rich KilterSessionStats shapes (pyramid, projects, median time on climb), while logging stays on the cards below. All of this rides the unchanged shared lifecycle — the docked command bar/mini-HUD (elapsed timer · HR chip with zone + recovery dot · Finish), pause/resume mirrored to the Live Activity, the peek-to-expand LiveMetricsPanel, background minimize/resume, and the ~20s clip auto-discovery that tags clips to sets and opens them in the shared Studio editor — so climbing, timed, strength, and running sessions all behave consistently. Finish lands on the type-adaptive completion summary (Duration · Sets · a dominant-kind headline: Volume / Sends / Hold time) with milestone celebrations like "First V4 send!", all derived by the pure FreeformSummary with no model migration required.

### Logical flows

#### Climbing — full flow (add climb → timed attempt → untimed attempt → 2nd climb → live stats → finish)

> Maps to current FreeformPlayerView + LogSetSheet(.climbAttempt) but reorganized climb-first. Today: tapping Climbing adds a flat SetKind.climbAttempt row named via SetMeasure.climbName and every attempt is a flat row with grade/outcome/attempts + optional per-attempt count-up stopwatch (durationSec reused). Redesign promotes the row to a named Climb card (type/name/grade/gym) with attempts logged UNDER it; the timed-attempt FOCUS cover is the StopwatchView(.countUp) Stop capture lifted out of the sheet into a full-cover. Climbing headline = FreeformSummary.sendCount; live stats reuse KilterSessionStats shapes (sends, projects, attempts, pyramid, sendsPerHour).

| # | Screen | Action | Leads to |
|---|--------|--------|----------|
| 1 | Quick Session — start & workout-type chooser (launchpad after Quick Start) | Tap Quick Start (workout.quickStart), then choose the Climbing type card | Climbing — Session Canvas (climb list) |
| 2 | Climbing — Session Canvas (climb list) | Empty canvas with HUD/command bar started; tap Add a climb (the +/New climb affordance, freeform.addExercise → 'Climbing') | Climbing — "Add a climb" bottom sheet (FreeformPlayerView add sheet) |
| 3 | Climbing — "Add a climb" bottom sheet (FreeformPlayerView) | Pick TYPE (boulder/top-rope/lead/sport), enter NAME, GRADE (scale-aware V/Font/YDS), optional GYM/location; confirm Add | Climbing — Session Canvas (climb list) |
| 4 | Climbing — Session Canvas (climb list) | New named Climb card appears (auto-scrolled into view via ScrollViewReader); tap it to expand | Climbing — Climb detail with attempts (expanded climb card) |
| 5 | Climbing — Climb detail with attempts (expanded climb card) | Tap Add attempt, choose TIMED → opens the live attempt as a full-cover | Climbing — Live timed attempt screen (full-cover FOCUS) |
| 6 | Climbing — Live timed attempt screen (full-cover FOCUS) | Shows climb name/type/grade + count-up StopwatchView; do the attempt, tap Stop (captures elapsed → durationSec, success haptic) | Climbing — Climb detail with attempts (expanded climb card) |
| 7 | Climbing — Climb detail with attempts (expanded climb card) | Pick the outcome for the just-timed attempt (Flash/Sent/Project/Attempt via KilterAscentStatus); attempt row is appended under the climb | Climbing — Climb detail with attempts (expanded climb card) |
| 8 | Climbing — Climb detail with attempts (expanded climb card) | Tap Add attempt again, choose UNTIMED → quick outcome + attempts stepper, no stopwatch; appends a second attempt row | Climbing — Session Canvas (climb list) |
| 9 | Climbing — Session Canvas (climb list) | Tap Add a climb again to start a 2nd climb | Climbing — "Add a climb" bottom sheet (FreeformPlayerView) |
| 10 | Climbing — "Add a climb" bottom sheet (FreeformPlayerView) | Enter type/name/grade for the 2nd climb; confirm Add, then log attempts under it | Climbing — Session Canvas (climb list) |
| 11 | Climbing — live in-session stats (stat ribbon docked above the climb cards) | Glance at the always-visible one-line ribbon (sends · attempts · hardest grade · sends/hr); tap to expand | Climbing — live in-session stats Live-stats sheet |
| 12 | Climbing — live in-session stats (tap-to-expand Live-stats sheet) | Read ambient KilterSessionStats-style detail (pyramid by grade, projects, median time on climb, timeline); dismiss — logging stays on the cards below | Climbing — Session Canvas (climb list) |
| 13 | Shared live command bar / mini-HUD (docked) | Tap Finish (freeform.finish); finishTapped() computes milestones and switches the cover to the summary | Session completion summary (type-adaptive) |
| 14 | Session completion summary (type-adaptive) — FreeformPlayerView.doneScreen | See Duration · Sets · Sends headline + any 'First V4 send!' milestone (CelebrationBurst); tap Done (save) or View detail | Quick Session ends / session detail |

#### Timed exercise — full flow (select-from-catalog OR create-new → live timed set → more sets / another exercise → finish)

> Maps to FreeformPlayerView .duration rows + LogSetSheet duration mode (StopwatchView count-up OR manual Min/Sec). Today: Timed just adds a flat 'Timed exercise' row, no catalog and no naming. Redesign adds a climb-like hierarchy: a named Timed-exercise card with a select-from-catalog/create-new dropdown (e.g. '7s hang', 'Plank', 'Dead hang'), sets logged under it, and the live timer promoted to a full-screen FOCUS cover. Timed headline = FreeformSummary.holdTimeSeconds (Hold time).

| # | Screen | Action | Leads to |
|---|--------|--------|----------|
| 1 | Quick Session — start & workout-type chooser (launchpad after Quick Start) | Tap Quick Start, then choose the Timed type card (freeform.cardTimed) | Timed exercise — pick or create |
| 2 | Timed exercise — pick or create | Use the dropdown: SELECT from the catalog (e.g. '7s hang', 'Plank', 'Dead hang') OR CREATE-NEW (name + optional default duration) | Strength/Timed canvas — named timed-exercise card on the Session Canvas |
| 3 | Timed exercise — pick or create | (create-new branch) Type a new exercise name, save it to the catalog for reuse, confirm | Strength/Timed canvas — named timed-exercise card on the Session Canvas |
| 4 | Climbing — Session Canvas (climb list) [reused as the timed-exercise canvas] | Named timed-exercise card appears; tap Add set → Timer to run it live | Timed exercise — live timed-set screen (full-screen FOCUS cover) |
| 5 | Timed exercise — live timed-set screen (full-screen FOCUS cover) | Shows the exercise name + count-up StopwatchView; perform the hold, tap Stop (captures elapsed → durationSec, success haptic). (Manual Min/Sec entry remains an option if not timing live) | Strength — quick set logging (timed-exercise card with sets list) |
| 6 | Strength — quick set logging (exercise card with sets list) | Set row appended under the exercise; tap Add set / Repeat (FreeformSummary.repeatLabel) to log more sets quickly | Strength — quick set logging (exercise card with sets list) |
| 7 | Strength — quick set logging (exercise card with sets list) | Tap New exercise (freeform.addExercise) → Timed exercise to add another timed exercise | Timed exercise — pick or create |
| 8 | Shared live command bar / mini-HUD (docked) | Tap Finish (freeform.finish) | Session completion summary (type-adaptive) |
| 9 | Session completion summary (type-adaptive) — FreeformPlayerView.doneScreen | See Duration · Sets · Hold time headline (+ any milestone); tap Done to save or View detail | Quick Session ends / session detail |

#### Shared session lifecycle (HUD · pause/resume · live metrics · clips → Studio)

> Cross-cutting behaviors that apply to every Quick Session type. Maps to the existing safeAreaInset command bar, togglePause() driving app.liveWorkout + Live Activity, LiveMetricsPanel peek, the 20s clip discovery .task + SessionMediaAssignment auto-tagging, and presentStudio()→StudioEditorView. The mini-HUD/LiveMetricsPanel and clips→Studio are type-agnostic; strength and running freeform sessions ride the same lifecycle.

| # | Screen | Action | Leads to |
|---|--------|--------|----------|
| 1 | Shared live command bar / mini-HUD (docked, all session types) | Persistent bar shows wall-clock elapsed timer · live HR chip (bpm + Z-zone + recovery dot) · Finish — present for climbing, timed, strength, and running sessions | Shared live command bar / mini-HUD (peek-to-expand LiveMetricsPanel) |
| 2 | Shared live command bar / mini-HUD — peek/tap the HR chip (freeform.hrChip) | Open the LiveMetricsPanel: HR zones Z1–Z5, recovery ring, calories (read-only/ambient) | Shared live command bar / mini-HUD (docked) |
| 3 | Shared live command bar / mini-HUD (docked) | Tap Pause (pauseWorkout) → togglePause() pauses app.liveWorkout and pushes paused state to the Live Activity (Lock Screen / Dynamic Island) | Shared live command bar / mini-HUD (paused state) |
| 4 | Shared live command bar / mini-HUD (paused state) | Tap Resume → app.liveWorkout.resume(); timer continues from wall-clock startedAt; HUD un-pauses | Shared live command bar / mini-HUD (docked) |
| 5 | Strength — quick set logging / any session canvas | Minimize (minimizeWorkout) leaves the session active in the background; re-entering via Quick Start resumes the same session (resume(), never stacks a 2nd) | Climbing — Session Canvas (climb list) / whichever canvas was active |
| 6 | Strength — quick set logging (per-set media strip) / any canvas | Film a clip during the session; the ~20s discover .task auto-tags it to the set it falls in (SessionMediaAssignment); tap the clip in the SetMediaStrip | Clip → Studio (StudioEditorView full-cover) |
| 7 | Clip → Studio (shared scoped Studio editor, StudioEditorView) | Edit the freeform clip (HR overlay loaded from live watch+BLE buffer for a still-live session); back out — the session stays live | Strength — quick set logging / whichever canvas was active |
| 8 | Running — quick log / live run (freeform session) | Running rides the same lifecycle: log distance/duration on the running card, HUD/HR/clips behave identically; tap Finish when done | Session completion summary (type-adaptive) |
| 9 | Session completion summary (type-adaptive) — FreeformPlayerView.doneScreen | Keep going (freeform.keepGoing) returns to the canvas, or Done saves, or Discard drops an empty/unwanted session | Quick Session ends or returns to the active canvas |

---

## 6. Wireframes

The 12 designed surfaces — open **[wireframes.html](./wireframes.html)** for the styled iPhone mockups, or **[wireframes.md](./wireframes.md)** for full ASCII mockups (with empty / no-HR / first-ever / long-session / Reduce-Motion states) plus interactions, captured data, and rationale per screen.

1. **Quick Session — start & workout-type chooser (the launchpad after Quick Start)** *(all)* — The one-screen launchpad layered over the already-running FreeformPlayerView the instant the user taps Quick Start — it replaces today's three-card emptyStateHero (Lifting / Climbing / Timed). The session shell is auto-started, dated, and live (timer ticking off session.startedAt, HR + Live Activity warming in the persistent command bar); this surface is purely the type chooser, NEVER a setup wizard. Its job: collapse "what am I doing?" into ONE tap, route straight into the right first-entity creator (Add a climb / Add a timed exercise / pick a lift / start an open count-up), teach the new entity-then-attempt loop ("attempts log underneath it"), surface the single most-likely choice via a Resume-last card so the dominant path is one tap, keep every target in the bottom thumb zone, and never block logging behind a catalog or config step. It renders only while session.exercises.isEmpty and auto-dismisses to the canvas on the first entity add; if the user deletes back to empty it re-shows (guarded so it never flashes mid-session). NOTE on data model: the rich climb fields the populated state shows (climbType, gradeScale, climbName, attemptTimestamps[], per-climb startedAt/endedAt) do NOT yet exist on the freeform SetLog/SessionExercise path — today's freeform SetLog only carries flat climbGradeLabel/climbStatusRaw/climbAttempts and no parent grouping. Those rich fields live only on the board-only KilterLogEntry @Model. So this redesign is NOT "~1:1 reuse" as the brief claimed; it requires promoting the KilterLogEntry shape (+ two net-new fields, climbType and gradeScale) into a freeform climbAttempt PARENT and wiring KilterSessionStats.compute over it. That modeling move is the real prerequisite and is called out here so the screen is not designed on a false "already exists" premise.
2. **Climbing — Session Canvas (climb list)** *(climbing)* — The climb-first home of a freeform climbing session: a vertical, scannable list of CLIMBS/ROUTES added this session. Each climb is a .snappetCard() that rolls up its IDENTITY (type icon + name + color-banded scale-aware grade chip) and its OUTCOME (status badge, attempts count, best outcome, time-on-climb). Attempts always live UNDERNEATH a climb, never as flat sibling rows — directly fixing the current pain point ("you cannot group 3 tries on the same V4 project"; today every attempt is a flat LogSetSheet row with a free-text "Grade (e.g. V4, 6c)" field, popped-and-dismissed once per bid). A teach-the-loop empty state invites "Add your first climb"; a bottom-thumb-zone "+ Add climb" CTA grows the session; one peek strip of live, accruing stats (Sends hero + hardest-send chip + tiny grade pyramid with a text equivalent) sits just above the command bar. Tapping a climb expands it inline to its attempt list and a one-gesture +1 attempt / Send footer; toggling "Time next go" routes the next attempt into the FOCUS live-timer cover; every other action stays on this canvas. TYPE is chosen first at creation and drives the grade SCALE (boulder→V/Font, TR/lead/sport→YDS/French) and the status taxonomy, so the canvas honestly renders mixed-type sessions (a V5 boulder and a 5.10a top-rope side by side).
3. **Climbing — "Add a climb" bottom sheet (freeform Quick Session / FreeformPlayerView)** *(climbing)* — Create a named, TYPED, GRADED climb PARENT inside the already-running freeform session so every later effort logs UNDERNEATH it instead of as a flat SetLog row (the documented pain point: no named climb, no type, no grade-scale awareness, cannot group 3 tries on one V4). Replaces TWO current antipatterns at once: (1) tapping "Climbing" in the Add-exercise confirmationDialog instantly dropping a generic "Climbing" SessionExercise row with no creation step, and (2) the flat per-attempt LogSetSheet whose freetext TextField("Grade (e.g. V4, 6c)") + single Outcome Picker + .medium-only detent carry the only climb identity. The sheet captures identity ONCE — TYPE first (boulder/top-rope/lead/sport, because it drives the grade scale and the status taxonomy), a scale-aware DISCRETE grade picker (never freetext, stores an ordinal Double so the pyramid + hardest-send math are exact), optional smart-suggested NAME, optional session-inherited GYM — then exits straight into the first attempt. Mostly-optional with last-time defaults: the warm path (a returning boulderer whose TYPE/scale/gym are prefilled) collapses to ~2 taps (tap a recent-grade chip, tap the CTA); the cold path (first-ever climb, no recents) is a short TEACHING form, never a blank void. This is the single highest-leverage fix and is ~1:1 reuse of the KilterLogEntry shape promoted out of the Kilter-only path into the freeform SetKind.climbAttempt parent.
4. **Climbing — Climb detail with attempts (expanded climb card inside the running Quick Session / FreeformPlayerView)** *(climbing)* — Make a single climb the unit of work: one named, typed, graded PARENT whose efforts are logged underneath it in a single gesture. This is the expanded state of a climb's .snappetCard() on the running session canvas — header (type chip, color-AND-glyph-banded grade, name, gym), an attempts timeline (outcome + duration + timestamp, newest-first), per-climb mini-stats (tries / best / time-on-this-climb), and TWO unmistakable bottom-thumb-zone ways to log the next effort: "Log attempt" (quick, untimed, pick an outcome inline) and "Timed attempt" (full-cover count-UP live timer). The expensive form (type/name/grade/gym) happened ONCE at creation, so from here every effort collapses to a single confirm tap — one-tap Repeat-last and inline outcome edit kill the re-opened-sheet antipattern. Repeat-last is suppressed once a send closes the climb; logging another go then becomes an explicit reopen so we never silently append to a finished climb.
5. **Climbing — Live timed attempt screen (full-cover FOCUS)** *(climbing)* — A full-screen, glanceable, one-handed FOCUS surface that times a single climbing attempt while the climber is mid-effort under a boulder. It is the COLLAPSE-on-stop third state of the PEEK→FOCUS→COLLAPSE flow: the session canvas (PEEK) hands off here when an attempt is timed, all session stats recede, exactly one hero metric (a count-UP stopwatch) dominates, and a giant bottom STOP button captures duration + start/stop timestamps. On Stop, an inline outcome prompt (Flash / Send / Fall / Project) writes the attempt under its parent climb and auto-returns to the canvas with zero re-entry of name, grade, or duration. Calm, dark, minimal chrome — you are mid-effort under a boulder, gripping the phone with chalky fingers. Untimed attempts skip this surface entirely (one tap on the card).
6. **Climbing — live in-session stats: a one-line "stat ribbon" docked just above the freeform climb cards, plus a tap-to-expand Live-stats sheet. Read-only/ambient; logging stays on the climb cards below it.** *(climbing)* — Make the freeform climbing session feel like it is building. ONE hero number (Sends, which momentarily flips to a Hardest-send grade chip the instant a harder send lands), a thin always-on tail, and a 4-bar mini pyramid sparkline sit in a single ribbon above the climb cards. One tap opens a Live-stats sheet (.medium then .large) with the accruing grade pyramid, sends/tries/projects, sends-per-hour, time-on-wall vs rest, and an effort/HR strip. The surface CAPTURES nothing — it is a derived read-model over the session's logged climbs. Honest-state-first: it renders nothing until the first attempt is logged, shows a "send one to start your pyramid" coachmark before the first send, gracefully DROPS the time-on-wall and HR rows when those signals are absent (untimed session / no Watch / simulator), and never bluffs data it does not have. Crucially the redesign FIXES a real data-model gap I confirmed in code: freeform climbs persist as flat SetLogs (WorkoutModels.swift L226) carrying only climbGradeLabel (free text), climbStatusRaw, climbAttempts, optional durationSec — NO climbUUID, NO float difficulty, NO per-climb startedAt/endedAt, NO attemptTimestamps[]. The original schema's claim of reading KilterSessionStats.make via KilterClimbLog.from(_:) is wrong: from(_:) maps a KilterLogEntry, which the freeform path never creates. So "1:1 reuse, no new modeling" is false. The load-bearing new work is a pure SetLog->KilterClimbLog adapter plus a grade-string->float parser; everything downstream (pyramid order, hardest-send, sends/hr) then reuses KilterSessionStats unchanged.
7. **Timed exercise — pick or create** *(timed)* — When the user taps "Timed" inside a live Quick Session (FreeformPlayerView), this medium-detent bottom sheet is the single entry point for choosing WHICH timed exercise to log — mirroring the climb-add hierarchy. Instead of today's dead-end "Timed exercise" row + flat "Add set" sheet, the user first picks/names a reusable PARENT (Dead hang, Plank, Wall sit, 7:3 repeaters, Hollow hold, Bar hang, or a custom), then logs timed SETS underneath it. It leads with a searchable catalog (favorites + recents first, then category groups) with "Create new" pinned at top. The create path captures NAME + STRUCTURE (count-up / count-down target / repeaters) via protocol-preset chips, with a SINGLE live "Total" readout that makes a structured spec legible before commit — persisting customs to a small SwiftData TimedExerciseCatalog so they survive across sessions and flow through the same stats aggregation as seeded ones. The expensive form happens exactly once here; every subsequent set is one gesture.
8. **Timed exercise — live timed-set screen (full-screen FOCUS cover)** *(timed)* — The dedicated eyes-off live timer that runs ONE timed effort under a named timed-exercise parent (e.g. "7s Max Hang", "Plank", "Repeaters 7:3") and turns the measurement itself into the log. It presents as a full-screen FOCUS cover — the middle state of PEEK→FOCUS→COLLAPSE — so the freeform command bar and session stats recede and exactly one thing matters: the count. It handles both timer mentalities unambiguously and visibly: count-DOWN drains a ring (ember WORK / muted REST) with a terminal success haptic for a structured target (a fixed 10s hang, a 7:3 repeater work phase); count-UP for an open effort (max dead-hang to failure, AMRAP) shows the count growing with a thin progress arc vs your last best. A configurable 3-2-1 lead-in gets the user into position AND stamps startedAt early to warm the HR/HealthKit pipeline so the first samples land inside the set. Distinct per-phase audio + haptic cues let a climber read the timer peripherally mid-hang; the HR chip degrades gracefully to an inert gray pill when there is no source. On Stop / auto-finish the measured hold time (or completed reps×sets) flows straight into a pre-filled SetLog with one confirm tap — replacing today's manual Min/Sec entry as the PRIMARY path — then auto-collapses to the freeform canvas where live stats update and an optional remembered rest countdown starts in the command bar.
9. **Strength — quick set logging (freeform session: exercise card with a sets list + fast reps×weight entry)** *(strength)* — Make logging a working set the single fastest interaction in the app, using the same entity→child grammar as the climb-first redesign. Tap "Strength" → pick or create a named EXERCISE (a parent .snappetCard), then log SETS underneath it. The dominant per-set interaction collapses to ONE tap because reps×weight + unit are prefilled from history (LastSetLookup) and surfaced as a "Same as last" repeat — wiring directly to the EXISTING repeatLastSet/SetMeasure.duplicate path, not new modeling. Big +/- steppers (the shipping QuickAddRow controls) handle bounded reps and ±2.5 weight; a numeric keypad (KeypadDoneToolbar) handles odd/unbounded weight; an inline plate calculator and a sticky session unit live without leaving the field. Committing a set is instant (with Undo) and OPTIONALLY auto-starts a remembered per-exercise rest timer (persisted on the already-present SessionExercise.targetRestSeconds) in the command bar. The hero stat is live Volume. This UPGRADES today's freeform strength path — which already has the inline QuickAddRow steppers + a "Repeat set" button but lacks a parent card, grouped sets list, rest timer, plate calc, and inline edit — into a scannable, grouped, prefilled exercise→sets logbook that mirrors the climb→attempts and timed→sets cards.
10. **Running — quick log / live run (freeform session)** *(running)* — Make running a first-class but LIGHT member of the grow-as-you-go freeform session — same auto-started dated shell, same docked elapsed|HR-chip|Finish command bar, same StopwatchView / LiveMetricsPanel / CelebrationBurst / completion-summary vocabulary as climbing/timed/strength — with NO GPS. Two coherent paths off one screen, both honest about what is actually measured device-side: (1) QUICK LOG — a medium-detent sheet to type distance + duration (pace auto-derived) for a run that already happened, capturing in <=3 taps; (2) LIVE RUN — a minimal one-hero HUD whose ONLY device-measured live value is DURATION (count-up StopwatchView) + live HR; distance is entered at Stop (or typed in for a treadmill that shows it), and pace is computed once distance is known. The running session's headline stat is Distance (mirroring climbing=Sends / strength=Volume / timed=Hold-time) — but during a no-GPS live run the LIVE hero is Duration, because that is the only thing actually accruing; Distance becomes the headline at capture. The whole point is type COMPLETENESS and coherence: a runner gets the identical card/HUD grammar so all five Activity types feel like one app, and a future real-GPS run slots into the same card/HUD/splits by simply filling distanceMeters/HRPoint live instead of at Stop — no redesign.
11. **Shared live command bar / mini-HUD (docked, all session types) with peek-to-expand LiveMetricsPanel** *(all)* — The single, shape-identical docked instrument pinned to the bottom of every active freeform session (climbing/timed/strength/run/dance/other). COLLAPSED it is a glanceable strip capped at THREE information cells — elapsed timer | live HR chip (bpm + zone color + recovery dot) | one SetKind-aware HERO stat — flanked by the only two thumb-zone ACTIONS: a quick-add (+) and Finish. The hero, chip, and (+) menu are the ONLY parts that adapt per session; chrome, layout, and gestures never change shape between types. A swipe-up on the grab handle, or a tap on the HR chip, expands it IN PLACE into the LiveMetricsPanel (recovery ring, bpm+zone, Avg/Max/Redline/kcal, one stacked time-in-zone bar, live HR trend, optional rest timer, and a climbing-only deeper-peek pyramid/hardest-send row). It is the always-on layer of the layered HUD so the session canvas above stays uncluttered. Grounded in the real FreeformPlayerView.commandBar (today: timer | HR chip | Finish) and LiveMetricsPanel — this refinement adds the hero cell, relocates Add from the toolbar into the thumb zone, gives the chip a no-HR connect affordance, and makes pause reachable without leaving the bar.
12. **Session completion summary (type-adaptive) — the "Finish" destination of a Quick Session (FreeformPlayerView.doneScreen, re-laid-out)** *(all — climbing / timed / strength carry bespoke bodies; running / dance / other degrade to the shared Duration-hero shell)* — duplicate-removed

---

## 7. Data-model & implementation notes

This redesign is deliberately **low-migration**: most of it reuses shapes that already exist in the Kilter board path.

### Already exists — just needs wiring into freeform
- **`KilterLogEntry`** (`climbUUID, climbName, gradeLabel, status, attempts, attemptTimestamps[], startedAt/endedAt, note`) is exactly the *climb parent + attempts* shape. Promote it out of the Kilter-only path into a freeform `SetKind.climbAttempt` parent.
- **`KilterSessionStats.compute`** is a pure function already producing `totalClimbs / sends / projects / totalAttempts / hardestSendGrade / sendsPerHour / pyramid[] / timeline[] / medianTimeOnClimb`. Wire it to the freeform session and recompute on every log event — that *is* the live-stats ribbon + completion pyramid.
- **`StopwatchView`** (count-up **and** count-down, wall-clock-backed, success haptic) is the live timed-attempt / timed-set engine. Lift it out of the cramped `LogSetSheet` into a full-cover FOCUS screen.
- **`KilterAscentStatus`** (`flash / sent / project / attempt`, `isSend`) is the boulder status set. The Glass-HUD kit, `snappetCard`, the docked command bar, `LiveMetricsPanel`, `CelebrationBurst`, and `KeypadDoneToolbar` are reused as-is.

### Genuinely net-new (the real work)
1. **A climb *parent* in the freeform model.** Today freeform stores flat `SetLog`s (`climbGradeLabel / climbStatusRaw / climbAttempts`). Introduce a parent entity (mirroring `KilterLogEntry`) so attempts nest under one card. This is the spine; do it first.
2. **`climbType` + `gradeScale` on the climb.** Boulder reuses the existing `6a/V3` Font/V labels. **Top-rope / lead / sport + YDS (5.x) / French scales are net-new modeling** — the single biggest gap. Add a `ClimbType` enum + a scale-aware discrete grade picker; persist both. Status options become type-driven (lead/sport add onsight/redpoint/pinkpoint + a top-rope flag).
3. **A persisted `TimedExerciseCatalog`** (small SwiftData model) so named timed exercises (*7s hang*, *Plank*, *Dead hang*) survive across sessions, plus a shared **`TimedExerciseSpec`** in `ios/App/Shared` (`workSec, restSec, reps, sets, restBetweenSetsSec, leadInSec, mode`) agreed by phone/watch/widget.
4. **A structured multi-interval runner** (repeaters / Tabata / EMOM) as a distinct full-cover: phase label + draining count-down + Set·Rep counter + next-phase preview, with a 3-2-1 lead-in and per-phase audio/haptic cues.
5. **Remembered per-climb/per-exercise rest timer**, auto-started on attempt/set completion, shown non-blocking in the command bar (reuses `StopwatchView` count-down + the command bar).
6. **Location at session/first-climb level**, inherited downstream, free-text + recents (no curated-catalog gate).

### Guardrails the research surfaced (verified failure modes)
- **Never silently snap an entered timer value** to a "preferred" setting (the Tindeq failure). Surface a gentle hint; ship protocol-preset chips instead.
- **Never free-text grades** — they can't power exact pyramid/hardest-send math. Use a scale-aware discrete picker + recent-grade chips.
- **Don't let custom climbs/exercises become stat dead-ends** (Fitbod's documented gap) — route them through the same `KilterSessionStats`-style aggregation as seeded ones.
- **Cap the always-on HUD** at one hero + a thin strip; hide session stats entirely during a timed FOCUS attempt.

## 8. Suggested phasing

A sequencing suggestion, not a commitment — each phase is independently shippable and PDD-prompt-sized (one prompt = one job = one PR).

1. **Phase 1 — Climb-first hierarchy (boulder only).** Climb parent entity in the freeform model; climbs render as expandable `snappetCard`s with nested attempts; "Add a climb" bottom sheet (type=boulder, name, V/Font grade picker, optional gym). Untimed attempts = one tap. *Reuses `KilterLogEntry` shape + existing Font/V labels. No new grade scales yet.*
2. **Phase 2 — Timed-attempt FOCUS cover.** Lift `StopwatchView(.countUp)` into a full-cover live attempt screen; Stop → capture duration into `attemptTimestamps[]/startedAt-endedAt` → inline outcome picker → auto-collapse.
3. **Phase 3 — Live stats ribbon + milestones.** Wire `KilterSessionStats.compute` to the freeform session; ambient one-line ribbon + tap-to-expand sheet; history-derived `CelebrationBurst` at the logging moment.
4. **Phase 4 — Route types + scales.** `ClimbType` (top-rope/lead/sport) + YDS/French scales + type-driven status set. *This is the net-new modeling; isolate it.*
5. **Phase 5 — Timed-exercise hierarchy + catalog.** `TimedExerciseCatalog` + `TimedExerciseSpec`; pick-or-create dropdown; named timed cards with nested sets; "the timer IS the log."
6. **Phase 6 — Structured interval runner.** Repeaters / Tabata / EMOM full-cover with protocol presets, 3-2-1 lead-in, per-phase audio/haptics (incl. watchOS).
7. **Phase 7 — Polish.** Remembered rest timers, recent-grade/recent-gym chip rails, voice/Watch fast-capture, keep-awake.

*Each phase should ship with its PDD feature prompt, a `pdd/context` update, and a knowledge-graph node when it lands as a real surface.*

---

*Generated 2026-06-18 · 38 agents · ~2.1M tokens · grounded against the live Snappet codebase. This is a research/design artifact, not shipped UI — use it to seed PDD feature prompts.*

