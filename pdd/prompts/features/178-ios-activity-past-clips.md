# Prompt: Activity progress P1 — every past clip of an activity

**File**: pdd/prompts/features/178-ios-activity-past-clips.md
**Created**: 2026-10-12
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: activity-progress ideation (`docs/ux-research/activity-progress/ideation.html`, §03 screens A–C, §08 P1) —
user approved the plan and the recommended decisions (climb = both levels, untagged = nudge, dashboard = own route)
**Context**: `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

For any exercise / climb in a session, let the user see every photo and video tagged to that activity in PAST
sessions, each stamped with the set it was filmed during and its heart rate — so footage reads as progress over time.

## Context the implementer needs

- `SessionMedia` already carries `sessionID` + `assignedExerciseID` (+ set index); the exercise's `exerciseId` is
  stable across sessions for catalog exercises. Ad-hoc entities (`adhoc-*`) share one id, so they are identified by
  display name (the `QuickSessionPager.lastSessionSets` rule). No schema change is needed.
- The live player re-renders ~1 Hz — nothing heavy may run in its body.

## Approach

- Pure `ActivityMediaIndex` (Foundation only): `ActivityKey.of(_:)`, `counts`, `groups(for:)`, `untaggedCount`,
  `averageBPM`. Value snapshots (`ActivityMediaInput`) so tests need no SwiftData.
- `ActivityClipsViews.swift`: `PastClipsChip`, `ActivityClipsSheet` (summary · per-session poster grid with set + ♥
  stamps · untagged nudge), `ActivityClipViewer` (paged fullscreen across sessions, each clip with its own session's
  HR scorebug via `ClipHROverlay`, transport bar).
- Chip on the pager page header (`FreeformPlayerView`, counts computed once per presentation) and on each exercise
  header in `SessionDetailView` (sheet hosted on the List — the stable-host rule).
- `-uiTestSeedActivityClips` (`ActivityClipsSeed`) layers tagged bench clips on the routine-history seed.

## Acceptance criteria

- [x] Pager + session detail show "▶ N past clips" only when the activity has past clips (UI test).
- [x] Sheet groups by session newest first, stamps set + HR, notes untagged clips (UI test + unit tests).
- [x] Fullscreen viewer pages across sessions; scorebug clears the transport bar (screenshot-checked).
- [x] `ActivityMediaIndexTests` green; app builds; knowledge graph updated.
- [ ] Device: real clips play with the right session's HR; posters load from the library.

## Constraints

- On-device only. Unnamed ad-hoc entities get no chip (they have no cross-session identity).
