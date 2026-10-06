# Prompt: Household P4: widget, watch, power hour, and shipping to Public Beta (prompt 159)

**File**: pdd/prompts/features/household/04-household-surfaces-and-beta.md
**Created**: 2026-10-05
**Project type**: Native iOS + watchOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: Household initiative, P4 of 4 (wireframe frame 7 + the ideation's "touchpoints"). Builds on P1–P3 (#344 → #345 → #346).
**Source**: user, 2026-10-05: "continue working and finish this feature end to end. i will only be able to test it with multiple phones when this is in public beta"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`, `pdd/context/household-wire-format.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Finish Household for real use and put it in testers' hands: the surfaces people touch without opening the
app (a Home/Lock Screen widget with check-off, a watch list, a power-hour Live Activity), the hardening a
first multi-phone test needs (a clear path when Local Network access is off), and the release: merge the
P1–P4 chain and ship a TestFlight build to Public Beta with tester notes that explain how to try it with
two phones.

## Scope

1. **Chores widget** (`HouseholdWidget`, small / medium / Lock Screen rectangular): the pet still (the
   buddy stills), house level, the goal bar, and up to four of *your* chores today with interactive
   check-off (`ToggleChoreIntent`, the `ToggleHabitIntent` pattern). Taps go to an App Group outbox
   (`ChoreOutbox`, one file per tap, absolute desired state) and update the snapshot optimistically. The app
   reconciles them into `complete` / `undo` ops **stamped with the tap time** on its next foreground.
2. **Watch**: a Chores page on the watch app (vertical pages: workout, chores). The phone sends the same
   snapshot as application context; a tap on the watch goes back with `transferUserInfo` (queued if the
   phone is away) and lands in the same outbox. Routed through the phone's existing `WCSession` delegate.
3. **Power hour** (frame 7): anyone starts a 15–60 minute blitz with a target. New ops `start_power_hour`
   (`ends`, `target`) and `end_power_hour`. Today shows a live banner (time left, chores done since the start,
   who's in); every phone shows a **Live Activity** (Lock Screen + Dynamic Island) with the countdown, which
   the OS ticks on its own. The count updates whenever the app syncs or is opened (accepted limit: no server,
   so no background push).
4. **Local Network denied**: detect it (browser/listener `.waiting`/`.failed` with a policy-denied error) and
   show a banner in the Household tab with "Open Settings". It's the most likely first-beta failure.
5. **Release**: merge #344 → #345 → #346 → this PR to `main` in order (retargeting each first), cut the next
   TestFlight build, add it to Public Beta, and write tester notes.

## Explicitly not in this round

- **Android.** There's no Android beta channel; the protocol spec in `household-wire-format.md` is the contract
  for that port.
- **Wi-Fi Aware** (router-free sync). It needs a new entitlement and two physical iPhone 12+ phones to test,
  and Bonjour on home Wi-Fi covers the household case. Revisit after beta feedback.
- Notifications for others' chores. Without a server they could only fire while the app is open, where the
  board already updates live.

## Acceptance criteria

- [ ] Widget shows the pet, level, goal and my chores; check-off works without opening the app and reconciles
      into ops with the tap's time (idempotent: a toggle applied twice changes nothing).
- [ ] Watch shows the chores and ticks them; the phone applies the tick even if it arrives later.
- [ ] Power hour: start → banner + Live Activity on every phone that syncs; the count only includes chores
      done since the start; it ends on time or on End; ops fold the same everywhere (tests).
- [ ] Local Network denied → banner with Open Settings.
- [ ] Unit + UI suites green; the two-simulator E2E still passes.
- [ ] The chain is merged to `main` in order; the TestFlight build is processed and on Public Beta; tester notes committed.

## Test plan

1. Unit: outbox reconcile (idempotent, tap time, undo), power-hour fold + count, watch message coding, snapshot builder.
2. UI: power-hour start → banner → end.
3. Two simulators: power hour started on one appears on the other after a sync.
4. Release: TestFlight build processed; Public Beta group has it.
5. Device legs (owed, in Public Beta): two iPhones join and sync on real Wi-Fi; widget check-off; watch tick; Live Activity on the Lock Screen.
