# Prompt: A fresh start during a Kilter session returns to the Kilter board

**File**: pdd/prompts/features/cloud-connect/285-ios-fresh-start-returns-to-kilter-session.md
**Created**: 2026-11-22
**Project type**: iOS
**Chain**: follow-up to prompts 279 and 282

## Problem

Prompt 279 made a fresh start of the app during a gym workout go back to the workout. A Kilter
session got no such return: the app opened on Home.

## Change

`SessionReturn.destination(workoutStart:kilterStart:now:alreadyRouted:)` (pure) picks the workout
player, the Kilter board, or nothing. Same 4-hour limit and the same "a link that started the app
decides" rule as before. With both unfinished, the one started last wins. `RootShell` opens the
Kilter module for `.kilter`; the session card is on the board.

## Tests

`CloudBackupTests.testAFreshStartReturnsToTheSessionThePersonIsIn`.

## Not verified

On a phone with a running Kilter session.
