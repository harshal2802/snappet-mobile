# Prompt: CI — split the UI suite into parallel legs

**File**: pdd/prompts/features/261-ci-ui-suite-shards.md
**Created**: 2026-11-16
**Project type**: Tooling (GitHub Actions) — no app code changes.
**Chain**: none (CI repair)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make the UI test job on CI finish. The single `App tests (SnappetUITests)` leg is cancelled at its 90-minute
ceiling on every run, on main and on PRs, since at least 2026-11-05. It reads as a red check, but no test fails:
on PR #439 106 tests ran and passed before the cut. Classes run alphabetically, so everything after "N" (all 104
racket UI tests among them) has never run on CI.

## Context the implementer needs

- `.github/workflows/ci.yml`: the `changes` job emits the `app` matrix (`suites`), the `app` job runs
  `xcodebuild test -only-testing:<suite>` with `-retry-tests-on-failure -test-iterations 3`.
- Measured on the runner: about 45 s per UI test. 272 UI tests in 89 classes ≈ 200 min serial.
- Main has no required status checks, so renaming the UI check does not block merges.

## Approach

- `scripts/ci-ui-shard.py <index> <count>`: reads `ios/App/SnappetUITests/**/*.swift`, finds each
  `class X: XCTestCase` with tests, weights it by its number of tests, places heaviest first on the lightest
  shard (deterministic), prints one `-only-testing:SnappetUITests/<Class>` per line. `--plan` prints the split,
  `--check` fails unless every class is in exactly one shard.
- `changes` job: `UI_SHARDS: 6`; the matrix becomes `SnappetTests` plus `SnappetUITests-1of6 … 6of6`.
- `app` job: a `SnappetUITests-KofN` leg runs `--check`, then passes the script's lines to `xcodebuild test`.
  The unit leg is unchanged. Each leg still builds the app itself.

## Output

`scripts/ci-ui-shard.py`, the edited `ci.yml`, a decisions.md entry.

## Acceptance criteria

- [ ] `scripts/ci-ui-shard.py --check 6` passes; the six shards hold 45–46 tests each.
- [ ] On the PR's CI run every UI leg starts, runs only its classes and ends on its own (pass or real failures),
      not by the 90-minute cancel.
- [ ] A PR that touches no `ios/**` still requests no UI runner.
- [ ] `decisions.md` updated.

## Constraints

- No app or test source changes in this PR. Tests that fail once they finally run on CI are reported, not fixed here.
- Six concurrent macOS runners per run that touches `ios/**`: more runner minutes in total (six builds), shorter wall time.

## Test plan

1. `python3 scripts/ci-ui-shard.py --check 6` and `--plan 6` locally.
2. Dry-run the leg's shell step locally for one shard.
3. Open the PR (it changes `ci.yml`, so the UI legs run) and read each leg's result and duration.
