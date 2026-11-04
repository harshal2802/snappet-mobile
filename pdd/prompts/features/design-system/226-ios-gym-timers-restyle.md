# Prompt: Design-system reset, step 3f — Gym Tracker timers (prompt 226)

**File**: pdd/prompts/features/design-system/226-ios-gym-timers-restyle.md
**Created**: 2026-11-03
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement, keep stop outline")**: `docs/ux-research/design-system/gym-timers.html`
(before: `timers-before-*.png`, after: `timers-after-*.png`)

## Goal

The first of the Gym Tracker "leftovers" (the user: "lets fix Gym leftover and kilter"). Restyle the timers:
- `StructuredTimedRunner` (interval runner + end card)
- `TimedSetCover` (Time this set)
- `TimedAttemptCover` (timed climb attempt)
- `StopwatchView` (Add set's timer)

It is visual only: ids and actions are unchanged.

## Approach

- **Background:** plain paper (was a per-phase orange-brown / blue wash). The phase word and ring carry the phase:
  Work = the accent, Rest = grey, Ready = white, Done = green.
- **Phase word:** sentence case via `sentenceCase()`; the model's labels stay caps. "Load to start", "Paused" and
  the self-paced "Done" are sentence case too.
  - `StructuredIntervalRunnerTests` now expects "Go" / "Rest" (display text only).
- **Numbers:** light (were heavy rounded): ring, open-rep timer, force kg, end-card elapsed, covers, stopwatch.
- **Stop:** a **red outline** on every timer (the user's call). That covers Stop, Stop & log and the stopwatch's
  running Stop. Start is the accent fill.
- **Chips, Pause / Skip, HR chip, Peek canvas:** hairline outlines (were white fills / material).
- **End card:**
  - a `snappetPanel` summary and a sentence "You changed" panel
  - Keep for next time / Log set use `SnappetWidePrimaryStyle`; Just this once is an accent outline
  - Use as my max is a green outline
- **Force:** under-target amber and the band green are meaning colours (were system orange / green). The
  one-hand indicator is an accent capsule.
- **Timed attempt:**
  - the grade is a light number on a neutral tile (was a Kilter-amber / blue pill)
  - outcome buttons are outlined in `KilterAscentStyle.color` (were solid fills)

## Acceptance

- [x] Timer suites green: StructuredIntervalRunner (except the known `525 kg`), ClimbAttemptTimer, TimedSetTimer,
  TimedStrengthSet. Dark screenshots match the mockup.
- [x] Full UI suite: only the known `525 kg` test failed. Unit suite alone: 2653 green.
- [x] Device: user on MrRobot 2026-11-03 ("merge after testing").
