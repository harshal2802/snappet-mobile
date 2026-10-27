# Prompt: Makefile resolves the simulator to an id (prompt 206)

**File**: pdd/prompts/features/206-tooling-makefile-sim-id.md
**Created**: 2026-10-25
**Project type**: Tooling (Makefile) — no app code.
**Context**: `pdd/context/conventions.md`, `pdd/context/decisions.md`; follows prompt 105 (Makefile).

## Goal

`make ios-test-unit` / `make ios-test` / `make ios-sim` exited 70 with "Unable to find a device matching the
provided destination specifier" once Xcode installed the iOS 27.1 simulator runtime: `name=iPhone 17 Pro`
resolves with `OS:latest`, and that device only exists on iOS 26.5.

## Approach

- `SIM_ID` (overridable): the id of the `SIMULATOR`-named device on the **newest** iOS runtime that has one,
  read from `xcrun simctl list devices available`. `DEST_SIM` uses `id=` when found, else falls back to the
  old `name=` destination (unknown name, or not macOS).
- `ios-run` boots by the same id, so it boots the device xcodebuild built for.
- `make help` prints the resolved id.

## Acceptance

- [x] `make -n ios-test-unit` → `id=3AB1FD60-…` (the 26.5 iPhone 17 Pro); an unknown `SIMULATOR` → `name=` fallback.
- [x] `make ios-test-unit` green (2535) on this machine, where it previously exited 70.
