# Prompt: Design-system reset — widgets & Live Activities (prompt 243)

**File**: pdd/prompts/features/design-system/243-ios-widgets-restyle.md
**Created**: 2026-11-05
**Project type**: Native iOS (SwiftUI + WidgetKit / ActivityKit) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "looks good")**: `docs/ux-research/design-system/widgets.html`

## Goal

Restyle the last surfaces still in the old module colours:
- the Today, Buddy and Household widgets
- the Workout, Kilter, Pomodoro and Power hour Live Activities

Layouts, data and intents are unchanged.

## Approach

- **The accent reaches the extension:**
  - The extension can't read the app's defaults. `SnappetAccent` (the pure palette) moves to
    `Shared/SnappetAccentPalette.swift`.
  - The app's theme modifier publishes the picked accent into the App Group (`SnappetAccent.publish`, on appear and
    on change).
  - It reloads widget timelines only when the value changed.
  - Live Activities pick it up on their next update. Nothing published means Periwinkle.
- **`WidgetPalette` (widget target only):**
  - `accent` is light / dark dynamic, for the system-background Today widget.
  - `accentOnDark` is for the dark surfaces: Live Activities and the Buddy / Household widgets.
  - Meaning colours: `fresh` / `warn` / `hard`.
- **Per surface:**
  - Today: the streak flame and its light number, habit ticks and Start focus take the accent (were orange / green /
    system blue).
  - Buddy:
    - The bar takes the accent (was ember).
    - "Your buddy" is sentence case; weights are semibold.
    - The form line follows the buddy's rule: accent while resting, green from 45%, amber below.
  - Household: sage becomes the accent. The CAPS headers are sentence case. Overdue is red, as in the app.
  - Workout / Kilter:
    - The routine, timer glyph and keyline take the accent (were orange / green).
    - "PAUSED" becomes an amber "Paused" outline; Recovered is a green outline.
    - The timers are light. HR zone colours are unchanged.
  - Pomodoro: focus takes the accent (was red); break stays green.
  - Power hour: sage becomes the accent; the countdown is light.

## Acceptance

- [x] Unit: `SnappetAccentPublishTests` (round trip, change-only reload, unknown value / no container → default).
- [x] Unit suite alone green; the watch target builds (it compiles `Shared/`).
- [x] Device: user on MrRobot 2026-11-05 ("merge it"; add the widgets; start a workout / power hour / focus). Simulator shots aren't
  possible for widgets here, so the mockup's "before" side is drawn from the code.
