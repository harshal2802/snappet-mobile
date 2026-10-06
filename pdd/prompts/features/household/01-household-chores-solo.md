# Prompt: Household mini-app P1: shared-chore board, solo and local, on a sync-ready log (prompt 156)

**File**: pdd/prompts/features/household/01-household-chores-solo.md
**Created**: 2026-10-04
**Project type**: Native iOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: Household initiative, P1 of 4 (wireframes approved first: `docs/ux-research/household-chores/wireframes.html`)
**Source**: user request 2026-10-04 (household chores app, gamified, devices talk to each other)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

A new **Household** mini-app (Lifestyle category). A household keeps its chores on one shared board,
works toward one shared goal, and syncs phone to phone on the home Wi-Fi with no cloud and no accounts,
including between iPhone and Android. The user chose: **cooperative, not competitive** (house pet, house
goal and fair share; no leaderboard), **a separate mini-app** (not part of Habits), and **local P2P** sync
(most households are all-iPhone, but Android members must be able to join).

The initiative ships in four prompts:

| Phase | Scope | Wireframe frames |
|---|---|---|
| **P1 (this)** | Solo, one device: chores, schedules, the board, the week view, the house goal, chore XP. **The data is an operation log from day one**, so P2 adds sync with no migration. | 1, 2, 3 (single member) |
| P2 | Household: invite QR + key, Bonjour discovery, TLS-PSK, log sync, members/devices, offline queue | 4, 5, 6 |
| P3 | Cooperative layer: house pet (buddy), fair share across members, help requests, weekly recap | 2 (full), 8, 9 |
| P4 | Surfaces + reach: widget, watch tick, power-hour Live Activity, Wi-Fi Aware transport, Android client | 7 |

P1 must be useful on its own (a personal chore planner with "after done" schedules and XP), and it must
not paint P2 into a corner.

## Context the implementer needs

