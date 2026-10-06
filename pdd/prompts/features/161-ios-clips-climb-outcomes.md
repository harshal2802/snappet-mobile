# Prompt: Clips — show how each climb went (Flash / Sent / Project) + a Sends chip

**File**: pdd/prompts/features/161-ios-clips-climb-outcomes.md
**Created**: 2026-10-06
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips review 2026-10-05 → item 2 of 3 (160 share with HR · 161 climb outcomes · 162 durable favorites)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

A climb post says "Attempt 3" but never whether you sent it. The outcome is already logged — Kilter's
`KilterLogEntry` (one row per climb per session) and Quick Session's per-attempt `SetLog.climbStatusRaw` — so
show it, and let people filter to their sends. The feed becomes "my sends", not just "my videos".

## Context the implementer needs

- `ClipFeedComposer` is pure; `ClipsFeedView.makeSnapshot` is the store edge. `climbMeta` is keyed by climb
  only (latest log wins) — fine for name/grade, wrong for outcome, which is per session.
- The Kilter logger accumulates one row per climb per session, status sticky once sent.
- Quick Session clips are tagged `exerciseId` (the climb exercise) + `setIndex` (the attempt).
- `dedupedByAsset` and the reel/festival partition both rebuild `SessionBundle`s — new fields must survive both.

## Approach

- `ClipFeedClimbResult` (status, attempts, per-attempt statuses for Quick Session) on `SessionBundle`
  (`climbResults`, keyed by the post group key) → `ClipFeedPost.climbResult`.
- Quick Session climb chips read "Attempt N" (not "Set N") and the sending attempt "Attempt N · Sent"; Kilter
  chips stay clip-index labels (attempt timestamps don't map onto clips reliably).
- Header badge FLASH / SENT / PROJECT in `KilterAscentStyle` colours; a plain attempt gets no badge.
- `ClipFeedFilter.sendsOnly` + a "Sends" chip (flash + sent), stacking like Favorites.
- No FeedKey change: outcomes are logged off-tab and the feed rebuilds on tab entry (`.task`).

## Acceptance criteria

- [x] A Kilter post shows its own session's result; another session's send on the same climb doesn't leak.
- [x] A Quick Session climb shows "Attempt N" chips and marks the attempt that sent; strength keeps "Set N".
- [x] "Sends" keeps flash + sent posts and stacks with the other chips.
- [x] `SnappetTests` green, 0 new warnings.
- [ ] Device: badges on real Kilter + Quick Session posts; the HR share caption carries "Attempt N · Sent".

## Test plan

1. `make ios-test-unit` — `ClipFeedComposerTests` (per-session result, Quick Session labels, merge/badge),
   `ClipFeedFilterTests` (Sends).
2. Device: log a send on a climb with a clip, return to Clips, check the badge and the chip.
