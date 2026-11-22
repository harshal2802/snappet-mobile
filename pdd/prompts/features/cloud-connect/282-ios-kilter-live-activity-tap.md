# Prompt: Tapping the Kilter session banner opens Kilter

**File**: pdd/prompts/features/cloud-connect/282-ios-kilter-live-activity-tap.md
**Created**: 2026-11-21
**Project type**: iOS (app + widget extension)
**Chain**: follow-up to prompt 279 (the same complaint, fixed there for gym sessions)
**Context**: `pdd/context/decisions.md`

## Problem

The Kilter Live Activity (Lock Screen, notification list, Dynamic Island) had no tap link. A tap
opened the app on whatever screen it was last on.

## Change

- `KilterActivityAttributes.openURL` = `snappet://kilter/session`, set as the `widgetURL` of the
  Lock Screen view and the Dynamic Island.
- `SnappetDeepLink.kilterSession` parses exactly that link. Climb links are unchanged.
- `RootShell.handle`: `KilterOpenLink.decide(rootModule:)` — Kilter already open in the Apps tab →
  show that tab and keep its screens; otherwise open the Kilter board, where the session card is.
- `SuiteRouter.rootModule`: the mini-app at the bottom of the Apps stack, kept by `open(module:)`,
  `push` of a `ModuleRoute` onto an empty stack, and cleared when the stack empties.

## Tests

`KilterDeepLinkTests`: the link parses to the route (and near-misses do not), the stay/open
decision, and the router's `rootModule` through push, open and back.

## Not verified

On a phone with a running Kilter session. The simulator cannot tap a Live Activity.

## Not done

A closed app does not reopen on a running Kilter session by itself (prompt 279 did that for gym
workouts only); the tap covers it.
