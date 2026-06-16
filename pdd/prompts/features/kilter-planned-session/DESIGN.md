# Kilter Planned-Session Lifecycle — DESIGN

**Created**: 2026-06-16
**Project type**: Native iOS (lead) + Android port. Code lands in this repo.
**Source**: User UX report — four disconnects in the Kilter "Plan a session" flow.
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`, `snappet-core-schema.md`

This is the umbrella design for a multi-PR feature. One PR = one prompt in this folder
(`01-…`, `02-…`). It supersedes the ad-hoc plan behavior introduced by `030e764`
(KilterRecommender) / `e5889db` (anchor coherence).

## The four reported defects → one root cause

The planned session isn't a persisted *thing* — it's a pure function (`KilterRecommender.recommend`)
recomputed from volatile inputs on every render, with completion re-derived live. All four symptoms
fall out of that:

1. **Logging a Send/Project pick doesn't tick it (warm-ups do).** `KilterPlanView.planKey`
   (`KilterPlanView.swift:126`) includes `entries.count`, so each log re-fires `rebuild()` (`:71`).
   `recommend` fills send/project bands with `allowSent: !preferUnsent == false`
   (`KilterRecommender.swift:134-136`), so the just-sent UUID is dropped and a fresh climb swapped in →
   the green check (`loggedThisSession`, `:102/:120`) never appears. Warm-ups use `allowSent: true`
   (`:132`) so they survive — the asymmetry.
2. **Hit Play → no way back to the session.** The session lives in `AppModel.kilterSessions`; its only
   UI is the root `sessionBar` (`KilterRootView.swift:338`), buried under the pushed Plan→Climb stack,
   and it routes to the session *summary*, not the plan/next pick.
3. **No re-enterable plan mid-run.** The plan is ephemeral `@State` (`KilterPlanView.swift:27`);
   re-opening rebuilds a *different* plan. `KilterSessionManager` holds no plan reference.
4. **No customization.** `KilterRecommender.Options` exists (`:49-61`) but `recommend` is called with
   defaults (`:144`); zero UI, no selection strategy.

## The keystone move

Promote the plan to a **persisted entity with per-pick state, decoupled from the recommender**:

- `KilterRecommender` stays a pure *generator*.
- On **Start**, snapshot its `Plan` into a durable `KilterPlan` (`@Model`) + ordered `KilterPlanItem`s,
  pin it to `sessions.currentId`, and **freeze** it (the recommender never rebuilds it again).
- Live UI reads done-state from `KilterPlanItem.status` — never re-derives from `logs ∩ recommend()`.

This one change fixes #1 (completion is stored, can't be filtered out), #3 (the plan has a stable home
keyed by `sessionId`), and the mid-session reshuffle hazard.

## State machine

| State | Meaning | Persisted |
|---|---|---|
| **No plan** | Generator screen; nothing snapshotted | recommender output ephemeral |
| **Plan ready** | `KilterPlan` exists, `sessionId == nil`, items `pending` | KilterPlan + items + optionsSnapshot |
| **Active in-progress** | `sessionId` set, ≥1 item resolved, `completedAt == nil` | + per-item status / completedAt |
| **Paused** | live but idle (soft) | + lastActivity stamp (reuse session recovery) |
| **Completed** | Finish plan → `completedAt` set, session ended | + completedAt; KilterSession.endedAt |
| **Abandoned** | >6h idle auto-closed by existing `KilterSessionRecovery` | KilterPlan open + session closed |

Transitions: generate → (Start snapshots) → first log flips matching item → … → Finish plan / recovery.

## Data model (additive, lightweight-migration safe)

- **`KilterPlan`** `@Model` (`KilterModels.swift`): `id`, `createdAt`, `angle`, `layoutId`,
  `workingDifficulty?`, `workingGradeLabel?`, `title?`, `sessionId: UUID?`, `completedAt: Date?`,
  options snapshot (`optionsTargetCount`/`optionsSendThreshold`/`optionsPreferUnsent`/`strategyRaw`),
  and `items: [KilterPlanItem]` (embedded Codable array — same shape as `KilterSession.hrSeries`).
- **`KilterPlanItem`** Codable value (`KilterPlanLogic.swift`): `id`, `order`, `goalRaw`, `climbUUID`,
  `climbName`, `setter`, `gradeLabel`, `difficulty`, `statusRaw`
  (`pending`/`sent`/`attempted`/`skipped`), `locked`, `completedAt?`.
- **`KilterPlanProgress`** pure namespace: `items(from:)`, `applyingLog(climbUUID:ascent:at:to:)`,
  `progress`, `nextPending`, `skipping`, `allResolved` — unit-tested without SwiftData.
- Register `KilterPlan.self` in `SnappetSchema.models` (`SnappetCore.swift`) **and** add
  `KilterPlanRow` to `SnappetBackup` (else `SnappetBackupTests` trips).

## Resume / return affordance

- **Cross-screen live chip** (iOS): a `KilterLiveChip` overlaid on the App Library `NavigationStack`,
  modeled on `PomodoroLiveChip` (`AppLibraryView.swift:98`), gated on `app.kilterSessions.isActive`,
  showing timer + "N/M done", deep-linking to the **pinned plan** (not the generic summary).
- **Plan screen = session home**: when a `KilterPlan.sessionId == currentId` exists, re-entering loads
  the **stored** plan (frozen order, status-driven checks), shows "N of M done" + "next up" + a
  **Finish plan** button.
- **Climb detail**: real session strip — "Back to plan" / "Next pick →" / "End" — replacing the
  decorative status row (`KilterClimbDetailView.swift:404-423`).
- **Android**: thread `sessions` into `KilterPlanScreen`; hoist the session bar to render around every
  `KilterScreen`; add a PLAN↔DETAIL return target + `recover()` to the Android `KilterSessionManager`.

## Customization / selection strategy

Default to today's zero-config plan; one **Adjust** entry opens a plan-config sheet leading with
climber-language presets that map under the hood to `KilterRecommender.Options`:

| Preset | Mapping |
|---|---|
| Volume / Endurance | ↑targetCount, at-grade weight, `preferUnsent:false`, offset 0 |
| Project push | ↓count, project-heavy, band +1/+2, `preferUnsent:true` |
| Limit / Power | small count, highest band, low warm-up ratio |
| Flash practice | mid count, fresh-only, band at/just-below working grade |
| Easy flush / Recovery | offset −1/−2, warm-up-heavy, `preferUnsent:false` |

Advanced knobs (collapsed): warmup:send:project ratio, target-grade offset, prefer-unsent,
sendThreshold. Wire by passing a built `Options(...)` into `recommend(options:)`
(`KilterPlanView.swift:144` / `KilterPlanScreen.kt:76`) — no core-math change. Persist last-used prefs
in `@AppStorage` / Android `KilterSettings`. Shuffle/lock only in **Plan ready** — never as a side
effect of logging.

## Session video / media tagging

No change of axis and no `SessionMedia` schema change for v1. Today a clip is auto-assigned to the
climb whose in-session window contains its `offsetSec` (`KilterMediaAssignment.climbUUID(forOffset:)`,
`KilterBoardController.swift:649`), stored on `SessionMedia.assignedClimbUUID`. Because
`KilterPlanItem.climbUUID == KilterLogEntry.climbUUID == SessionMedia.assignedClimbUUID`, a plan row
**inherits its clips by a pure join** (the same `KilterMediaAssignment` join `KilterSessionDetailView`
already runs). The active-session model lets us *optionally upgrade* tagging from post-hoc time-window
inference to live `activeClimbUUID` capture, and lets the reel group by `goal` (warmup/send/project).
Off-plan clips tag to their own climbUUID and surface in the session's actual timeline, not on a plan
row. A `SessionMedia.assignedPlanItemID` is a P2 nicety, not needed for v1.

## PR plan (one prompt = one PR)

| PR | Change | Pri | Scope |
|---|---|---|---|
| 01 | `KilterPlan`+`KilterPlanItem` models, `KilterPlanProgress` pure logic + tests, schema + backup | **P0** | data + shared |
| 02 | Snapshot-on-Start; plan-home reads `PlanItem.status`; freeze while active; per-item media strip | **P0** | iOS UI |
| 03 | Cross-screen `KilterLiveChip` → deep-link to pinned plan | **P0** | iOS UI |
| 04 | Android parity: `sessions` into `KilterPlanScreen`, persistent session bar, `recover()` | **P0** | Android |
| 05 | Climb-detail session strip: Back to plan / Next pick / End | P1 | iOS+Android |
| 06 | Finish plan + `completedAt` + summary plan-vs-actual + goal-grouped reel | P1 | iOS+Android+data |
| 07 | Plan-config sheet + named strategies wired to `Options` | P1 | iOS+Android+shared |
| 08 | Shuffle + lock-pick (Plan-ready only); Home "Resume Kilter" card | P2 | iOS+Android |

Every PR updates `pdd/context/*` + `decisions.md` same-day and the `kilter-planned-session` node in
`docs/knowledge-graph/data.js`. `HighlightEngine` stays platform-free; shared plan-progress wire types
(if any cross phone↔watch↔widget) live in `ios/App/Shared/`.
