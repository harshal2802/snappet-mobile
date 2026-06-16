# Prompt: Android port of the Kilter planned-session lifecycle

**File**: pdd/prompts/features/kilter-planned-session/02-android-port.md
**Created**: 2026-06-16
**Project type**: Native Android (Kotlin / Jetpack Compose / Room) — code lands in this repo.
**Chain**: kilter-planned-session/DESIGN.md → Android parity (iOS shipped first; this is "right after")
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (2026-06-16 entries)

## Goal

Bring Android to parity with the iOS "Kilter planned-session lifecycle" feature (8 PRs, merged on
`claude/kilter-planned-session-lifecycle`). iOS is the source of truth — port its behavior, decisions,
and tests faithfully. This fixes the same four reported defects on Android: (#1) a logged Send/Project
pick must stay ticked, (#2) a way back to a running session, (#3) a re-enterable plan mid-run, (#4)
customizable plan generation.

## Why this is a large, self-contained effort

The Android side is **behind** iOS: `feature/kilter/KilterSessionManager.kt` is ~55 lines with only
`start`/`end` (no `recover()` / #54 stale-session recovery, no plan concept), `KilterPlanScreen.kt`
never receives the session manager (no Start, no checkmarks), and there is no Room plan entity. So this
port re-does iOS PRs 01–07 in Kotlin/Compose/Room **plus** the recovery foundation iOS already had.

## Approach (mirror the iOS commits, in order)

Reference iOS commits on the branch: 36adc78 (model), 57de1d4 (snapshot/freeze/log-tick),
15d88e4 (re-entry), e170566 (climb forward-loop), 63856a2 (finish + summary), a85cdd4 (customization),
770fa35 (shuffle + home card), a58c246 (combined-review fixes).

1. **Room model + migration** (iOS PR 01):
   - Add `KilterPlanEntity` to `feature/kilter/KilterEntities.kt`: `id` (PK, String UUID), `createdAt`,
     `angle`, `layoutId`, `workingDifficulty: Double?`, `workingGradeLabel: String?`, `title: String?`,
     `sessionId: String?`, `completedAt: Long?`, `optionsTargetCount/SendThreshold/PreferUnsent`,
     `optionsGradeOffset`, `strategyRaw: String?`, and `items` as a JSON `String` (a `@TypeConverter`
     for `List<KilterPlanItem>`, mirroring how HR series / assignments are stored — see
     `KilterAssignmentsCodec`).
   - `core/SnappetDatabase.kt`: add `KilterPlanEntity::class` to `entities`, bump `version` 5→6, add
     `AutoMigration(from = 5, to = 6)` (purely additive table → no hand-written SQL; Room generates it;
     `exportSchema=true` writes `app/schemas/...6.json`). **Renumber if Wave-2's v5 bump conflicts.**
   - `KilterDao`: `upsertPlan`, `planForSession(sid): KilterPlanEntity?` (WHERE sessionId=:sid AND
     completedAt IS NULL), `openPlans(): Flow<List<…>>`, `deletePlan`.
2. **Pure logic** (iOS PR 01): port `KilterPlanProgress` (items(from:), applyingLog, progress,
   nextPending, pendingClimbUUIDs, skipping, allResolved) + `KilterPlanItem` + `KilterPlanItemStatus`
   to a new `feature/kilter/KilterPlanProgress.kt`. Unit-test in `KilterPlanProgressTest.kt` — port
   `KilterPlanLogicTests` (incl. the send/project "stays done" regression + advance-by-order).
3. **Recovery foundation**: port iOS `KilterSessionRecovery` + add `recover()` to the Android
   `KilterSessionManager` (the #54 adopt/auto-close logic) — required before plan re-pinning works.
4. **Session manager plan ownership** (iOS PR 02/03/05/06): `currentPlanId`, `planProgress`,
   `planPendingUUIDs`, `attachPlan` (one-open-plan invariant), `applyLogToPlan`, `nextPlanClimb`,
   `skipPlanItem`, `openPlan`; close the plan on `end`/recover-auto-close; delete on undo. Port
   `KilterPlanSessionTests`.
5. **KilterPlanScreen** (iOS PR 02/06/07): generate vs frozen session-home modes; thread `sessions`;
   Start snapshots + attaches + freezes; status-driven checkmarks; progress + next-up; Finish; the
   config bottom-sheet with `Strategy`/`Mix` + grade-offset + shuffle (port the recommender extension
   in `KilterRecommender.kt`: `Strategy`, `Mix`, weighted `allocation(target, mix)`, `rerollSeed`,
   `gradeOffset` applied to the anchor in the screen, working-grade label from the detected bucket).
6. **Re-entry** (iOS PR 03 + home card): Android nav is `KilterRoot`'s `KilterScreen` enum (not a
   NavigationStack) — add a persistent "session running" affordance that routes to the plan-home, and a
   Home "Resume climbing session" card. Converge the in-Kilter session bar on the plan-home too.
7. **Climb detail** (iOS PR 05): Back-to-plan / Next-pick(advance-by-order) strip for plan-backed runs;
   wire the log path to `applyLogToPlan`.

## Acceptance criteria

- [ ] `./gradlew :app:assembleDebug` green; `:app:testDebugUnitTest` green (incl. ported plan tests).
- [ ] Room v6 AutoMigration ships; `app/schemas/…6.json` committed; no destructive fallback added.
- [ ] All four reported defects fixed on Android, matching iOS behavior + the decisions.md invariants
      (one open plan per session; a plan never outlives its session; done-state read from status).
- [ ] `docs/knowledge-graph/data.js` `kilter-planned-session` node updated to `platform: ios+android`.
- [ ] `decisions.md` notes any Android-only divergence (e.g. JSON-column items vs iOS embedded array).

## Constraints / build

- macOS not required; Android build needs JDK 17 + `ANDROID_HOME` (java not on PATH — see the
  `android-build-env` memory). AVD `snappet_pixel7` for UI checks.
- On-device only; additive migration (existing stores upgrade cleanly, never wiped).

## Test plan

1. `cd android && ./gradlew :app:testDebugUnitTest` (unit), then `:app:assembleDebug`.
2. Adversarial review of the Android diff (mirror the per-PR + combined reviews the iOS side ran).
3. Device/AVD smoke: plan → start → log a send → it stays ticked; leave & resume; finish → summary.
