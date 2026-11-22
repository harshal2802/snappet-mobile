# Prompt: Returning to a running workout does not show the Gym Tracker first

**File**: pdd/prompts/features/cloud-connect/290-ios-session-return-without-the-tracker-flash.md
**Created**: 2026-11-22
**Project type**: iOS
**Chain**: follow-up to prompts 265 (F15) and 279

## Report

"Every time I tap the session's notification to open the session it shows the Gym Tracker first and
then pops out the session. Is it on purpose?"

## Cause

Not on purpose. The session screen is a full-screen cover owned by the Gym Tracker's home view, so
a return from outside opens the Gym Tracker (animated push) and then the cover slides up over it.

## Change

For a return from outside the app (the Live Activity's tap, a fresh start mid-workout, Home's
resume card through the router's one-shot), both steps run with animations disabled: the shell
opens the module with `openWithoutAnimation`, and `resume(_:animated: false)` presents the player in
a transaction with `disablesAnimations`. Starting or resuming from inside the Gym Tracker still
animates.

## Tests

`WorkoutBrokenLinksUITests` (7 pass): the link and the fresh start still reach the player.

## Not verified

That the flash is gone to the eye: the simulator tests cannot judge it. To be checked on the phone.
The Gym Tracker is still built underneath, so a frame of it may show on a cold start.
