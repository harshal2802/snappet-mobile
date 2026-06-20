# Prompt: P5 — On the Board (history of climbs you lit)

**File**: pdd/prompts/features/kilter-improvement/P5-on-the-board.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI; new SwiftData `@Model`).
**Chain**: PLAN.md → P5 (depends on P0)
**Source**: GitHub issue — Kilter Improvement P5
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Design**: `docs/ux-research/kilter-improvement/README.md` §4 (Flow 5) · wireframes `05_ontheboard`, `05b_recent_rail`

## Goal

Capture and surface a brand-new axis the app can't show today: a history of every climb the user **lit on
the board** — including the ones they pulled up and worked but never formally logged — with status joined
from their ascent log and one-tap re-light.

## Context the implementer needs

- Lighting a climb is `KilterBoardController.illuminate(holds)` (`:197`), called from
  `KilterClimbDetailView.swift:545/725` (and the create/preview `liveLight`, `CreateClimbView.swift:334`).
  The controller keeps only the **most-recent** requested holds in memory (`:54`) — nothing is persisted.
  The climb identity is known **at the call sites**, not inside the controller (which only has `[KilterHold]`).
- The only persisted climb action today is `KilterLogEntry` (ascents) — so non-logged lights are invisible.
- Status join: count/derive from `KilterLogEntry where climbUUID == …` to label each lit climb Lit /
  Attempt / ✓ Sent (the `logCount` pattern, `KilterClimbDetailView.swift:674`).
- Thumbnails reuse `KilterBoardView`; re-light reuses `board.illuminate(holds)`. P0 supplies the hero count
  + grouping helpers.
- A new `@Model` pays the `SnappetSchema.models` (`SnappetCore.swift:39-53`) + `SnappetBackup`
  Row/File/recordCount/snapshot/restore mirror (use `KilterSessionRow` as the template) with both
  `SnappetBackupTests` tripwires green.

## Approach

- Add a `KilterLitEvent` `@Model`: `{climbUUID, climbName, gradeLabel, angle, layoutId, sizeId, litAt,
  wasConnected}`. Record it at the `illuminate()` **call sites** (where the climb is known), **deduped per
  climb-per-session** so the log stays bounded (decide: only `wasConnected` real-board lights, or also
  previews — see open question). Keep capture out of the platform-pure controller.
- Add `KilterOnTheBoardView` (new route): a hero "N climbs worked" + filters (status / angle / board), a
  timeline grouped by day/session with roll-ups, each row = mini board thumbnail + name + grade/angle/time +
  status chip (Lit / Attempt / ✓ Sent) + one-tap **re-light** (`board.illuminate`).
- Add a "Recently on the board" re-light rail to the Kilter root (resume a project in one tap) + a tab/entry.
- Register the new `@Model` in `SnappetSchema.models` + add the `SnappetBackup` mirror. Keep dedup/grouping/
  status-join logic pure + unit-tested.

## Output

- `KilterLitEvent.swift` (`@Model`) + the capture hook at the `illuminate()` call sites.
- `KilterOnTheBoardView.swift` + route registration + the root re-light rail.
- `SnappetBackup` Row + `SnappetSchema` registration. Pure dedup/grouping/status-join helpers + `SnappetTests`.
- `docs/knowledge-graph/data.js` new On-the-Board node + edges. XCUITest.

## Acceptance criteria

- [ ] Lighting a climb records a deduped `KilterLitEvent`; the On the Board timeline lists climbs worked
      (grouped by day/session, roll-ups) including non-logged "· Lit" climbs, with status joined from
      `KilterLogEntry` and a one-tap re-light.
- [ ] The Kilter root shows a "Recently on the board" rail that re-lights a recent climb in one tap.
- [ ] `KilterLitEvent` round-trips through `SnappetBackup`;
      `SnappetBackupTests.testCodecCoversEverySchemaModel` + the count tripwire stay green.
- [ ] Dedup/grouping/status-join helpers are pure + unit-tested; capture logic stays out of the
      platform-pure `KilterBoardController`. App type-checks (Swift 6, 0 warnings); `decisions.md` updated.

## Constraints

- On-device only; local data only. Keep the lit log bounded (per climb-per-session dedup). The
  re-light + live capture leg is **device-pending** (MrRobot) — keep helpers pure + unit-tested so the PR
  ships green without a board.

## Test plan

1. Unit: dedup/grouping/status-join + backup round-trip green; build-for-testing.
2. XCUITest: light a climb (mocked) → appears in On the Board with correct status → re-light from timeline
   and from the root rail. Device pass (MrRobot): real illuminate → event recorded → re-light works.
