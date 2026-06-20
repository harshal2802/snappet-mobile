# Kilter Improvement — your climbing record, made smart

> **Snappet Mobile** · Kilter module (`kilter`) · 2026-06-19
>
> A focused, phased upgrade of the Kilter mini-app across **five** "memory & understanding" surfaces:
> **(1) auto-detect the board you're on**, **(2) a gallery of the climbs you set**, **(3) a redesigned
> usage-stats & analysis dashboard**, **(4) a redesigned session history**, and **(5) a brand-new history
> of every climb you lit on the board**. This is the **planning** deliverable — research, design
> direction, logical flows, wireframes, and a phased PDD plan — to review **before any implementation**
> (CLAUDE.md / the [[wireframe-before-implementation]] rule).
>
> | File | What it is |
> |------|------------|
> | **README.md** (this) | The design direction + the keystone + the per-surface design + the phased plan. |
> | **[wireframes.html](./wireframes.html)** | **Open in a browser** — real-looking iPhone surfaces for all 5 flows (11 screens), real `SnappetColor` tokens, dark-mode-first. The visual deliverable. |
> | **[wireframes/](./wireframes/)** | Rendered PNGs (real tokens, 2×). |
> | **[research-appendix.md](./research-appendix.md)** | The design + technical research (Aurora/Kilter BLE, BoardLib, Whoop, 8a/KAYA, Stōkt, Hevy, Gentler Streak, Strava) with citations. |
>
> *Derived from a **13-agent deep-research workflow** (6 file:line code maps + 5 design sweeps + a synthesis
> pass + a board-detection feasibility adversary). Every `file:line` below was checked against source.
> Paths are under `ios/App/Snappet/Features/Kilter/` unless noted.*

---

## TL;DR

**The problem.** The Kilter feature is a strong browse-and-log mini-app, but its "memory & understanding"
surfaces are thin and inconsistent:

- **Board selection is 100% manual.** Layout/size/angle live in three `@AppStorage` keys
  (`kilter.layout` / `kilter.productSizeId` / `kilter.angle`, `KilterRootView.swift:39-46`) and re-picking
  on every visit is friction — even though `KilterBoardController` **already** persists a stable per-board
  identity (`kilter.lastBoardID`, captured on a confirmed connect at `KilterBoardController.swift:329`)
  that it does **nothing** with.
- **"Climbs I set" is buried.** It exists only as the layout-scoped **Mine** filter, rendered in a
  text-only row with no board thumbnail — and climbs set on *other* layouts silently vanish. The lit-holds
  render (`KilterBoardView.swift:13-15`) that *is* a climb's identity is never used in a list.
- **There is no climbing analytics dashboard.** All cross-session math is hand-rolled, untested inline
  code in `KilterHistoryView.swift:59-78`; the pure, tested per-session engine
  `KilterSessionStats.make` (`KilterSessionStats.swift:105`) is **never aggregated** by any caller.
- **Session history is one flat reverse-chron list** (`KilterHistoryView.swift:166`) with no grouping,
  search, filter, session naming, or metadata editing.
- **Lighting a climb on the board is recorded nowhere.** `KilterBoardController.illuminate(holds)`
  (`:197`) is a transient BLE write; the controller keeps only the *most-recent* holds in memory (`:54`).
  Every climb you pulled up and worked but didn't formally log is **invisible**.

**The fix.** Treat all five as one coherent, **on-device** "your climbing record" system on the Pulse Pro
language. Lift the per-session `KilterSessionStats` engine into a pure all-time aggregator
(`KilterAllTimeStats`) — the **keystone** that feeds three of the five surfaces. Generalize the existing
single-board memory into a `KilterBoardMemory` that recognizes a board you've connected to before
(BLE identifier + coarse on-device location). Promote "Mine" into a first-class **Your Climbs** thumbnail
gallery. Redesign the dashboard and history on top of the aggregator. And capture a lightweight
**lit-event** at the `illuminate()` call sites to power a new **On the Board** history.

**Everything is on-device.** No backend, no network, no accounts. The pure cores stay device-free +
unit-tested per CLAUDE.md.

---

## 1. Decisions locked with the user (2026-06-19)

