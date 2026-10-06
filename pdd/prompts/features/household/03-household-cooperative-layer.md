# Prompt: Household P3: the house pet, fair share, help requests and the weekly recap (prompt 158)

**File**: pdd/prompts/features/household/03-household-cooperative-layer.md
**Created**: 2026-10-05
**Project type**: Native iOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: Household initiative, P3 of 4 (wireframe frames 1, 2, 6, 8, 9: `docs/ux-research/household-chores/wireframes.html`). Builds on P1 (#344) and P2 (#345).
**Source**: user, 2026-10-05: "continue working" (cooperative, not competitive, chosen at ideation)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`, `pdd/context/household-wire-format.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The gamified, cooperative part of the approved design. Everyone works for **one shared creature and one
goal**, the board shows balance instead of ranking, and nagging is replaced by asking for a hand and saying
thanks. Everything is derived from the op log, so it syncs for free over P2.

## Scope

1. **The house pet** (frames 1, 9): the 3D buddy creature (`BuddyCreatureView`) as the household's pet.
   - **House level** from total house chore XP: every credited member's chore XP, no daily cap (the cap
     protects a person's level, not the house's). Same level curve as the buddy (`Progression.levelInfo`),
     so the stage comes from it.
   - **Mood (Form)** from the house's chore health: overdue chores weighted by effort and days, against the
     week's goal pace. A slipping kitchen makes it sleepy; it never shrinks and never names a person.
   - Paused (house on holiday) means calmly asleep.
   - Named by the household (`name_pet` op; default "Biscuit").
   - **Pet screen** (frame 9): big pet, mood line, "What would cheer Biscuit up" (overdue chores with
     Help / I'll do it), house streak, pause toggle.
2. **House streak**: consecutive weeks the house goal was met. Paused weeks are neutral; the current week
   counts once met.
3. **Pause the house** (frame 9): `pause_house` (until a date, optional) and `resume_house`. While paused,
   nothing is overdue, the pet sleeps, and the week doesn't break the streak.
4. **Fair share** (frame 2): each member's effort points this week (S1 · M2 · L3 per credited round; both
   people in a shared round get the points), as a stacked bar + legend and a **balance** pill
   (Balanced ≤ 10 pp between the top and bottom share, A bit uneven ≤ 25 pp, otherwise Uneven). Shown once
   there are two members.
5. **Lean toward lighter share** (frame 3's deferred toggle): a rotating chore with `lean` set goes to the
   member in its rotation with the fewest effort points this week (ties → normal rotation order). New
   optional field `lean` in the wire `fields`.
6. **Help requests** (frames 2, 9): "Ask for a hand" on one of my chores, with an optional note
   (`ask_help` op). It shows to everyone as "Jo asked for help · Bathroom · away till Tue" with **Take it**
   (= `claim`). It closes when the chore is next done, claimed by someone else, or retracted (`undo`).
7. **Thanks** (frame 6): when a round was done by more than one person, or someone took my help request,
   a 👏 **Thank** button (`thank` op: to member, optional chore). Thanks show in the recap.
8. **Weekly recap** (frame 8): "Week in the house" for the last finished week: rounds done, goal met + reward,
   the pet's level change, a **thank-you line for every member** chosen from what they actually did (took a
   help request › rescued an overdue chore › kept a daily chore going N days › did N chores), thanks received,
   and the balance line when shares stayed close. It opens once at the first visit of a new week, is
   reachable from Week, and shares as an image (`ImageRenderer` + `ShareLink`).

## Approach

- **Pure** `Features/Household/HouseholdInsights.swift` (Foundation only): house XP and level inputs, mood,
  streak, pause state, fair share + balance, lean assignee, open help requests, thanks, and the recap model.
  `ChoreBoard.fold` learns the new op kinds (help requests, thanks, pauses, pet name) as plain folded state,
  merging like everything else (latest wins; `undo` retracts help requests and thanks).
- `ChoreBoard.assignee` honours `lean` via `HouseholdInsights` effort points.
- `ChoreSchedule.status` gets the pause window: no overdue days inside it.
- Views: `HouseholdPetCard` (Today hero, replacing P1's goal card but keeping the goal bar inside it),
  `HouseholdPetScreen`, `HouseholdFairShareCard`, `HouseholdHelpCard`, `HouseholdRecapSheet`, an "Ask for a
  hand" sheet, and Thank buttons. All are cooperative in copy: no ranking, no "who slacked".
- Wire spec: new kinds `ask_help`, `thank`, `pause_house`, `resume_house`, `name_pet`; new field `lean`.
  All additive under v1 (old readers ignore them).

## Acceptance criteria

- [ ] House level counts every member's chore XP, uncapped, and moves the pet's stage.
- [ ] Mood drops with overdue chores (weighted by effort and days) and recovers when they're done; pause → asleep.
- [ ] Streak counts consecutive met weeks; a paused week neither breaks nor extends it.
- [ ] While paused, after-done chores report no overdue days.
- [ ] Fair share sums effort per credited member for the week; the balance thresholds hold at their edges.
- [ ] `lean` gives a rotating chore to the lightest member in its rotation; ties fall back to rotation order.
- [ ] A help request opens, shows to others, and closes on completion, someone else's claim, or undo.
- [ ] Thanks fold and land in the recap; undo retracts one.
- [ ] Recap: one thank-you line per member, by the priority above, and correct totals and goal state for the week.
- [ ] Everything converges across two phones (machine-pair test, P2 harness).
- [ ] Wire spec updated; golden tests for each new kind round-trip.
- [ ] Unit + UI suites green; UI test covers the pet card, pet screen, ask-for-help, and the recap sheet.

## Constraints

- Cooperative copy only: never rank members or call anyone out. Overdue chores are "the kitchen's slipping",
  not "Sam is late".
- No new SwiftData models: everything derives from the op log.
- The pet reuses the buddy creature and its art styles; no new 3D work.

## Test plan

1. Unit: `HouseholdInsightsTests` (XP/level, mood, streak, pause, fair share + balance, lean, help lifecycle,
   thanks, recap lines), wire golden additions, a P2 machine-pair convergence test with the new kinds.
2. UI: `HouseholdUITests` additions.
3. Visual: screenshot pass on the simulator against frames 1, 2, 8, 9.
