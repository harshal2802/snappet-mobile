# Recap — a self-composing session feed that's a social graph in disguise

> **Snappet Mobile** · new **Recap** tab (`feed`) · 2026-06-20
>
> A new third tab — **Today · Recap · Apps** — that turns your own climbing/training history into a
> self-composing, beautiful, *true* daily-open hook: a reverse-chronological backbone of your sessions,
> woven through with eligibility-gated insight & recap cards, a pinned Stories rail, and a one-tap path
> from any card to a shareable Instagram/iMessage artifact. This is the **planning** deliverable —
> design direction, the keystone, the data model, per-surface design with verified `file:line`,
> wireframes, and a phased PDD plan — to review **before any implementation**
> (CLAUDE.md / the [[wireframe-before-implementation]] rule).
>
> | File | What it is |
> |------|------------|
> | **README.md** (this) | The design direction + the keystone + the data model + the card taxonomy + the per-surface design + the phased plan. |
> | **[wireframes.html](./wireframes.html)** | **Open in a browser** — real-looking surfaces for all Recap flows, real `SnappetColor`/`PulseColors`/Pulse-Pro tokens, dark-mode-first. Prototype **#8 (Story Player)** first — highest wow, highest risk. |
> | **[wireframes/](./wireframes/)** | Rendered PNGs (real tokens, 2×). |
>
> *Every `file:line` below was checked against the dossier code maps (iOS models, Android models, shared
> components). iOS paths are under `ios/App/Snappet/` and Android under
> `android/app/src/main/java/com/snappet/mobile/` unless noted.*

---

## TL;DR

**The north star.** *Open the app daily because a new, beautiful, true story about your own
climbing/training is always waiting — and any card is one tap from being a shareable artifact on
Instagram or iMessage.* We call the tab **Recap**.

