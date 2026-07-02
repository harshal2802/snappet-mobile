# Prompt: Compact "On the board" re-light strip (give the list its screen back)

**File**: pdd/prompts/features/kilter-ux-feedback/03-compact-relight-strip.md
**Created**: 2026-07-02
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: kilter-ux-feedback/PLAN.md → F4
**Source**: Real-user feedback: *"most recent climbs takes a lot of screen real estate on the list"*
· wireframe flows F4 A/1/2
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Keep the P5 rail's two jobs — see what was recently on the board, re-light it in one tap — at a
fraction of the vertical cost, so the browse list (the screen's actual job) gets its rows back.

## Context the implementer needs

The root's "Recently on the board" rail rendered full cards: a 96×110 board thumbnail
(`KilterThumbnailCache`), the climb name, a status chip, and a Re-light button — ~200 pt of chrome
above the list, on top of the filter bar, session slot, and count line. On a 6.1″ phone that left
~3 climb rows visible. The full-card experience already exists one tap away: the On the Board
timeline (`KilterOnTheBoardView`), unchanged.

## Approach

Replace the rail with a single-line chip strip (~36 pt): `ON THE BOARD` label + horizontally
scrolling capsules + `All ›`. Each capsule = status dot (send/attempt/lit tint; the status also rides
the name's accessibility label so color is never the only signal) + climb name (button → climb
detail) + an always-visible ⚡ (button → the existing `relightRecent` path: illuminate + upsert lit
event + haptic). Because the compact chip has no room for inline feedback, ⚡ confirms with the
root's transient bottom notice — honest about whether holds actually lit ("X is on the board" vs
"Saved to On the Board — connect to light holds") — with an "Open" shortcut. The root's
`KilterThumbnailCache` and the card/thumbnail builders go away. Same data (`recentRail`, limit 8),
same hidden-until-lit gating, same `kilter.board.recentRail` / `railCard` / `rail.relight` ids.

## Output

- `KilterRootView.swift` — compact `recentlyOnTheBoardRail` + `recentChip`, `RootNotice` +
  `noticeView` (shared with F3's reset notice), `relightRecent` confirm, cache removal.

## Acceptance criteria

- [ ] With lit history, the strip is one line; six-ish climb rows fit where ~3 did.
- [ ] Chip name opens the climb; ⚡ re-lights without leaving browse and confirms via the notice.
- [ ] Strip stays hidden until something was lit (existing UI test on `kilter.board.recentRail`).
- [ ] VoiceOver reads name + status on the chip and "Re-light <name>" on ⚡.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated.

## Constraints

- Do not touch `KilterOnTheBoardView` (the full experience) or the P5 capture semantics
  (`upsertLitEvent` into the CURRENT session only).

## Test plan

1. Full `SnappetTests` + `KilterOnTheBoardUITests` on the simulator.
2. By eye: strip height, chip tap targets, notice auto-dismiss; device-pending: a real re-light.
