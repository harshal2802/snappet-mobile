# Prompt: Light Kilter climbs only when asked (prompt 210)

**File**: pdd/prompts/features/kilter-connect/210-ios-kilter-manual-light.md
**Created**: 2026-10-29
**Project type**: Native iOS (Swift / SwiftUI) — code lands in this repo. Stacked on #401.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

User, after a real-board test (2026-10-29: checks 1–9 of #398/#399/#401 passed): "when I switch between the climbs it
automatically lights the climb — can we have a setting where we only light the climb on tapping the button?"

## Approach

- Kilter Settings → Lighting: **Light climbs automatically** (on by default — the existing behaviour).
- Off: opening or swiping to a climb never lights it; only **Light up this climb** and the board pill do. A board
  connect / reconnect or a board-size ("wrong holds?") fix re-sends a climb only if you lit it on this screen, so
  those still show the right holds.
- Pure rule `KilterAutoLight.shouldLight(trigger:automatic:litByYou:)`, unit-tested (`KilterAutoLightTests`).
  Create-a-climb keeps its own "Auto-light each new climb" toggle (prompt 155).

## Acceptance

- [x] Unit + Kilter UI (Settings / climb / walkthrough) green.
- [ ] Real board: with the switch off, swiping between climbs leaves the board alone; the button lights it.