| Question | Decision |
|----------|----------|
| **What does "auto-detect board based on gym" mean?** | The BLE advert carries **no** layout/size, and angle is **never** transmitted — so detecting a *never-seen* board is impossible on-device. Reframed to **recognize a board you've connected to before**, by its **BLE identifier + `#serial`** *and* a **coarse CoreLocation place** (**Option B**), to suggest your board *on arrival* and disambiguate two boards at one gym. Coarse place stored on-device, **never uploaded**. |
| **Session naming + notes?** | **Yes — name + notes + date/angle edit**, via *additive optional* fields on `KilterSession` (lightweight migration), mirroring the gym tracker's all-axis edit (commit `6f8d2a9`). |
| **What counts as "your climbing"?** | **Kilter-board only** (`KilterLogEntry` / `KilterCreatedClimb`), matching today's History — not folding in Quick-Session freeform climbing. Cleanest scope. |
| **Consistency surface?** | **Both** a GitHub-style heatmap **and** a tappable month calendar. |
| **Lit-on-board history?** | **Yes — a new Phase P5.** Capture a deduped lit-event at the `illuminate()` call sites; surface an "On the Board" timeline + a "Recently on the board" re-light rail. |

---

## 2. The keystone — one pure aggregator feeds three surfaces

```
            TODAY                                          AFTER

  KilterSessionStats.make([KilterClimbLog])     KilterAllTimeStats over the full @Query of
    pure, tested, PER-SESSION   ── never ──┐      KilterLogEntry (bridged via KilterClimbLog.from)
    aggregated by any caller (:105)        │                      │
                                           │      ┌───────────────┼────────────────┐
  KilterHistoryView inline math  ── untested ──┘  Analytics dash  Session-history   Adaptive
    total sends / this-month / hardest /          (P3): hero,     roll-up headers   session-card
    CSS-bar pyramid (:59-78)                       pyramid, rings  (P4)              facts (P4)
```

`KilterAllTimeStats` is a **value type with no SwiftData/device dependency**, so it unit-tests in
`SnappetTests` exactly like `KilterSessionStatsTests` — and **requires zero schema change** (it recomputes
from queried rows). Building it first (P0) lets the dashboard (P3) and history (P4) consume tested
aggregates instead of re-deriving math in the view, and it **deletes** the untested inline aggregation in
`KilterHistoryView`.

---

## 3. The Pulse Pro design direction (these five surfaces)

1. **One hero numeral per surface** (`DisciplineHero`, accent `SnappetColor.kilter` amber): dashboard =
   Climbing Level; session detail = hardest send; gallery header = "N climbs set"; On the Board = "climbs
   worked". Everything else demotes to a `StatRibbon` (≤3 chips) or flat tiles — never a grid of co-equal
   numerals.
2. **Two color axes stay air-gapped.** `SnappetColor.kilter` amber is **wayfinding only**; the performance
   ramp `perfFresh → perfModerate → perfHard` (`SnappetColor.swift:73-77`) is **effort/state only**
   (grade-pyramid bands, deltas, zones, PR glow); **coral (`brand`) is the single primary CTA / "today"
   marker per surface.** Never paint a whole card in an accent — accents are edge-bars, dots, badges,
   hairlines, numerals.
3. **Identity = glyph + label + shape, never color alone.** Ascent style (flash / send / project / attempt)
   always carries an icon + word; hold roles render as colored rings; board provenance (BLE vs Manual,
   Hand-set vs Generated, 📍 place) is a glyph+label capsule. Verify dark-mode contrast against the
   warm-neutral `#1E1E22` surface, not `#000`.
4. **Glass only on floating chrome** (`pulseGlassChrome`, `PulsePro.swift:82-112`): the detection-confirm
   ribbon, the live-session ribbon, command/filter bars. Content cards stay flat (`snappetCard` /
   `snappetTile`) with `SnappetColor.hairline`.
5. **Tile-as-doorway, three tiers on separate screens.** Dashboard tiles = headline + sparkline → full
   trend screen → raw per-session/per-ascent. Session card = 3-4 adaptive facts; detail = full replay.
6. **The grade pyramid is the signature visual** and the one place to invest: promote it from a CSS-bar
   capsule list (`KilterHistoryView.swift:59-78`) to a Swift Charts `BarMark` (reuse `ClimbGradePyramid`,
   `FreeformClimbSummaryComponents.swift:31`), order easiest→hardest, segment by style (flash | send |
   project) with **pattern + label, not hue alone**, and a dashed current-max marker; tap a grade to filter.
7. **Auto-detect is a smart suggestion, never a silent overwrite** that fights a deliberate manual pick:
   a recognized board pre-applies its remembered layout/size through
   `catalog.effectiveSizeId(forLayout:requested:)` (`KilterCatalog.swift:460-465`) and pre-selects the
   usual angle, but always shows a one-tap confirm/adjust (angle is physically mutable and **never**
   electronically readable).