- Mini-apps are `AppModule`s collected in `Core/ModuleRegistry.swift`; use `ModuleCategory.lifestyle`
  (Wardrobe's category). **A mini-app never adds its own bottom bar** (decisions 2026-07-12). Sections
  are a top segmented control (`Today · All chores · Week`; `Household` arrives in P2), like Gym Tracker.
- **The name is "Household", not "Home"**: `Features/Home` is already the suite's Home tab.
- `Features/Habit/HabitSchedule.swift` is the one definition of "due" for weekday schedules. Reuse its
  weekday rule; **"every N days after it's done"** is new and goes in the chore scheduler, not in Habits.
- XP lives in `Features/Progression/Progression.swift`: derived, never stored, one `Rules` table,
  `dailyCap = 300` shared across everything. Today only sessions feed the ledger (decisions 2026-10-01:
  "the rules table is the one place other apps would plug in"). Chores are the first non-training source.
- Adding `@Model`s to `SnappetSchema.models` requires mirror Rows in `Core/SnappetBackup.swift`
  (`SnappetBackupTests.testCodecCoversEverySchemaModel` is the tripwire).

## Approach

**The keystone is a pure, platform-free operation log.** The board is a fold over it. Nothing stores
"current state".

- `Features/Household/ChoreLog.swift` (pure, no SwiftUI/SwiftData imports):
  - `ChoreOp`: `id: UUID`, `deviceID: UUID`, `seq: Int` (per-device counter), `at: Date`, and a
    `kind` enum: `createChore`, `editChore(fields)`, `archiveChore`, `complete(choreID, by: memberID)`,
    `undoComplete(opID)`, `claim(choreID, by:)`, `setGoal(target, reward, week)`.
  - `Codable` with a **stable, versioned JSON wire format** (`"v": 1`, snake_case keys, ISO-8601 dates,
    unknown kinds skipped, not fatal). P2 sends exactly this, and P4's Kotlin port must parse it.
  - `VersionVector` (`[deviceID: maxSeq]`) and `missing(since:)`. Not used across devices until P2,
    but written and tested now.
- `Features/Household/ChoreBoard.swift` (pure): `fold(ops) -> BoardState` that is **order-independent and
  idempotent** (sort by `(at, deviceID, seq)`, dedupe by op id). Merge rules, decided now so P2 is only plumbing:
  - Edits are last-writer-wins **per field** by `(at, deviceID)`.
  - Two `complete` ops for the same chore in the same due window: **both members get credit, the house
    goal counts it once** (wireframe frame 6). No conflict UI anywhere.
  - Archive beats concurrent edits.
- `Features/Household/ChoreSchedule.swift` (pure): repeat modes `daily`, `weekdays([Int])` (delegates to
  the `HabitSchedule` weekday rule), `afterDone(days:)` (due N days after the most recent completion by
  anyone; never done = due now), `once`. Exposes `isDue`, `dueWindow`, `overdueBy`.
- Assignment: `rotate(order)`, `fixed(member)`, `upForGrabs`. In P1 there is one member (`me`), but the
  rotation code takes a member list and is tested with several.
- Effort: `S/M/L` = 1/2/3 effort points (fair share and the goal both use it) and the XP below.
- **Persistence**: one `@Model HouseholdOpRecord` (op id, device id, seq, at, `payload: Data` = the wire
  JSON) plus `@Model Household` (id, name, `myDeviceID`, `myMemberID`). The board is never persisted.
  Folding is cached in memory, keyed by op count + last op id (the same shape as the XP ledger cache).
  Backup mirrors both models.
- **XP**: add `Progression.Rules.choreS/M/L` (start at 10 / 20 / 35) and feed chore completions **credited
  to me** into the ledger under the existing `dailyCap`. One line per completion: "🧹 Clean the fridge".
  Keep it derived. This reverses "only training feeds XP" (decisions 2026-10-01) by the user's choice in
  this initiative; record it. Home's training-first switch (prompt 150) stays training-only.
- **Views** (`Features/Household/`): `HouseholdRootView` (segmented control), `HouseholdTodayView`
  (frame 1 minus the pet and the sync pill: a house-goal card leads instead), `HouseholdChoresView`
  (all chores grouped by room, swipe to archive), `HouseholdWeekView` (frame 2: goal + "the house this
  week" bars; fair share and help requests hidden until P2/P3), `ChoreEditorSheet` (frame 3; "Lean
  toward lighter share" and "Ask for a photo" are **not** in P1), `HouseholdGoalSheet` (weekly target +
  free-text reward).
- **Deliberately not in P1**: networking, QR, members beyond me, the house pet, fair share, help
  requests, recap, widget/watch/Live Activity, notifications.

## Output

- `ios/App/Snappet/Features/Household/` with the files above plus `HouseholdModule.swift`.
- Registration in `Core/ModuleRegistry.swift`; models in `SnappetSchema.models`; Rows in `SnappetBackup.swift`.
- `Progression.swift` rules + ledger input for chores.
- `SnappetTests/Household*Tests.swift` (see Test plan); UITest smoke `HouseholdUITests` (add chore → set goal → tick → goal moves → untick; starter board).
- A `SnappetColor.household` accent (pick an unused hue; teal-green fits the pet) with light/dark values.
- `docs/knowledge-graph/data.js`: Household module node + edges (Progression XP source, Backup, Habit schedule reuse).
- `pdd/context/decisions.md` entry; `pdd/context/project.md` lists the module.
- `pdd/context/household-wire-format.md`: the v1 op JSON with 3+ example ops. This is the spec P2 and the Android port build against.

## Acceptance criteria

- [ ] Household appears in the app library (Lifestyle) and opens to Today, with no module bottom bar.
- [ ] Creating, editing, archiving, completing and undoing chores all work, and survive relaunch, by replaying ops.
- [ ] "Every 14 days after done" is due 14 days after the latest completion, and re-anchors on each completion.
- [ ] Rotation advances per due window through the member order (unit-tested with 3 members).
- [ ] The house goal bar counts chores (rounds) done this week; setting a reward shows it on Today. *(Amended at build: rounds, not effort points, to match the wireframe's "28 of 40 chores"; see decisions.)*
- [ ] Completing a chore adds an XP line under the shared 300/day cap; undo removes it.
- [ ] `ChoreBoard.fold` gives the same state for any permutation and any duplication of the same ops (property-style test).
- [ ] Two devices' concurrent completes of the same chore: both credited, goal +1 (test with fake device ids).
- [ ] The wire-format JSON round-trips; an unknown `kind` is skipped; golden-file test against `household-wire-format.md` examples.
- [ ] Backup round-trips both new models (tripwire green).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine`; `ChoreLog`/`ChoreBoard`/`ChoreSchedule` import Foundation only.
- [ ] `decisions.md` updated (op log as the model, merge rules, chores feed XP, the "Household" name).

## Constraints

- On-device only in P1. No networking code, not even dormant (P2 owns Local Network permission + Info.plist keys).
- The wire format is a contract: changing it after P1 merges needs a version bump and a migration test.
- Don't fork Habits' "due" logic. Delegate weekday rules to `HabitSchedule`.
- State verification honestly: unit tests prove the fold; the UI leg is a sim run, not a device claim.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`: new `HouseholdChoreBoardTests` (fold permutation and
   duplication, LWW per field, archive wins, double-complete credit), `HouseholdChoreScheduleTests`
   (after-done, weekdays delegation, rotation), `HouseholdWireFormatTests` (golden files, unknown kind),
   `ProgressionTests` additions (chore XP, shared cap, undo).
2. `xcodebuild test … -only-testing:SnappetUITests/HouseholdUITests` (no Make target for one UI class) (add a chore → set goal → tick → goal moves → untick). Relaunch persistence is unit-tested in `HouseholdStoreTests`, since UI tests run on an in-memory store.
3. Install on MrRobot. Add 5 real chores (one "after done"), tick two, check the XP line on the buddy screen.
