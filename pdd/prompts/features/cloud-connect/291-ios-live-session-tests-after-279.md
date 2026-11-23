# Prompt: The live-session UI tests accept that the workout opens by itself

**File**: pdd/prompts/features/cloud-connect/291-ios-live-session-tests-after-279.md
**Created**: 2026-11-22
**Project type**: iOS (UI tests)
**Chain**: follow-up to prompts 279 and 283

## Problem

CI on main failed in one UI leg: five tests of `LiveSessionSafetyUITests` at the same line. Since
prompt 279 a fresh start with a workout running opens that workout's player. These tests seed a
running session (`-uiTestRacketLive`) and then walked to the player through Apps → Gym Tracker →
Quick Start, where the Gym Tracker card is no longer on screen. Nobody saw it because no UI test
ran in CI from 2026-11-21 until prompt 283.

## Change

`openLivePlayer()` first waits for the player (`minimizeWorkout`) and returns if it is up; the walk
is kept for a launch that did not open it.

## Tests

`LiveSessionSafetyUITests`: 6 of 6 pass locally on a freshly booted simulator. (A first local run on
a simulator that had been up for hours was slow and failed three tests further in, one taking 35
minutes; not reproduced after a restart.)
