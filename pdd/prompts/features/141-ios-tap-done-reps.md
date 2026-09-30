# Prompt: "Until I tap done" reps (Contact)

**File**: pdd/prompts/features/141-ios-tap-done-reps.md
**Created**: 2026-09-30
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: hangboard-protocols — 139 → 140 → **141 tap-done reps** → 142 load + hands → 143 mid-run adjust → 144 any-frequency → 145 force sensor
**Design**: `docs/ux-research/hangboard-protocols/wireframes.html` frames 1 (Each rep), 5 (runner)

## Goal

Contact-style reps (and any single effort that isn't a fixed-length hang) had no representation: a 0 s
"on" time produced a timeline with no work at all. The owner: "these isometric holds could be just
single reps but may be timed".

## Approach

- `TimedExerciseSpec.selfPacedWork: Bool?` — optional, never encoded for timed protocols, so every
  existing protocol / routine / backup / QR is byte-identical; `isSelfPaced` only for repeaters/tabata.
- `IntervalSchedule`: a self-paced rep is an **open-ended work phase** (0 s, `isOpenEnded`);
  `state(at:completedOpenReps:)` blocks on the first unfinished one; `State.startOfPhase` lets the runner
  anchor exactly. Timed protocols walk exactly as before.
- `RunnerViewModel`: schedule time = wall time − time inside open reps (frozen during a rep, resumes
  exactly after); `completeOpenRep()`; Skip on an open rep completes it; TUT includes tap-done reps.
- Runner: count-up + big **DONE** during an open rep. Editor: "Each rep: Timed hang / Until I tap done";
  **Contact** preset (3 × 5, 30 s, 3 min); summary "… each until you tap done … + your reps".

## Acceptance criteria

- [x] Contact runs: each rep waits for DONE (never times out), then the rest; stop logs the reps' time.
- [x] Timed protocols unchanged (schedule + encoded bytes).
- [x] `SelfPacedRepTests` (10) + `StructuredIntervalRunnerTests.testContactRepWaitsForDoneThenRests`; existing schedule tests green.