**The concept.** The Feed tab is a reverse-chronological backbone of the user's *own* sessions, woven
through with eligibility-gated insight & recap cards that compose themselves from whatever data the user
actually has — and pinned at the top, a Stories rail that makes the tab a *daily-open hook* ("what new
story unlocked?") rather than a passive log.

**The differentiator.** A **pure, eligibility-gated `FeedComposer`**: every card declares an
`eligibility(predicate) -> Bool` and a `salience(score) -> Double`, so the feed **degrades gracefully by
construction** — a card needing data Android lacks is simply never composed (no greyed-out buttons, no
"coming soon" stubs). Beneath the surface, every feed-worthy event is an **append-only, AS2-shaped,
UUIDv5-identified `FeedActivity`** with `visibility`/`audience`/reactions provisioned but dormant — so
"personal-now" becomes "social-ready" with **zero card-view rewrite**.

**The synthesis.** We resolve the three-way design tension decisively: a self-composing intelligence layer
**(B)** is the spine (the engagement engine), the append-only AS2 activity log + first-class interaction
rows **(C)** is the foundation (social insurance), and the comfortable everyday chronological stream + the
inline auto-clip wow + the masonry send-wall **(A)** is the texture. v1 derives session/insight **cards on
read** (A's `TodayDigest` pattern — no migration) but **persists the thin `FeedActivity` log + interaction
rows from day one** (C), because deferring the log "guarantees the redesign the lens exists to prevent."
Salience ranking is kept but **recency-bounded** (a card never floats older than its trigger) and a
chronological **"Sessions-only"** lens is always available.

**Everything is on-device.** No backend, no accounts, no network in v1. The pure cores stay device-free +
unit-tested per CLAUDE.md.

---

## 1. The keystone — one pure composer behind every surface

**Keystone: `FeedComposer` + the `FeedCard` value type + the per-card `eligibility`/`salience` registry —
pure, Foundation/Kotlin-stdlib only, golden-vector-tested across iOS↔Android, with ZERO UI and ZERO store.**

```
            TODAY                                          AFTER

  KilterAllTimeStats / KilterSessionStats        FeedComposer.compose(window:) — pure, tested
  HRStats / HRVMetrics / ReelRanking              eligibility(predicate)->Bool · salience(score)->Double
    pure, tested ── surfaced by ──┐                            │
    nobody as a unified feed      │      ┌────────────────────┼─────────────────────┐
                                  │      Infinite feed         Story Player           Wall
  TodayDigest derive-on-read  ────┘      compose(.allTime)     compose(.thisWeek/     (same corpus,
    pure aggregation (Home)              (FeedView/FeedScreen)  .thisMonth/.thisYear)  masonry)
```

This is the single artifact every other phase renders, exactly as `KilterAllTimeStats` was the keystone for
the Kilter initiative. Justification:

- **It is the engagement engine.** The "self-composing magazine" delight lives entirely here — eligibility
  predicates decide *what* unlocks, `salience × recencyDecay` decides *order*.
- **It is the graceful-degradation mechanism.** A card needing `hrSeries`/`SessionMedia` declares those in
  its eligibility; on Android those providers return nil and the card is **never emitted** — same engine,
  two eligible sets, no divergent UI code.
- **It is platform-shared and cheaply provable** via the existing `KilterCreatedClimb` UUIDv5
  cross-platform golden-vector discipline: one golden *corpus* (raw sessions/logs in → ordered `FeedCard`s
  out) yields the identical eligible card set on both platforms.
- **It reuses, never reinvents.** It consumes `KilterAllTimeStats`, `KilterSessionStats`, `HRStats`,
  `HRVMetrics`, `ReelRanking` **verbatim** and only *surfaces* their numbers.
- **It is the one caller behind two surfaces:** the infinite feed calls `compose(window: .allTime)`; the
  Story Player calls `compose(window: .thisWeek/.thisMonth/.thisYear)`. One engine, two callers.

The **companion keystone** (same wave, separate PR) is the **`FeedActivity` persisted log +
`Reaction`/`SaveItem`/`ShareEvent` rows** — the AS2 backbone with dormant social columns. The composer
reads activities and *dereferences* to the rich models; it never duplicates their data.

---

## 2. Information architecture

Recap plugs in as the **middle** tab (Today · **Recap** · Apps) — the new emotional center.

- **iOS:** add `case feed` to `SuiteTab` (`Core/SuiteRouter.swift:5`); insert a third `TabView` case in
  `ShellTabs` (`Features/Shell/RootShell.swift:160-169`) → `FeedView()`, `.tag(SuiteTab.feed)`, SF Symbol
  `sparkles.rectangle.stack`, label **"Recap"**. New dir `ios/App/Snappet/Features/Feed/`. Deep-link
  `snappet://feed` via the existing `onOpenURL` (`RootShell.swift:51`).
- **Android:** third `NavigationBarItem` at index 2 (`ui/RootShell.kt:75-81`, icon
  `Icons.Filled.AutoAwesome`, label "Recap"); extend the `AnimatedContent` switch (`RootShell.kt:100-104`)
  with `2 -> FeedScreen()`, reusing `snappetSurfaceTransition()` (`RootShell.kt:35`). New pkg
  `com.snappet.mobile.feature.feed`. Deep-link `snappet://module/feed`.

### Sub-surfaces

1. **FeedView / FeedScreen (root scroll)** — `LazyVStack`/`LazyColumn`, infinite reverse-chronological
   backbone + interleaved insight/recap cards. At the very top: the **pinned Stories rail** (horizontal
   swipeable period covers: "This Week" · "This Month" · "Year in Climb"). Under it: the **Lens bar**
   (client-side filter chips: *All · Climbing · Strength · Effort · Milestones · Sessions-only*). Then the
   composed stream. Header has a **grid toggle** to the Wall.
2. **WallView / WallScreen (grid / "send wall")** — same corpus as masonry portfolio
   (`LazyVerticalStaggeredGrid` on Android; waterfall `LazyVStack` columns on iOS). Identity-at-a-glance
   retention surface (Instagram grid + Pinterest masonry).
3. **CardDetailView (push)** — full polished stat card + expandable deeper stats (climb-by-climb timeline +
   HR effort on iOS; pyramid + volume on Android) + attached media (iOS) + reactions strip + "Open in
   Kilter/Workout" deep-link + Share entry.
4. **RecapStoryCover (full-screen)** — Spotify-Wrapped-grammar swipeable scenes (tap-through, hold-to-pause,
   tap-left/right). Re-runs `FeedComposer` scoped to a period; sparse period = 3 scenes, rich = 8. Each
   scene independently shareable.
5. **ShareComposerCover (sheet)** — named-template picker → live on-device preview at exact 9:16 / 4:5 / 1:1
   → render-to-image (both platforms) or render-to-clip (iOS) → OS share sheet / IG Stories sticker handoff.
6. **InsightDetailView (push)** — for a tapped insight card (e.g. Grade PR), shows the math behind it: the
   source send/session, the progression line for context, the pyramid row it completed.

### End-to-end user flow

```mermaid
flowchart TD
    Shell["RootShell (Today · RECAP · Apps)"] -->|tap Recap tab| Feed["FeedView / FeedScreen"]
    Feed -->|Stories rail| Story["RecapStoryCover<br/>(period-scoped FeedComposer)"]
    Feed -->|Lens chips| Feed
    Feed -->|grid toggle| Wall["WallView (send wall)"]
    Wall -->|tap thumb| Detail
    Feed -->|tap session/PR/insight card| Detail["CardDetailView / InsightDetailView"]
    Feed -.->|double-tap| React["Reaction row (target=self)"]
    Feed -.->|long-press| Save["SaveItem row (collection)"]
    Feed -->|new session logged while away| Pill["'N new' / 'New recap ready' pill<br/>(scroll-to-top, no yank)"]
    Pill --> Feed
    Detail -->|Open in module| Module["KilterSessionDetail / WorkoutSessionDetail"]
    Detail -->|Share| Composer["ShareComposerCover<br/>(template · aspect · metrics)"]
    Story -->|per-scene Share| Composer
    Composer -->|iOS: Animate| Reel["ReelEditor (HR-overlay clip via ReelExporter)"]
    Composer -->|render image / clip| OS["OS share sheet → Instagram / iMessage / Photos<br/>(music omitted)"]
    Reel --> OS
    OS -.->|append ShareEvent (channel=export:instagram)| Log["FeedActivity append-only log"]
    Feed -. derive-on-read .-> Composer2["FeedComposer (keystone)"]
    Composer2 -. reads .-> Engines["KilterAllTimeStats · KilterSessionStats · HRStats · HRVMetrics · ReelRanking"]
    Composer2 -. dereferences .-> Log
```

**Flow narrative.** User taps **Recap** → skeleton paints, the Stories rail fades in first (cheap), then the
top band of composed cards. Newest session is at top; just below, the composer has floated a
recency-bounded **Grade PR** card and a **Pyramid** card. User flicks down (next keyset page lazily
decodes); on iOS the session card nearest viewport-center auto-plays its muted/looping clip. User
double-taps a card to react (private memory), long-presses to save to a collection. Taps a card → detail →
"Share" → picks the *Send Ticket* template, 9:16 → on-device render → IG Stories sticker. Dismiss returns
to the exact scroll position; if a session was logged meanwhile, the "New recap ready" pill appears.

---

## 3. The data model — two layers, social-ready seams

Two layers (the C+B synthesis): a **persisted append-only activity log** (thin, social-ready) and an
**ephemeral pure card** (computed, never stored). v1 derives the *cards* on read (no migration for cards)
but **persists the activity + interaction rows** so the redesign is never forced.

### 3.1 Persisted: `FeedActivity` (AS2-shaped backbone) — SwiftData @Model (iOS) / Room @Entity (Android)

```
FeedActivity
  id            : UUID            // v4/v7 — the ACTIVITY row id (an event is repeatable)
  contentId     : String         // UUIDv5 — stable CONTENT identity (cross-device dedup)
  actorRef      : String = "self" // today self; later a real userId  ← THE social flip
  verb          : String         // sent | flashed | loggedSession | hitPR | extendedStreak
                                  //  | recap | createdClimb | litBoard | sharedClip | correctedSend
  objectRef     : String         // FK → KilterSession.id / WorkoutSession.id / climbUUID
  objectKind    : String         // kilterSession | workoutSession | climb | clip | litEvent | aggregate
  targetRef     : String?        // board layout / gym / grade-tier / period / collection
  published     : Date           // ordering + dedup + keyset cursor key
  visibility    : String = "private"  // private | followers | public   ← provisioned, dormant
  audienceTo    : [String] = []  // structured people-tag refs (display-name-only burned in) ← dormant
  foreignId     : String         // "\(verb):\(contentId)" idempotency key
  aggregationKey: String         // "\(targetRef):\(verb):\(objectKind):\(weekBucket)" — "X & 3 others" later
  updatedAt     : Date           // LWW conflict field
  version       : Int = 1
  schemaVersion : Int = 1
```

**First-class interaction primitives** (separate append-only rows — the C graft B lacks):

```
Reaction   { id, activityContentId, actorRef:"self", type:emoji|note, createdAt }
SaveItem   { id, activityContentId, collectionId, createdAt }
ShareEvent { id, activityContentId, channel:"export:instagram"|"export:imessage"|"user:<id>", createdAt }
```

The `channel` field is the seam: `export:*` today, `user:*` tomorrow — **the table shape never changes.**
Reactions are framed as **private memory/curation** ("react-as-note to your own On-This-Day"), not hollow
social likes. An **outbox table** is created empty now, drained by nobody — retrofitting an outbox onto live
data is painful, so we pay the tiny cost up front.

### 3.2 Ephemeral: `FeedCard` (pure value type — derived on read, never persisted)

```
FeedCard                         // pure, like KilterAllTimeStats — Codable/Sendable
  kind        : FeedCardKind     // a1Session | b1GradePR | c1Pyramid | e1Effort | f3YearInClimb …
  category    : FeedCategory     // climbing | strength | effort | milestone | trend | recap | memory
  salience    : Double           // PR > trend > routine session
  anchorDate  : Date             // recency slot — NEVER older than its trigger
  sourceRefs  : [ActivityRef]    // which FeedActivities/models it derived from
  payload     : FeedCardPayload  // discipline-typed snapshot so the view renders without re-query
  shareHint   : ShareTemplate?   // suggested export template
```

### 3.3 Derivation from existing models (every field cited)

- **`a1Session` (Kilter)** ← `KilterSession` (iOS `Features/Kilter/KilterModels.swift:310`; Android
  `feature/kilter/KilterEntities.kt:52`) + its `KilterLogEntry[]` → `KilterSessionStats.make(...)`.
  `contentId = uuidv5(NS_SESSION, session.id)`. Payload: `{hardestSendGrade, sends, projects,
  totalAttempts, durationSec, pyramid, angle, hr?:{avgBpm,maxBpm,zoneSparkline?}}`.
- **`a2Session` (Workout)** ← `WorkoutSession` (iOS `Features/WorkoutTracker/WorkoutModels.swift:502`;
  Android `feature/workout/WorkoutModels.kt:271`) + `SessionExercise`/`SetLog`. Discipline-adaptive via
  `disciplineRaw`: strength→`{totalVolume, exerciseCount, durationSec}`; running→`{distanceMeters
  (SetLog.distanceMeters), pace, durationSec}`; timed→`{workTime, rounds, durationSec}`.
- **`a3OnTheBoard`** ← `KilterLitEvent[]` (iOS `KilterModels.swift:465`; Android `KilterEntities.kt:101`)
  for a session with lit events but no full log (the degraded "pulled climbs up but didn't log" path).
  Payload: `{litCount, gradeSpread}`.
- **`b1GradePR`** ← diff of a new send's `difficulty` vs `KilterAllTimeStats.maxGradeDifficulty`.
- **`b4LiftPR`** ← `SetLog.actualWeight × actualReps` → est-1RM vs prior best per `exerciseId` (both
  platforms carry set data).
- **HR cards** ← iOS `KilterSession.hrSeries` → `HRStats`/`KilterSessionStats.timeline[].effort`/
  `HRVMetrics`; Android `avgHr/maxHr/hrSampleCount` summary only (`KilterEntities.kt:65-70`).
- **Media/clip cards** ← `SessionMedia` (iOS `Features/WorkoutTracker/SessionMedia.swift:23`, iOS only) →
  `ReelRanking`/`ReelPlanner`.

### 3.4 Content identity (UUIDv5) scheme

Pinned per-type namespaces, never changed: `NS_FEEDITEM`, `NS_SESSION`, `NS_CLIMB`, `NS_CLIP`. Inputs
**canonicalized** (normalize unicode, trim, fixed field order, fixed units) and built **only from fields
shared by both platforms**. **Critical gotcha:** `KilterLogEntry` has no stable id on Android
(`@PrimaryKey(autoGenerate=true) val id: Long`, `KilterEntities.kt:32`) — per-send `contentId` must
canonicalize `(climbUuid, difficulty, statusRaw, dayBucket(date), sessionId?)`, **never the row id**, or
dedup breaks across devices. The repo's existing `KilterCreatedClimb` golden-vector test is reused/extended.

### 3.5 Social-ready seams (what stays local now, what a future backend attaches to)

- **Stays local now:** everything. One actor (`self`), `visibility=private`, single fan-out-on-read over
  one timeline.
- **A future backend attaches to:** flip `actorRef` to a real userId (the entire read-side social change);
  aggregate multiple actors + apply the `visibility` filter; drain the outbox via WorkManager (Android) /
  `BGTaskScheduler` (iOS); use `aggregationKey` for "you and 3 others sent V4"; resolve `audienceTo`
  display-name tags to real accounts; `ShareEvent.channel` flips `export:*`→`user:*`. **No card view
  changes** — proven later by a single documented stub PR.

---

## 4. Card taxonomy

Availability legend: ✅ data exists today · 🟡 needs aggregation/small field · 🔶 needs new capture.
Platform: **iOS / Android**.

| Card | Trigger / eligibility predicate | Data source (availability) | Platform | Wave |
|---|---|---|---|---|
| **a1 Climb Session** | session has ≥1 `KilterLogEntry` | `KilterSession`+`KilterSessionStats` ✅ | iOS+Android | F1 |
| **a2 Workout Session** | `completedAt != nil` && ≥1 completed set | `WorkoutSession`+`SetLog` ✅ | iOS+Android | F1 |
| **a3 On-the-Board** | ≥1 `KilterLitEvent` AND no full session log | `KilterLitEvent` ✅ | iOS+Android | F5 |
| **b1 Grade PR** | send difficulty > all-time `maxGradeDifficulty` | `KilterAllTimeStats` ✅ | iOS+Android | F5 |
| **b2 First at Grade** | first-ever send at that grade band | log scan ✅ | iOS+Android | F5 |
| **b3 Most Climbs / Session** | session `totalClimbs` > prior max | `KilterSessionStats` ✅ | iOS+Android | F5 |
| **b4 Lift PR** | weight/est-1RM/volume > prior best per `exerciseId` | `SetLog.actualWeight/Reps` 🟡 | iOS+Android | F5 |
| **b5 Longest Streak PR** | current streak beats prior best | session-date scan ✅ | iOS+Android | F5 |
| **c1 Grade Pyramid** | ≥15 sends across ≥3 grades | `KilterAllTimeStats.pyramid` ✅ | iOS+Android | F5 |
| **c2 Pyramid Health** | a row narrower than the row above (top-heavy) | shape heuristic over c1 🟡 | iOS+Android | F6 |
| **c3 Grade Progression** | ≥3 months of sends | `maxGradeProgression` ✅ | iOS+Android | F6 |
| **c4 Climbing Level** | ≥20 recent sends | `climbingLevelLabel` ✅ | iOS+Android | F6 |
| **c5 Angle Distribution** | sends at ≥2 angles | `angleDistribution` ✅ | iOS+Android | F6 |
| **d1 Weekly Volume Trend** | ≥2 non-empty weeks | `sendsPerWeek` ✅ | iOS+Android | F6 |
| **d2 This Period vs Last** | two consecutive non-empty periods | `week/monthRollups` ✅ | iOS+Android | F6 |
| **d3 Discipline Split** | ≥2 disciplines in window | cross-session `disciplineRaw` roll-up 🟡 | iOS+Android | F6 |
| **d4 Trend Arrows** | ≥90 days history | 90-day rolling avg vs baseline ✅ | iOS+Android | F6 |
| **e1 Session Effort / Zones** | session has HR | iOS: `HRStats.secondsByZone`+`edwardsTRIMP` from `hrSeries`; **Android: avg/max/redline summary only** 🟡 | iOS full / Android summary | F2 |
| **e2 Hardest-Effort Send** | `hrSeries` non-empty AND a send aligns to a peak | `KilterSessionStats.timeline[].effort` 🟡 | **iOS only** | F2 |
| **e3 Avg & Peak HR Trend** | ≥3 sessions with HR | per-session HR summary 🟡 | iOS+Android | F2 |
| **e4 Effort-vs-Grade Efficiency** | ≥3 sessions, full series, same grade band | HR+grade+date trend 🟡 | **iOS only** | F6 |
| **e5 HRV / Recovery Nudge** | RR intervals present (chest strap) | `HRVMetrics` from `rrIntervalsMs` 🔶 | both engines exist, rarely eligible | F6 |
| **clipReady (auto-clip)** | ≥1 `SessionMedia` video + HR, `ReelPlan` non-empty | `SessionMedia`+`HighlightEngine`/`ReelPlanner` 🔶 | **iOS only** | F4 |
| **streak** | streak ≥3 days/sessions; protective framing | session dates ✅ | iOS+Android | F5 |
| **consistencyMap** | ≥14 active days | per-day counts ✅ | iOS+Android | F6 |
| **restNudge ("Go Gentler")** | N high-effort days w/o rest | HR-load (iOS) / volume-only (Android) 🔶 | iOS rich / Android coarse | F6 |
| **pyramidHealth / goalNudge insight** | derivable heuristic over pyramid | `KilterAllTimeStats.pyramid` 🟡 | iOS+Android | F6 |
| **onThisDay** | a send/session on this date in a prior year | dated log ✅ | iOS+Android | F6 |
| **g1 Project Sent** | climb `.project`→`.sent`/`.flash` | iOS: `attemptTimestamps`; Android: session-count fallback 🟡 | iOS rich / Android coarse | F6 |
| **weeklyRecap (Story)** | ≥1 session this week | week aggregate of B–E ✅ | iOS+Android | F6 |
| **monthlyRecap (Story)** | ≥1 session this month | `monthRollups`, Hevy-style ✅ | iOS+Android | F6 |
| **yearInClimb (Story)** | ≥6 months history | all-time year-scoped ✅ | iOS+Android | F6 |

Every synthetic card **degrades by absence**: a predicate needing HR/media the platform lacks never becomes
eligible — no stub. Crucially, the flagship insight cards (Grade PR, Pyramid, Year-in-Climb) ride on
`KilterAllTimeStats`, which **exists on both platforms** (iOS `KilterAllTimeStats.swift:27`; Android
`feature/kilter/KilterAllTimeStats.kt`), so Android's Recap ships a real "wow" card and isn't second-class.

---

## 5. The four user pillars (delivered through reused engines)

1. **Polished, shareable visual session-stat cards.** Every session is one rich `FeedCard` built from
   `PulsePro.DisciplineHero` (climbing-native hero: hardest grade / mini-pyramid, NOT a route map) +
   `StatRibbon` (fact triad) + `.snappetCard()` on `SnappetColor` tokens, discipline edge-accent
   (`SnappetColor.kilter`/`.workout`). The **ShareComposerCover** renders a named object-template library —
   **Send Card · Session Receipt · Grade PR Ticket · Board Polaroid · Pyramid Card** — on-device at exact
   9:16 & 4:5 (no cropping bug) → `ShareSheet.swift` (`UIActivityViewController`) / Android
   `Intent.ACTION_SEND`, IG Stories sticker, music omitted. *Engines/components reused:* `PulsePro.swift:11`
   (`DisciplineHero` `:11`, `StatRibbon` `:49`, `pulseGlassChrome` `:82`), `SnappetCard.swift:28`,
   `ShareSheet.swift`; Android `PulseColors`/`SnappetAccents` (`ui/theme/Color.kt:10`) **+ a new
   `pulseCard()` Compose modifier** (the one parity gap — components.md confirms no `.snappetCard()`
   equivalent exists on Android, so we build it as a tiny shared primitive).

2. **HR-deepened stats.** When `hrSeries` exists (iOS), e1/e2/e4 cards surface zone-banded sparklines,
   hardest-effort send, and effort-vs-grade efficiency ("sending V6 at lower HR than 3 mo ago") from
   `KilterSessionStats.timeline[].effort` + `HRStats.secondsByZone`/`edwardsTRIMP`; HRV/recovery (e5) from
   `HRVMetrics` when chest-strap RR is present. Android degrades to the summary band (`avgHr/maxHr/redline`)
   — a different *simpler payload*, not a degraded chart that renders empty. *Engines reused:* `HRStats`,
   `HRVMetrics`, `HeartRateZone` (iOS `HighlightEngine`; Android `feature/kilter/hr/HRSeries.kt:12`,
   `HeartRateZone.kt:9`), `KilterSessionStats` — verbatim on both platforms; the feed only surfaces.

3. **Auto-clip with HR overlay + name tagging.** iOS: a `clipReady` card on sessions with `SessionMedia`
   video + HR drives the ShareComposer's **Animate** path → `SessionHighlightInput`
   (`Features/WorkoutTracker/SessionHighlightInput.swift:29`) → `HighlightEngine`/`ReelPlanner` rank
   segments → `ReelExporter` (`Services/ReelExporter.swift:24`) + `AVVideoCompositionCoreAnimationTool` burn
   the HR overlay (reusing Glass-HUD `HRTile`/`StudioOverlays` styling). The inline auto-clip plays
   muted/looping for the card nearest viewport center (single active `AVPlayer`). **Name tags are structured
   `audienceTo` refs** — display name burned into the visual, the ref kept for future account resolution.
   Heeds the dossier gotchas: custom CALayer props don't export (drive built-in props only),
   layer-instruction background = clear, export off-main-thread with cancellable progress, music omitted.
   Android: clips are an honest **Stage-0 `ReelRoot`** placeholder (`feature/reel/ReelRoot.kt`, never a dead
   button) until the deferred Media3 Transformer wave. *Engines reused:* `HighlightEngine`, `ReelRanking`
   (Android `feature/reel/ReelRanking.kt:14`), `ReelExporter`, `PhotoClipRenderer`
   (`Services/PhotoClipRenderer.swift:15`), `SessionHighlightInput`.

4. **Creative cross-session insights.** The full insights menu realized through the eligibility-gated
   composer + the conditional scene engine: streaks/consistency (Gentler-protective framing), PRs (B1–B5),
   pyramid + health (C1/C2), progression/level (C3/C4), volume/trend arrows/discipline split (D1–D4), HR
   effort/efficiency (E1–E5), recaps/Year-in-Climb (via `RecapStoryCover`), projects/on-this-day (G1–G3).
   The feed *composes itself* from whatever the user has. *Engine reused:* `KilterAllTimeStats` (both
   platforms) + a small new cross-discipline workout aggregate following the `TodayDigest` pure pattern
   (`Features/Home/TodayDigest.swift`).

---

## 6. Both-platform plan & graceful degradation

**Identical on both** (the shared spine, golden-corpus tested): `FeedCard`/`FeedCardKind`/`FeedCategory`/
`FeedComposer` + all eligibility/salience predicates; `FeedActivity`/`Reaction`/`SaveItem`/`ShareEvent`
value types (Swift struct ↔ Kotlin data class, same field names); UUIDv5 namespaces + canonicalized inputs;
the named image-template share library (Pillar-1, needs no media/HR — **Android's strongest parity path**);
the Stories rail + Story Player (rides `KilterAllTimeStats`, present both sides); the freshness kit; the Wall.

**Differs (degrade-by-absence, never disabled UI):**

| Capability | iOS | Android | Feed behavior |
|---|---|---|---|
| Full `hrSeries` | ✅ | ❌ summary only | iOS: zone/TRIMP/per-climb cards; Android: e1/e3 summary payload; e2/e4 never compose |
| `SessionMedia` | ✅ | ❌ | iOS: inline auto-clip + clipReady; Android: card falls back to generated `DisciplineHero`; reel entry → Stage-0 `ReelRoot` |
| Reel export | ✅ AVFoundation | ❌ Stage-0 | iOS: Animate path; Android: image templates only (deferred Media3 wave) |
| HRV / RR | ✅ | engine ported, capture deferred | e5 iOS-only until Android BLE RR mainstream |
| Per-climb timing/notes | ✅ (`startedAt`/`attemptTimestamps`/`note`, `KilterModels.swift:251-305`) | ❌ (`KilterEntities.kt:30-46`) | iOS: rich timeline + project cadence; Android: pyramid+volume detail, g1 uses session-count fallback |
| **Workout HR** | ✅ `hrSeries` | **❌ none at all** (only `KilterSession` carries HR summary) | **Hard-gate workout-effort cards to iOS-only** |

**Hard rules (feasibility):** Android `WorkoutSession` stores *no* HR (`WorkoutModels.kt:271-301`) →
workout-effort cards are **iOS-only, full stop**. Per-climb-aligned cards check the *specific field absence*
(`hrSeries`/`attemptTimestamps`), not merely "has HR." Any banded-memoization invalidation logic must be
**byte-identical on both platforms** or the golden corpus passes while real scrolling diverges — so v1 keeps
composition simple and temporal; banding is added only if profiling demands it (and then test band
boundaries explicitly).

---

## 7. Phased plan — one PDD prompt = one PR

Keystone-first, iOS wave then Android wave. **Epic: "Recap Feed — self-composing session feed +
social-ready activity graph."** Each phase ships its committed feature prompt
(`pdd/prompts/features/feed/`), keeps `pdd/context/` true, records choices in `pdd/context/decisions.md`
the same day, and updates `docs/knowledge-graph/data.js` (add `tab-feed`/`feed`/`feed-composer`/
`feed-activity`/`story-player`/`feed-export`/`wall` nodes + `contains`/`navigate`/`uses`/`feeds` edges)
**in the same change**.

### Wave 0 — Pure foundations (the keystone; shared, no UI)

| Phase | Scope | Depends on | Issue |
|-------|-------|------------|-------|
| **F0 (KEYSTONE)** | `FeedCard` value type + `FeedCardKind`/`FeedCategory` + `FeedComposer.compose(...)` with eligibility/salience registry; session + PR + streak + pyramid + volume cards (no HR/media yet); recency-bounded salience. Pure, unit-tested, **iOS↔Android golden corpus**. | — | *"F0 FeedComposer keystone (pure)"* |
| **F0b** | `FeedActivity` @Model (iOS) + `Reaction`/`SaveItem`/`ShareEvent` value types + UUIDv5 namespaces + canonicalized `contentId` golden-vector + outbox table (additive). Append-only writers hooked into session-finish/climb-log. *Depends F0.* | F0 | *"F0b FeedActivity log + interaction rows + outbox"* |

### Wave 1 — iOS feed (lead)

| Phase | Scope | Depends on | Issue |
|-------|-------|------------|-------|
| **F1** | `FeedView` shell — tab wiring (`SuiteTab.feed`, `RootShell` `TabView`), `LazyVStack`, a1/a2 session cards on Pulse Pro, keyset `(published,id)` pagination, freshness kit (skeleton/optimistic-insert/"N new" pill/pull-to-refresh), Lens bar, Sessions-only lens. | F0 | *"F1 iOS FeedView + session cards + freshness"* |
| **F2** | HR-deepened cards (e1/e2/e3) + `CardDetailView` (reuse `KilterSessionStats`/HR zone chart); inline reactions/save (double-tap/long-press) + deep-link to source module. | F1 | *"F2 iOS HR cards + detail + reactions"* |
| **F3** | Inline media auto-clip (single active `AVPlayer` nearest center) from `SessionMedia`; media-first hero fallback chain. | F1 | *"F3 iOS inline auto-clip hero"* |
| **F4** | `ShareComposerCover` + named template library (image, 9:16/4:5) → `ShareSheet`; **Animate** path (`clipReady` → `ReelExporter` HR-overlay burn, structured tag refs); append `ShareEvent`. | F2, F3 | *"F4 iOS ShareComposer + auto-clip export"* |
| **F5** | Synthetic cards wave-1 (a3/b1–b5/c1/streak) — predicates in `FeedComposer`. | F1 | *"F5 iOS milestone/PR/streak cards"* |
| **F6** | `RecapStoryCover` (Wrapped grammar) + Stories rail + weekly/monthly/Year-in-Climb + remaining insight cards (c2–c5/d1–d4/e4–e5/consistency/restNudge/onThisDay/g1). | F5 | *"F6 iOS Story Player + insight/recap cards"* |
| **F7** | `WallView` masonry send-wall + grid toggle. | F1 | *"F7 iOS Wall/send-wall"* |

### Wave 2 — Android parity

| Phase | Scope | Depends on | Issue |
|-------|-------|------------|-------|
| **FA0** | Kotlin port of `FeedComposer`/`FeedCard`/eligibility against the shared golden corpus (JVM-tested). | F0 | *"FA0 Android FeedComposer port"* |
| **FA0b** | `pulseCard()` Compose modifier (shared primitive) + `FeedActivity` Room @Entity (v7→v8 **additive** migration) + interaction rows + outbox + write seam. | F0b, FA0 | *"FA0b Android pulseCard + FeedActivity migration"* |
| **FA1** | `FeedScreen` shell — `RootShell.kt` third tab, `LazyColumn`, session cards, Paging 3 keyset, freshness kit, Lens bar. | FA0, FA0b | *"FA1 Android FeedScreen + cards"* |
| **FA2** | HR summary cards (e1-summary/e3) + `CardDetailScreen` + reactions/save + deep-link. | FA1 | *"FA2 Android HR-summary + detail + reactions"* |
| **FA3** | `ShareComposerScreen` — image templates only → `ACTION_SEND`; reel entry routes to Stage-0 `ReelRoot`. | FA1 | *"FA3 Android image-template share"* |
| **FA4** | Synthetic cards wave-1 (non-HR/non-media) + Story Player + Stories rail (eligible scenes only; media/zone scenes auto-skip). | FA1 | *"FA4 Android milestones + Story Player"* |
| **FA5** | `WallScreen` (`LazyVerticalStaggeredGrid`). | FA1 | *"FA5 Android Wall"* |

**Phasing realism.** **F0 first** (it's the spine of every render). F0b can land right behind it. On iOS,
F3 and F5 are independent of F2 and can run in parallel after F1; F4 needs both F2 and F3. The whole Android
wave forks from F0/F0b. Per the highest-risk rule, **wireframe + prototype the Story Player (F6) first** even
though it lands late.

### Deferred (own future epics, explicitly out of scope now)

- **Android Media3 Transformer auto-clip** (Pillar-3 device pipeline, Stage-1).
- **HRV/recovery** once chest-strap RR is mainstream on Android.
- **Social seam stub PR** — `actorRef=.user`, drain outbox via WorkManager/`BGTaskScheduler`, hybrid
  fan-out; proves zero card-view change.

---

## 8. Reusable hooks (what we lean on, not rebuild)

| Need | Reuse (file ref) |
|------|------------------|
| Per-session card payload (pyramid, timeline, hardest send, HR effort) | `KilterSessionStats.make(...)` — iOS `KilterSessionStats.swift:40`; Android `feature/kilter/KilterSessionStats.kt` |
| PR/pyramid/progression/level/volume/rollup cards + Year-in-Climb (both platforms) | `KilterAllTimeStats.make(...)` — iOS `KilterAllTimeStats.swift:27`; Android `feature/kilter/KilterAllTimeStats.kt` |
| Zone breakdown, TRIMP, redline (summary on Android) | `HRStats` / `HeartRateZone` — Android `feature/kilter/hr/HRSeries.kt:12`, `HeartRateZone.kt:9`; iOS `HighlightEngine` |
| e5 recovery/HRV (RR present) | `HRVMetrics` — Android `feature/kilter/hr/HRSeries.kt:72`; iOS `HighlightEngine` |
| Rank/plan auto-clip segments (iOS) | `HighlightEngine` / `ReelPlanner` / `SessionHighlightInput` — `SessionHighlightInput.swift:29`; `ios/HighlightEngine` |
| Pure clip ranking core (parity, JVM-tested) | `ReelRanking` — Android `feature/reel/ReelRanking.kt:14` |
| HR-overlay clip export (iOS) | `ReelExporter` / `PhotoClipRenderer` — `Services/ReelExporter.swift:24`; `Services/PhotoClipRenderer.swift:15` |
| Honest "Clips coming to Android" entry (no dead button) | `ReelRoot` Stage-0 — Android `feature/reel/ReelRoot.kt` |
| Inline media hero + clipReady eligibility (iOS) | `SessionMedia` / `SessionMediaService` — `SessionMedia.swift:23`; `Services/SessionMediaService.swift:14` |
| Card hero + stat triad + Story chrome | `PulsePro` (`DisciplineHero` `:11` / `StatRibbon` `:49` / `pulseGlassChrome` `:82`) — `DesignSystem/PulsePro.swift:11` |
| Card surface, edge accents, performance/zone ramp | `.snappetCard()` / `SnappetColor` — `DesignSystem/SnappetCard.swift:28`; `DesignSystem/SnappetColor.swift` (`performance(for:)` `:83`, `performance(forZone:)` `:91`) |
| Glass-HUD HR overlay styling (WYSIWYG preview = export) | `HRTile` / `StudioOverlays` — `Features/WorkoutTracker/HRTile.swift:13`; `Services/StudioOverlays.swift:121` |
| OS share-sheet handoff (iOS); `ACTION_SEND` mirror on Android | `ShareSheet` — `Features/Shell/ShareSheet.swift` |
| Android card parity (new shared primitive) | `PulseColors`/`SnappetAccents` (`ui/theme/Color.kt:10`) **+ new `pulseCard()` modifier** |
| The derive-on-read pure-aggregation template `FeedComposer` follows | `TodayDigest` — `Features/Home/TodayDigest.swift` |
| Third-tab insertion + deep-link | `SuiteRouter`/`RootShell` — `SuiteRouter.swift:5`; `RootShell.swift:160`; Android `ui/RootShell.kt:75` |
| Cross-platform content-identity discipline | `KilterCreatedClimb` UUIDv5 golden-vector test — iOS `KilterCreatedClimb.swift:87`; Android `KilterEntities.kt:135` |

---

## 9. Testing strategy (pure-logic-first, per CLAUDE.md)

- **Golden-corpus cross-platform (the keystone test).** One shared corpus of raw sessions/logs → ordered
  `FeedCard`s out, asserted **byte-identical** on iOS (XCTest) and Android (JVM) — modeled on the existing
  `KilterCreatedClimb` UUIDv5 golden-vector discipline. This is what proves "same engine, two eligible
  sets" and catches any cross-platform divergence in eligibility, salience ordering, recency bounding, or
  `contentId` canonicalization. Includes the `KilterLogEntry`-has-no-stable-id case explicitly.
- **Pure-engine unit tests (no simulator/device).** `FeedComposer` eligibility predicates (each card's
  trigger + the absence/degrade path), salience × recency-decay ordering, recency-bound invariant (a card
  never anchors older than its trigger), per-period scoping for the Story Player, `contentId`
  canonicalization, and any new cross-discipline workout aggregate (following the `TodayDigest` /
  `KilterAllTimeStats` pure pattern). Interaction-row append/dedup (`Reaction`/`SaveItem`/`ShareEvent`).
- **Migration / backup.** `FeedActivity` + interaction rows + outbox are new SwiftData @Models (iOS) and a
  new Room v7→v8 **additive** migration (Android) — require the backup mirror + codec-coverage tripwire
  green; **no card-table migration** (cards stay derive-on-read).
- **UITests (simulator/emulator).** Feed scroll + keyset paging + freshness pill; Lens-bar filtering +
  Sessions-only; card → detail → deep-link; double-tap react / long-press save; Story Player tap-through; the
  ShareComposer template picker + aspect/metric toggles (preview only in sim).
- **UI-suite policy.** F0/F0b/FA0 (pure logic + additive schema) gate on unit + golden corpus +
  build-for-testing + review ([[ui-suite-policy-logic-only-prs]]); UI phases run XCUITest/Compose UITest. The
  sim can wedge (`xcrun simctl shutdown all`, [[uitest-event-synthesize-flake]]).
- **Device-burn list (honesty rule).** Confirmable only on real hardware (MrRobot): the iOS `ReelExporter`
  HR-overlay clip burn + `AVVideoCompositionCoreAnimationTool` export (F4), the inline-clip single-
  `AVPlayer`-nearest-center behavior (F3), the real OS share-sheet / IG-Stories-sticker handoff and the
  9:16/4:5 exact-dimension render (no Apple cropping bug), and chest-strap RR → HRV (e5). Keep all new logic
  pure + unit-tested so each PR ships green without hardware.

---

## 10. Scope guards & non-goals

**Non-goals (v1):** no backend, no accounts, no network, no real likes/comments/followers, no fan-out
worker (the outbox stays empty), no Android reel/clip device pipeline (Stage-0), no Android workout HR, no
muscle-tagging/muscle-balance cards (need new capture), no in-app music (handoff to IG/CapCut), no banded
memoization unless profiling demands it (keep v1 temporal). **"Share" = export to the OS share sheet only.**

**Top risks & mitigations:**

- **Story Player is highest-wow, highest-execution-risk.** *Mitigation:* wireframe + prototype it **first**
  (the [[wireframe-before-implementation]] rule applies hardest here); ship per-scene shareability so even a
  3-scene sparse story feels complete.
- **Salience "floating" feels unpredictable.** *Mitigation:* recency-bound every card (never older than its
  trigger) + always-available "Sessions-only" lens for the comfortable chronological stream.
- **Cold-start: strict predicates → empty Recap.** *Mitigation:* a lively sparse/new-user state ("log more
  to unlock insights" hint, not an empty wall) + aggressively seed early-eligible cards (first session,
  first streak-of-3, on-this-day).
- **Cross-platform delight gap (auto-clip/HR-zone iOS-only).** *Mitigation:* the flagship cards (Grade PR,
  Pyramid, Year-in-Climb) ride `KilterAllTimeStats` on both platforms; verify Android Recap ships a real wow
  card.
- **Sharing is device-pending & untestable in sim; Apple cropping bug.** *Mitigation:* render at exact
  9:16/4:5 dimensions, off-main-thread with cancellable progress; gate device-only paths behind the honest
  Stage-0 entry; flag as device-burn items.
- **`KilterLogEntry` has no stable id; cross-platform `contentId` inputs differ.** *Mitigation:* canonicalize
  per-send `contentId` from shared fields only `(climbUuid, difficulty, statusRaw, dayBucket, sessionId?)`;
  golden-vector test **before any UI**.
- **Self-targeted reactions feel hollow.** *Mitigation:* frame as private memory/curation (collections,
  react-as-note), never social-like mimicry.
- **Room v7→v8 migration for the activity log.** *Mitigation:* keep it strictly **additive** (new tables, no
  column drops); `FeedCard` itself stays derive-on-read (no card-table migration).

---

## 11. Wireframes

Real `SnappetColor`/`PulseColors`/Pulse-Pro tokens, dark-mode-first, rendered HTML→PNG, kept under
[wireframes/](./wireframes/) with the source in [wireframes.html](./wireframes.html). **Prototype #8 (Story
Player) FIRST** per the highest-risk rule.

1. **Feed root — rich state** — Stories rail + Lens bar + interleaved a1 session / b1 Grade PR / c1 pyramid / e1 effort cards (the hero shot).
2. **Feed root — sparse / new-user state** — 1 session card + "log more to unlock insights" composer hint (not an empty state).
3. **Feed root — Android degraded** — same layout, no media thumbs, summary-only effort card (proves graceful parity).
4. **Feed root — freshness** — "New recap ready / N new sessions" pill + skeleton cards + pull-to-refresh.
5. **a1 Climb Session card** (iOS) — DisciplineHero hardest-grade + StatRibbon triad + mini grade-pyramid + edge accent + HR sparkline + reactions strip.
6. **a1 Climb Session card — no media** — generated DisciplineHero hero fallback chain.
7. **a2 Workout Session cards** — strength (volume hero) and running (distance/pace) variants.
8. **RecapStoryCover — Year in Climb** — 3 scenes (cover → grade-journey/progression → pyramid reveal), Spotify-grammar full-bleed. *(prototype first)*
9. **b1 Grade PR card** — celebratory "V7 · YOUR HARDEST EVER" with accent halo.
10. **c1 Grade Pyramid card** + **c2 Pyramid Health** plain-language nudge.
11. **e1 Effort card — iOS stacked-zone** vs **e1 Effort card — Android avg/max**, side by side (proves degradation).
12. **streak / consistencyMap card** — Gentler-protective framing ("Go Gentler" rest-nudge variant).
13. **onThisDay memory card** — "1 year ago you sent your first V5" + react-as-note interaction.
14. **CardDetailView** (Kilter) — full card + expandable timeline + HR zone chart + media row + reactions + Share/Open buttons.
15. **WallView / send wall** — masonry portfolio grid.
16. **ShareComposerCover — template picker** — Send Card / Receipt / Grade PR Ticket / Board Polaroid / Pyramid Card thumbnails.
17. **ShareComposerCover — live preview** at 9:16 with HR overlay (iOS animated-clip variant) + aspect (9:16/4:5/1:1) + metric toggles.
18. **Exported share assets** — a 9:16 "Send Ticket" and a 4:5 "Session Receipt" as they'd land in IG Stories / iMessage.
19. **Reaction / Save micro-interactions** — double-tap react, long-press save-to-collection states.
20. **Media/clip card — Android Stage-0** — honest "Clips are coming to Android" placeholder.
21. **Tab bar — 3-tab state** (Today / Recap / Apps) for both platforms.
22. **Empty state** — no sessions yet → CTA into Kilter/Workout modules.

---

## 12. Obligations on implementation (CLAUDE.md)

- **PDD:** one feature prompt per phase under `pdd/prompts/features/feed/`, committed with the code; keep
  `pdd/context/` true; record decisions the same day.
- **Knowledge graph:** every new/changed surface (the Recap tab, `FeedView`/`FeedScreen`, `FeedComposer`,
  `FeedActivity`, the Story Player, the ShareComposer, the Wall) gets a `nodes` entry + `links` edge in
  `docs/knowledge-graph/data.js` **in the same change** (added per phase at build time, not in this planning
  PR — don't let the graph claim unbuilt surfaces).
- **Platform purity:** `FeedComposer` + `FeedCard` + all eligibility/salience predicates stay pure value
  types (device-free tests); `HighlightEngine` stays platform-free; PhotoKit / AVFoundation / CoreBluetooth
  live behind the service edge.
- **Android:** its own wave after the iOS lead, as stacked PRs (model + Room migration + backup mirror).

---

## 13. GitHub issues

This plan maps to an **epic** (tracking) issue + child issues for **F0/F0b** (keystone), **F1–F7** (iOS), and
**FA0/FA0b–FA5** (Android parity), plus deferred follow-ups (Android Media3 auto-clip, HRV capture, the
social-seam stub). See the parent PR / the epic for the live links.

---

*Built on the real code — iOS + Android data-model maps, the shared-component inventory, and a three-direction
judge-panel synthesis (B = self-composing spine, C = social-ready foundation, A = everyday texture). Every
cited `file:line` was checked against the dossier.*

---

## Addendum (review feedback): Session media carousel

The original deck showed only the single auto-edited **highlight** per session. Per review, the session card also surfaces an **Instagram-style carousel of *all* media** shot during the session — the auto-edit becomes "clip 1", not the only view.

**Three surfaces** (wireframes Flow 9 — `card_carousel.png`, `media_grouped.png`, `media_viewer.png`):
1. **Carousel on the card** — swipeable, dots + count, each clip with a per-clip HR overlay + exercise/climb name tag.
2. **Grouped media browser** — a `By exercise · By session · All` toggle; rails bucketed per exercise/climb, each tile with a peak-HR badge.
3. **Fullscreen viewer** — Instagram-post style, swipe between clips, live HR overlay (peak BPM + zone band), `Share / Animate` burns the overlay in.

**Why it's cheap — `SessionMedia` already has the fields** (`ios/App/Snappet/Features/WorkoutTracker/SessionMedia.swift:23`):
| Need | `SessionMedia` field |
|---|---|
| Split by exercise / climb | `assignedExerciseID` · `assignedSetIndex` · `assignedClimbUUID` (+ `assignmentSourceRaw` auto/manual) |
| Per-clip HR overlay window | `offsetSec` + `durationSec` → aligned to `KilterSession.hrSeries` (Kilter) / HealthKit (gym) |
| Photo vs video | `kindRaw`; asset via `localIdentifier` (PHAsset) |

**Phase:** new **F3b** (#227, iOS, depends on F3 #212). **Android is gated on porting `SessionMedia`** (current parity gap — no media attach on Android yet), tracked under #225; until then Android keeps the honest Stage-0 clips entry + image-template share. The carousel grouping/HR-alignment logic is pure and unit-tested; the AVFoundation overlay export is a device-burn item.