8. **Frame consistency kindly** (Gentler Streak): "weeks climbed" + trend-vs-baseline, rest days are
   legitimate; heatmap uses one amber intensity ramp on hairline-outlined empty tiles, "today" in coral.
9. **Every empty/no-result state is a designed surface** (`ContentUnavailableView`): brand icon
   (`figure.climbing`), ≤3 sentences, one CTA.

---

## 4. Per-surface design (see [wireframes.html](./wireframes.html))

### Auto-detect board on arrival — Flow 1 (P1)
**The honest scope** (from the feasibility adversary): every external source agrees the Aurora/Kilter BLE
advert carries **no** layout/size, and **angle is never transmitted** (it's always a manual in-app pick).
So "detect a never-seen board" is impossible on-device. What *is* buildable — and what removes the real
friction — is recognizing a board **this phone has connected to before**.

Generalize the single `kilter.lastBoardID` (`KilterBoardController.swift:329`, already captured + already
re-used as a reconnect key) into a pure **`KilterBoardMemory`** — a `UserDefaults` map keyed on
`CBPeripheral.identifier` (+ the parsed advertised `#serial` token as a reinstall cross-check), modeled
**1:1 on `BandMemory`/`BLEBands`** (`Services/`), carrying `{layoutId, sizeId, angleHistory, label,
coarsePlace, lastSeen}`. On a confirmed connect to a known board, silently restore layout + size by writing
the shared `@AppStorage` keys through `catalog.effectiveSizeId` (`:460-465`, the validity chokepoint so
render + LED map agree) and pre-select the most-frequent angle; surface a non-blocking `pulseGlassChrome`
ribbon to confirm/adjust the angle. **Option B** adds **CoreLocation**: a coarse place fingerprint
(rounded, raw, never reverse-geocoded, never uploaded) lets the app suggest your usual board **on arrival,
before BLE connects**, and disambiguates two boards at one gym. First-ever board/place stays today's
one-time manual pick. A "Remembered boards" section in Settings manages labels / forget / the location
permission. *Reuse: `BandMemory`+`BLEBands` (the exact remember-device + pure-rules + suppress/forget
template); `KilterBoardController` identifier capture + `isLikelyBoard`; `effectiveSizeId` + `syncBoardSize`
(`KilterRootView.swift:321-328`); `@AppStorage kilter.*` keys; `pulseGlassChrome`; `SessionExercise.gym`
to seed wall/gym from the board label.*

### Your Climbs — Flow 2 (P2)
Promote the buried layout-scoped **Mine** filter into a first-class **Your Climbs** route: a `DisciplineHero`
"N climbs set" header + a coral "Set a climb" CTA, then a **2-up board-thumbnail grid** (each cell a cached
`KilterBoardView(geometry:holds:)` from `catalog.holds(for:sizeId:)` — the lit-holds render *is* the climb's
identity, never used in a list today), **global across layouts** (a board facet, so climbs on other layouts
don't vanish), a **Draft/Saved** status segment, filter + sort, the user's **own** logbook status per climb
(count `KilterLogEntry where climbUUID == created.uuid` — never community signals, none exist on-device), and
per-card **Edit / Duplicate / Share / Delete**. Delete is guarded — it **keeps logged ascents**
(`KilterCreatedClimb.delete`). Tapping a card pushes the existing climb detail unchanged. *Reuse:
`KilterCreatedClimb` `@Model` + `asClimb`; `KilterBoardView` as a per-cell thumbnail; `KilterShareView` QR;
`KilterDuplicateChecker`; `DisciplineHero`/`StatRibbon`.* *Scope guard: prefer **deriving** a Draft state
from a failed `kilterValidate` over adding a schema field.*

### Climbing analytics dashboard — Flow 3 (P0 + P3)
A new `KilterStatsRoute` consuming `KilterAllTimeStats`: a tier-1 hero **Climbing Level** (seeded from
`KilterRecommender.workingDifficulty`, `:147-155`, windowed) with a perf-ramp delta; then doorway tiles —
the signature **segmented grade pyramid** (Swift Charts, flash/send/project, dashed max, tap-to-filter),
**send/flash rings**, a **volume / sends-per-week trend** (clone `WorkoutDashboardSection.volumeChart`,
`WorkoutDashboardSection.swift:207`, with range chips + vs-previous ghost), a **max-grade progression**
step-line, **attempts-to-send velocity**, and an **angle distribution** (a defining Kilter dimension never
aggregated today). All numbers come from the pure aggregator — no inline view math. The old
`KilterHistoryView` inline aggregation is **deleted** and History links here. *Reuse: `KilterSessionStats`
lifted; `ClimbGradePyramid`/`ClimbEffortSection`/`ClimbTimelineList`; `WorkoutHRStats`+`HeartRateChart`+
`ZoneBar`; `DisciplineHero`/`StatRibbon`.*

### Redesigned session history — Flow 4 (P0 + P4)
Regroup `KilterHistoryView` into **month/week/all** buckets whose sticky headers double as **roll-ups**
("June — 7 sessions · 41 sent · hardest V7", from `KilterAllTimeStats`), a scope switcher, **faceted
filters** (board/angle/grade/status/source) + search with **stale-filter recovery**, **both** a consistency
heatmap **and** a tappable month calendar (each doubling as navigation), and **adaptive 3-4-fact session
cards** (one badge max — Strava rule). Session detail gains **naming + notes + date/angle edit** via
*additive optional* fields on `KilterSession` (lightweight migration), mirroring the gym tracker all-axis
edit. The detail route + `KilterSessionManager.end/recover` lifecycle stay unchanged. *Reuse:
`KilterSession.sessionId` join (`KilterHistoryView.swift:166`); `KilterAscentRow` (`:194`);
`kilterDisplayGrade` (`KilterSessionDetailView.swift:631`); the WorkoutTracker month-group + faceted-chip +
stale-filter-recovery patterns as the template.*

### On the Board — Flow 5 (P0 + P5) — **new**
Lighting a climb on the board (`KilterBoardController.illuminate`, `:197`) is transient and recorded nowhere
(`:54` holds only the most-recent holds). Capture a lightweight **lit-event** at the `illuminate()` **call
sites** (where the climb identity is known — `KilterClimbDetailView.swift:545/725`, optionally the guided
player), deduped per climb-per-session so it stays bounded: `{climbUUID, climbName, gradeLabel, angle,
layoutId, sizeId, litAt, wasConnected}`. Surface an **On the Board** timeline of every climb you actually
pulled up & worked — **including the ones you never logged** — grouped by day/session, with **status joined
from your ascent log** (Lit / Attempt / ✓ Sent) and **one-tap re-light**; plus a "Recently on the board"
re-light rail on the Kilter root to resume a project instantly. *Reuse: `KilterBoardController.illuminate`
as the capture hook; `KilterBoardView` thumbnails; `KilterLogEntry` join for status; the canonical
`board.illuminate(holds)` for re-light.* *New: a `KilterLitEvent` `@Model` (additive — incurs the
`SnappetSchema` + `SnappetBackup` mirror cost, with `KilterSessionRow` as the copy-paste template).*

---

## 5. Phased plan — one PDD prompt = one PR

> Each phase ships a committed feature prompt (`pdd/prompts/features/kilter-improvement/`), keeps
> `pdd/context/` true, records choices in `pdd/context/decisions.md` the same day, and updates
> `docs/knowledge-graph/data.js` (nodes + edges for every new/changed surface) **in the same change**.

| Phase | Scope | Depends on | Tested by |
|-------|-------|------------|-----------|
| **P0** | **Keystone.** Pure `KilterAllTimeStats` over `[KilterClimbLog]` (send/flash rate, attempts-to-send velocity, max-grade progression, sends-per-week, angle distribution, per-period roll-ups); extend `GradeCount` with attempt/project counts; formalize the ascent-style color vocabulary. **No UI, no `@Model` change.** | — | `KilterAllTimeStatsTests` (pure, no sim) |
| **P1** | **Board detect.** `KilterBoardMemory` (BLE identifier + `#serial`) **+ CoreLocation** coarse-place match; restore-on-recognize through `effectiveSizeId`; confirm ribbon; "Remembered boards" + location permission in Settings. | — | `KilterBoardMemoryTests` (pure, injectable UserDefaults); BLE/location legs device-pending |
| **P2** | **Your Climbs.** First-class gallery (thumbnail grid, global-across-layouts, status segment, filter/sort, own-logbook status, Edit/Duplicate/Share/Delete). | — | unit: query/sort/filter helper; UITest |
| **P3** | **Analytics dashboard.** Tiered Pulse Pro dashboard on `KilterAllTimeStats`; segmented pyramid; rings; trends; angle distribution; **delete** inline History math. | P0 | unit: any new pure helper; UITest |
| **P4** | **Session history.** Grouped/scoped/filterable timeline + heatmap + calendar + adaptive cards; **naming + notes + date/angle edit** (additive `KilterSession` fields). | P0 | unit: bucketing/scope/filter + adaptive-fact helpers; backup tripwires; UITest |
| **P5** | **On the Board.** Instrument `illuminate()` → `KilterLitEvent` (`@Model`); lit-history timeline + status join + re-light rail. | P0 | unit: dedup/grouping/status-join helpers; backup tripwires; UITest |
| **H** | **Hardening + Android.** Device burn-in (MrRobot: the BLE + CoreLocation legs); the Android wave (model + Room migration + backup mirror). | P1–P5 | manual device pass; Android suites |

**Phasing realism.** **P0 first** (it's the spine of P3+P4). P1, P2 are independent and can run in parallel.
**P3 before P4** — both touch `KilterHistoryView` (P3 deletes its inline math, P4 regroups it), so sequence
or coordinate to avoid a merge collision. P5 depends only on P0. Android is its own multi-PR wave.

---

## 6. Reusable hooks (what we lean on, not rebuild)

| Need | Reuse |
|------|-------|
| All-time climbing analytics | Lift `KilterSessionStats.make` (`KilterSessionStats.swift:105`) into `KilterAllTimeStats` via `KilterClimbLog.from` (`:200`) |
| Signature grade pyramid | `ClimbGradePyramid` + `GradeCount` (`FreeformClimbSummaryComponents.swift:31`) — extend `GradeCount` with attempt/project counts |
| On-device board recognition | `BandMemory` + `BLEBands` (`Services/`) as the exact template; `KilterBoardController` identifier capture (`:329`) |
| Apply a detected size safely | `catalog.effectiveSizeId(forLayout:requested:)` (`KilterCatalog.swift:460-465`) + `syncBoardSize()` (`KilterRootView.swift:321-328`) writing `@AppStorage kilter.*` (`:39-46`) |
| Authored-climb thumbnail | `KilterBoardView(geometry:holds:)` (`KilterBoardView.swift:13-15`) fed by `catalog.holds(for:sizeId:)` (`KilterCatalog.swift:318-343`) |
| Your-Climbs store / delete / share / dedup | `KilterCreatedClimb` `@Model` + `asClimb`; `KilterCreatedClimb.delete`; `KilterShareView`; `KilterDuplicateChecker` |
| Per-climb own status | Count `KilterLogEntry where climbUUID == created.uuid` (the `logCount` pattern, `KilterClimbDetailView.swift:674`) |
| Climbing-Level seed | `KilterRecommender.workingDifficulty` (`KilterRecommender.swift:147-155`) windowed per period |
| Volume / sends-per-week trend | `WorkoutDashboardSection.volumeChart` BarMark + grow-on-appear (`WorkoutDashboardSection.swift:207`) |
| HR / strain / zone trends | `WorkoutHRStats` (`WorkoutHRStats.swift:11`) + `HeartRateChart` + `ZoneBar` |
| Hero / ribbon / glass chrome | `DisciplineHero` / `StatRibbon` / `pulseGlassChrome` (`PulsePro.swift:12-112`) + `SnappetColor.kilter` + perf ramp |
| New pushed Kilter screens | `KilterSessionRoute`/`navigationDestination` (`KilterRootView.swift:229`) on the shared path; `SnappetDeepLink` + `SuiteRouter` one-shot only if deep-linkable |
| History grouping + filters | `KilterSession.sessionId` join (`KilterHistoryView.swift:166`); `KilterAscentRow` (`:194`); WorkoutTracker month-group/chip/recovery patterns |
| Session metadata edit | WorkoutTracker `SessionDetailView` all-axis edit (commit `6f8d2a9`); `KilterSessionManager.end/recover` intact |
| Lit-event capture + re-light | `KilterBoardController.illuminate` (`:197`) as the hook; `KilterLogEntry` join for status |
| Any new `@Model` field | `SnappetSchema.models` (`SnappetCore.swift:39-53`) + `SnappetBackup` Row/File/recordCount/snapshot/restore (`KilterSessionRow` as template); `SnappetBackupTests` tripwire |

---

## 7. Testing strategy (pure-logic-first, per CLAUDE.md)

- **Unit (no simulator):** `KilterAllTimeStats` (send/flash rate, attempts-to-send, max-grade trend, weekly
  volume, angle distribution, empty/single-session, roll-ups) — the keystone test; `KilterBoardMemory`
  remember/recall by identifier + serial cross-check + most-frequent-angle + forget + unknown→no-restore;
  Your-Climbs query/sort/filter + own-status join; history bucketing/scope/filter + adaptive-card-fact
  selection; lit-event dedup/grouping/status-join.
- **UITests (simulator):** Your Climbs browse + card actions; dashboard pyramid + tap-to-filter; history
  grouped timeline + heatmap/calendar + session naming/notes/edit; On the Board timeline + re-light.
- **Migration / backup:** new `KilterSession` fields (P4) and `KilterLitEvent` (P5) require the
  `SnappetBackup` mirror + `SnappetBackupTests.testCodecCoversEverySchemaModel` + the count tripwire green.
- **UI-suite policy:** P0 (pure logic) gates on unit + build-for-testing + review
  ([[ui-suite-policy-logic-only-prs]]); P1–P5 run XCUITest. The sim can wedge
  (`xcrun simctl shutdown all`, [[uitest-event-synthesize-flake]]).
- **Device-pending (honesty rule):** the BLE connect leg (P1), the CoreLocation leg (P1), and live
  re-light (P5) are confirmable only on real hardware (MrRobot) — keep all new logic pure + unit-tested so
  each PR ships green without a board.

---

## 8. What this does NOT change (scope guards)

- **No backend / network / accounts.** Board recognition learns from your own behavior; the coarse place is
  on-device and never uploaded. No shipped gym→board database (the network fantasy the constraint forbids).
- **No "detect a never-seen board".** Auto-detect removes the pick only on **repeat** visits; the first
  encounter with any board/place stays a one-time manual pick.
- **Kilter-board data only** for the dashboard / history / galleries (not Quick-Session freeform climbing).
- **No community signals** (ascents-by-others, global quality) anywhere — none exist on-device.
- **Minimize new `@Model`s.** P0–P3 add none; P4 adds *additive optional fields*; P5 adds one
  (`KilterLitEvent`). Prefer deriving state (e.g. a Draft flag) over a schema add.
- **Knowledge graph** nodes are added **per phase at build time**, not in this planning PR (no UX shipped
  yet — don't let the graph claim unbuilt surfaces).
- **Android** follows iOS per phase, as its own wave.

---

## 9. Open questions to resolve during implementation

1. **Lit-event volume** — cap/rollup strategy (one event per climb-per-session vs every tap) to keep the
   `KilterLitEvent` log bounded; decide whether preview-illumination (authoring) counts or only
   `wasConnected` real-board lights.
2. **Deep-linkable new screens?** — Your Climbs / Stats / On the Board as `SnappetDeepLink` cases (Spotlight
   / widget entry, the `pendingKilterClimb` precedent) or in-app-push only.
3. **Draft state for created climbs** — derive from a failed `kilterValidate` (no schema) vs an explicit
   flag (schema add). Prefer derived.
4. **Per-session stats caching** — recompute `KilterSessionStats` per row vs denormalize on `KilterSession`
   for very long histories. On-the-fly for v1; optimize only if a real history lags.
5. **CoreLocation precision + permission copy** — the coarse bucket size, the when-in-use prompt wording,
   and graceful degradation to BLE-only when location is denied.
6. **`#serial` reliability** — community-reverse-engineered; confirm on a real board whether names are
   distinct per unit before relying on serial as anything but a soft cross-check.

---

## 10. Obligations on implementation (CLAUDE.md)

- **PDD:** one feature prompt per phase under `pdd/prompts/features/kilter-improvement/`, committed with the
  code; keep `pdd/context/` true; record decisions the same day.
- **Knowledge graph:** every new/changed surface (board memory, Your Climbs, the dashboard, the regrouped
  history, On the Board) gets a `nodes` entry + `links` edge in `docs/knowledge-graph/data.js` in the same
  change.
- **Platform purity:** `KilterAllTimeStats` + all stats + the board-memory rules stay pure value types
  (device-free tests); CoreBluetooth / CoreLocation behind the service edge; `HighlightEngine` stays
  platform-free.
- **Android:** its own wave after each iOS phase (model + Room migration + backup round-trip mirror).

---

## 11. GitHub issues

This plan maps to an **epic** (tracking) issue + **6 child issues** (P0–P5) + a hardening follow-up. See the
parent PR / the epic for the live links.

---

*Built on the real code — 6 file:line code maps + 5 design sweeps + a board-detection feasibility adversary
from a 13-agent research workflow. Every cited `file:line` was checked against source.*
