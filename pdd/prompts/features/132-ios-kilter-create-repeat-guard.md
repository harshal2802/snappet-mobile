# Prompt: A repeat guard for the create-climb → detail race

**File**: pdd/prompts/features/132-ios-kilter-create-repeat-guard.md
**Created**: 2026-08-31
**Project type**: Native iOS test (Swift / XCUITest) — code lands in this repo.
**Chain**: closes the device leg owed by prompt 124 (PR #307) — user: "help me test for create-climb repeats"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Prove the create-climb → detail push actually lands, every time. Prompt 124 fixed an
**intermittent** SwiftUI drop (dismiss + push in one transaction) with stash-and-promote, but it
shipped with no automated coverage — "no UI test installs a catalog" — so its only verification was
"tap it a few times by hand", which cannot prove an intermittent fix.

## Context the implementer needs

- Both hosts push on create and both had the race: `KilterRootView` (browse `+`) and
  `KilterCreatedView` ("Set a climb"). A guard must cover both.
- `-uiTestInstallKilterCatalog` already seeds a catalog (`KilterCatalogFixture`), so the earlier
  "can't test this" assumption was wrong — only the hold placement was actually blocking.
- Saving requires `kilterValidate`: ≥4 holds including a start and a finish. Placing those means
  tapping exact points on a rendered board — not reliably drivable from XCUITest.
- The saved uuid is a CONTENT hash of the frames, so repeating one draft hits the duplicate path
  ("Open existing") instead of creating anew; each pass needs distinct frames.

## Approach / Output

- `CreateClimbView`: a launch-arg-gated ("-uiTestKilterCreateSample") "Sample" toolbar button that
  fills a valid four-hold draft, varying one placement id per fill so every pass is a NEW climb.
  Same shape as the festival canned-scan seam; absent from the shipped app. Everything after the
  fill — validation, save, uuid hand-off, push — is the real production path.
- `KilterCreateClimbRepeatTests`: 5 consecutive create → save → detail hops per host, asserting the
  detail opened each time (`kilter.favorite`), then popping back.

## Acceptance criteria

- [ ] Both tests pass on the simulator AND on a physical device (the race was hardware-timing).
- [ ] Each pass creates a distinct climb (no duplicate-path short-circuit).
- [ ] The seam is invisible without the launch arg.

## Test plan

1. `-only-testing:SnappetUITests/KilterCreateClimbRepeatTests` on the simulator.
2. The same on MrRobot via `-destination id=…` — **the leg prompt 124 owed**.
