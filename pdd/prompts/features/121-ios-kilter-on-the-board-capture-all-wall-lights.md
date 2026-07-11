# Prompt: Kilter — "On the Board" records every wall-light, not just the explicit button

**File**: pdd/prompts/features/121-ios-kilter-on-the-board-capture-all-wall-lights.md
**Created**: 2026-07-11
**Project type**: Native iOS bug fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: Kilter improvement initiative (epic #199) → P5 "On the Board" follow-up.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

**On the Board** (the lit-history timeline) showed only a single climb after a session in which the climber
lit *several*. The screen is correct — it queries every `KilterLitEvent` and the pure `KilterOnTheBoard`
grouping keeps one row per climb-per-session. The defect is upstream: almost nothing **wrote** a lit event.
Capture was gated to the single explicit **"Light up this climb"** button, so every other way a climb
actually lights on the wall — the board first connecting, swiping/opening a climb (auto-light), the
fast-path "On the board" pill, a size remap — recorded nothing. A real session (connect once, then swipe
climb-to-climb) therefore logged at most the one climb whose button the climber happened to tap.

Fix: **a climb counts as worked exactly when its holds reach a connected board — regardless of which
control triggered the light.** Record all of those; record nothing when no board is on the wall.

## Context the implementer needs

- The lit-event write is the shared `upsertLitEvent(...)` free function
  (`Features/Kilter/KilterClimbDetailView.swift`), keyed on `(normalized climbUUID, sessionId)` — idempotent,
  so overlapping light sites for the same climb bump one row instead of duplicating it.
- Capture used to live only in `lightAndCapture()` (explicit button) + the two re-light buttons
  (`KilterRootView`, `KilterOnTheBoardView`) + `confirmBoardSetup`. Five *other* `board.illuminate(holds)`
  sites in `KilterClimbDetailView` were deliberately "illumination ONLY — no capture (decision F1)": the
  `onChange(board.isConnected)` first-light, the `onChange(productSizeId)` remap, the `boardPillTapped`
  connected case, and the `load()` open/swipe auto-light. That decision (avoid a "passive browse log")
  over-corrected — it dropped genuinely-worked climbs.
- `KilterOnTheBoard.status(...)` joins a lit event with the ascent log; a climb with a logged send but **no
  lit event never appears**. So the missing lit events were the whole failure.

## Approach

1. **One funnel.** Replace `lightAndCapture()` with `illuminateAndCapture()`:
   `board.illuminate(holds); if board.isConnected { captureLitEvent() }`. Route **every** detail-view light
   site through it — the explicit button (`attemptLight`), the pill (`boardPillTapped`), and the three
   auto-lights (connect / size remap / open+swipe). The `board.isConnected` guard is the whole policy: a
   swipe or remap on the simulator (no board) updates the on-screen render and records nothing; a light that
   reaches the wall is captured.
2. **Leave `log()` untouched.** Logging an attempt/send does **not** fabricate a lit event — the chosen
   policy is "any wall-light", not "any logged climb" (a climb logged from memory with no board on the wall
   shouldn't appear in a *lit*-history).
3. **Untouched:** the calibration light in `KilterBoardSetupSheet` (not a climb) and the `CreateClimbView`
   authoring preview (design preview) stay non-capturing, so neither pollutes worked-climbs history.

## Output

- `Features/Kilter/KilterClimbDetailView.swift` — `illuminateAndCapture()` funnel; 5 call sites repointed;
  comments updated to the new policy (the old "F1 — no capture" notes rewritten).
- `pdd/context/decisions.md` entry (supersedes the F1 no-auto-capture stance).
- `docs/knowledge-graph/data.js` — refresh the On-the-Board node note (behavior change, no new node/edge).

## Acceptance criteria

- [x] With a board connected, opening/swiping to a climb, the pill, a size remap, first-connect, and the
      explicit button all record the climb (deduped one row per climb-per-session).
- [x] No board connected (simulator) → no lit events written from any of those paths; UITest behavior
      unchanged (all new sites gate on `board.isConnected`, false when `state == .unsupported`).
- [x] Logging an ascent alone does not create a lit event.
- [x] App type-checks (Swift 6, 0 warnings); full unit suite green.
- [ ] Device (owed, needs a real Kilter board): connect, swipe through several climbs, confirm each lands as
      a row in On the Board with correct status.

## Constraints

- On-device only; no backend. `KilterBoardController` stays platform-pure ([KilterHold] in).
- BLE is hardware-dependent: the "does a real wall-light get captured" leg is device-pending (the simulator
  never connects a board, so the capture guard is always false there).

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — full unit suite (pure `KilterOnTheBoard` logic
   unchanged; regression guard).
2. `make ios-sim` — build-for-testing on iPhone 17 Pro (Swift 6, 0 warnings).
3. Device (owed): connect a board, swipe/open several climbs + tap the pill, verify each appears in On the
   Board; confirm a size remap on the simulator records nothing.
