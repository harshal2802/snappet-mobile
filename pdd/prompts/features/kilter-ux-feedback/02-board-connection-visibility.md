# Prompt: Board connection you can see (root strip + detail pill)

**File**: pdd/prompts/features/kilter-ux-feedback/02-board-connection-visibility.md
**Created**: 2026-07-02
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: kilter-ux-feedback/PLAN.md → F1
**Source**: Real-user feedback: *"connecting to the board was hard to see"* · wireframe flows F1 1–4
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make the BLE board connection visible and reachable where the climber actually is: the browse screen
gets a persistent board + session strip (status dot, plain words, one-tap Connect), and the climb
detail answers "am I connected?" with a glass pill on the board render itself.

## Context the implementer needs

`board.connect()` was only reachable from `illuminateSection` — the 8th block down the climb-detail
scroll (below render, legend, angle picker, stats, meta, session row, logging, grade chart). The root
had no connection surface at all; its session slot showed either the live session bar or an idle
"Start session" pitch. `KilterBoardController.state` already models every state
(unsupported/bluetoothOff/unauthorized/idle/scanning/connecting/connected/failed).

## Approach

- **Root strip** (`boardSessionStrip`, replacing `idleSessionBar`): reuses the session slot — zero new
  vertical cost. Status dot (green connected / pulsing amber busy / gray otherwise — words always
  beside it), state title + subtitle, and the state's one action (Connect / Cancel / Settings for
  unauthorized). Start session stays in the row (same path, same `kilter.session.start` id). With no
  radio (simulator) the board half collapses to the original pitch, so UI tests are unaffected.
- **Board name**: `recognizeBoard` stores the recognized label (`connectedBoardLabel`), cleared on
  disconnect; the active session bar shows it in place of the generic "Session" word (a BLE connect
  auto-starts a session, so the strip and the bar never fight for the slot).
- **Detail pill** (`boardStatusPill` on `boardSection`): glass capsule at the render's top-trailing —
  idle/failed → "Connect board" (taps `connect()`), busy → progress (taps `cancel()`), connected →
  "On the board" (re-sends the holds). The full section below (wrong-holds fixes, disconnect) stays.

## Output

- `KilterRootView.swift` — `boardSessionStrip` + dot/title/subtitle/action helpers, session-bar label,
  `connectedBoardLabel` wiring.
- `KilterClimbDetailView.swift` — `boardStatusPill` + tap routing on the board render.

## Acceptance criteria

- [ ] On the browse screen the connection state is readable at a glance in every controller state,
      and idle → Connect starts the scan without leaving the screen.
- [ ] The detail render carries the pill in every state; connected-tap re-illuminates.
- [ ] Simulator (no radio): the strip shows the original session pitch; the pill is absent.
- [ ] `kilter.session.start` UI tests pass unchanged.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated.

## Constraints

- Status is never color-alone (dot + words; pill icon + words) — the module's colorblind stance.
- No new screens; the strip never blocks browsing.

## Test plan

1. Full `SnappetTests` + `SnappetUITests` on the simulator (strip's unsupported branch).
2. Device-pending: real BLE connect/cancel/failed transitions on a physical board.
