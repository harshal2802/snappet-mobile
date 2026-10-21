# Prompt: Other apps can start and log workouts in Snappet — App Intents + `snappet://` workout links

**File**: pdd/prompts/features/199-ios-workout-app-intents.md
**Created**: 2026-10-20
**Project type**: Native iOS feature (Swift / App Intents / SwiftData) — code lands in this repo.
**Context**: `pdd/context/decisions.md`

## Ask

User (2026-10-20): "can we expose app intents so that other apps can start or log activities in snappet app?"
First of three (A: intents + links → B: universal https links → C: QR photo import).

## Build

- **App Intents** (app target, `WorkoutAppIntents.swift`), all in the Shortcuts app with Siri phrases
  (`SnappetShortcuts`, now 9 shortcuts):
  - **Start a Quick Session** [activity] — opens the app; resumes the running session if there is one.
  - **Log a Set** activity, reps, weight, seconds, metres — does NOT open the app. Numbers left out repeat the
    activity's last set.
  - **Log a Climb Attempt** climb, Fall / Project / Sent / Flash — does not open the app.
  - **Finish Workout** — opens the app; finishes the running session the way the player's Finish does.
  - `ActivityEntity` = a row of your Library's Yours list (id = `LibraryEntry.raw(key)`), most used first.
- **`WorkoutIntentService`** (main actor, the app's own `ModelContext`): logs land in the RUNNING session, or a new
  Quick Session if none is running. They go on the activity's entity in it, added as last time when it's missing.
  Pure `IntentSetBuilder` builds the set.
- **`snappet://` workout links** (pure `WorkoutLinkAction`): `quick[?activity=]`, `log?activity=&reps=&weight=
  [&unit=&seconds=&meters=]`, `attempt?climb=&outcome=`, `finish`. They are routed by `RootShell.handle`. A log
  link keeps an open player in place and only opens the Gym Tracker when it started the session.
- The store is handed to App Intents with `AppDependencyManager` in `SnappetApp.init`.

## Acceptance criteria

- [x] `WorkoutIntentTests`: log starts a Quick Session + repeats last time; second log → same entity; climb
      attempt; errors; set builder; link parsing; routing; the log link against the UI-test seed.
- [x] `WorkoutLinkUITests`: quick → the player opens on Bench; log → `5 × 82.5 kg` shows in the open player;
      finish → back to Quick Start.
- [ ] Device: Shortcuts app shows the 4 actions; "Log a Set" with the app closed, then open → the set is there;
      Siri phrase; a `snappet://log…` link from Notes / Safari.
