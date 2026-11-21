# Prompt: CI — UI tests by area on PRs, the full suite nightly

**File**: pdd/prompts/features/268-ci-ui-suite-smoke-targeted-nightly.md
**Created**: 2026-11-18
**Project type**: Tooling (GitHub Actions + a Python stdlib script) — no app or test source changes.
**Chain**: prompt 261 (the UI suite in eight legs) → prompt 267 (UI tests that hold on the runner), PR #457.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The full UI suite is 94 classes / 294 tests, about 8 hours of machine time in eight legs. With the few macOS runners
GitHub gives the repo, a PR waits about two hours for it. User decision (2026-11-18): the full suite does not run on
every PR. A PR runs unit + engine, a small UI smoke set when it touches `ios/**`, and the UI classes of the areas it
touches; the full suite runs nightly on main, on manual dispatch, when the CI recipe changes, or on request (label).

## Context the implementer needs

- `.github/workflows/ci.yml`: a Linux `changes` job emits the `app` job's matrix; the `app` job builds and runs one
  leg per row (`-only-testing:`), `fromJSON(… || '[full]')` fallback, fail-open everywhere (decisions 2026-06-17).
- `scripts/ci-ui-shard.py` (prompt 261): finds the UI test classes in the sources, splits them by test count;
  `--check` (every class in one leg, no async hooks, prompt 267) runs in every UI leg.
- About 45 s per UI test on the runner (30–150 s), ~8 min of build per leg. Main has no required checks.

## Approach

1. **Area map** in `scripts/ci-ui-shard.py` (`AREAS`): each area has app path patterns (fnmatch), optional
   exclusions, and UI test class patterns. Areas follow `ios/App/Snappet/Features/*`; WorkoutTracker splits cleanly
   into `racket` (`Racket*` files) and `workout` (the rest). Services / Shared files with an area prefix
   (`Racket*`, `Kilter*`, `Pomodoro*`, `Household*`, `Wardrobe*`, `Workout*`) join their area. A class may be in
   several areas (e.g. `HeartRateOwnershipUITests` in workout and kilter).
2. **Selection** for a list of changed paths: recipe file (ci.yml, the script) → full; a UI test file → its
   classes plus every class that uses what it declares (helpers: grep for the helper's type / free-function /
   extension-member names; an extension function with required labels must be called with them, so
   `tap(_:until:)` is not every `.tap()`; helpers used by helpers followed); a helper with no user found → full; an
   app file in an area → the area's classes; other `ios/**` → smoke only; unit tests / docs under ios → nothing;
   nothing under ios → no UI. Smoke is added whenever UI runs. Legs: ceil(tests / 35) with the balanced split;
   8 or more → the full suite.
3. **Smoke set**: `SuiteSmokeTests`, `TestStoreGuardUITests`, `WorkoutDashboardUITests`, `FeedViewUITests` (6 tests).
4. **Matrix rows** carry their class list for smoke / targeted / picked legs (`{"suite", "classes"}`); full legs
   (`SnappetUITests-KofN`) recompute from the same sources as before. The leg validates the list (`--only`).
5. **Events**: PR → the merge commit vs its first parent; push to main → `before..after`, recipe files don't force
   full, fail open to smoke; nightly `schedule` 08:37 UTC → full, skipped when the previous finished nightly ran the
   same commit; `workflow_dispatch` → full, or exactly the `ui_classes` input (unknown name fails the job; not
   fail-open). PR labels: `full-ui` → full, `ui-quick` → smoke only whatever changed, both → full-ui; `labeled` is a
   trigger type so adding either starts a run, other labels give a no-op run in its own concurrency group.
6. **Concurrency**: PR runs share `ci-pr-<ref>` and cancel stale runs; every other run has its own group, so a
   nightly or a merge's run is never cancelled or replaced while pending.
7. `--check` also fails when a class is in no area and not in smoke, an area pattern matches no class or file, or
   the ci.yml fallback is not the full matrix. `scripts/test_ci_ui_shard.py` (unittest) runs in a Linux job.

## Output

`scripts/ci-ui-shard.py`, `scripts/test_ci_ui_shard.py`, `.github/workflows/ci.yml`, a decisions.md entry,
conventions.md (Testing).

## Acceptance criteria

- [ ] `python3 scripts/ci-ui-shard.py --check 8` passes (94 classes, 294 tests); the unit tests pass.
- [ ] `--select` on PR #457's diff gives the full suite (ci.yml changed); with `ui-quick`, smoke only.
- [ ] A docs-only PR requests no UI runner; a Core-only PR runs one smoke leg.
- [ ] The workflow parses; each event's matrix is walked through in the PR description.
- [ ] `decisions.md` updated.

## Constraints

- No app or test source changes. No knowledge-graph change (no user-facing change).
- Fail open except for a manual `ui_classes` typo.
- The workflow cannot run locally: event handling is verified by reading and by the first real runs.

## Test plan

1. `python3 -m unittest discover -s scripts -p 'test_ci_ui_shard.py' -v`; `--check 8`; `--select` on real diffs.
2. Parse the YAML; walk each event type by hand.
3. After merge: one PR of each kind, the first nightly, a dispatch with `ui_classes`.
