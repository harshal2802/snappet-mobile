# Prompt: <Feature name>

**File**: pdd/prompts/features/<NN-slug>.md
**Created**: YYYY-MM-DD
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: <which PLAN + phase, e.g. PLAN-ios-to-shippable.md → P4>
**Source**: GitHub issue [#60](https://github.com/harshal2802/Snappet/issues/60) §<x> (if applicable)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

<One paragraph: what this builds and why it matters now. Trace the "why" to the research / PLAN.>

## Context the implementer needs

<Only what's not obvious from the context files: the specific files this touches, the current
behavior, the constraint that makes this non-trivial. Assume the reader has the context files, this
prompt, and the codebase — nothing else.>

## Approach

<The intended shape of the solution. Name the files to add/change. Respect the layering rule
(engine stays platform-free; platform I/O in Services; wiring in AppModel).>

## Output

<Concretely what to produce: which files, what each contains.>

## Acceptance criteria

- [ ] <Observable, checkable outcomes — behavior, not vibes.>
- [ ] Engine changes ship with passing `swift test` (if `HighlightEngine` is touched).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated if a non-obvious choice was made.

## Constraints

- On-device only; no backend/network/accounts. Keep the selector pluggable (no HR-only hardwiring).
- State verification honestly: type-check ≠ device run for HealthKit/Photos/AVFoundation features.

## Test plan

1. <How to verify — `swift test`, type-check command, and/or the device steps if runtime-only.>
2. <Sanity check by eye / by replaying feedback, where relevant.>
