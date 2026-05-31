# Prompt: Feedback-replay tuner + efficacy-harness fusion/tolerance sweep (P6)

**File**: pdd/prompts/features/06-feedback-replay-tuner.md
**Created**: 2026-05-30
**Project type**: R&D tool — offline analysis in `experiments/`.
**Chain**: `pdd/prompts/features/PLAN-ios-to-shippable.md` → P6
**Source**: [Snappet#60](https://github.com/harshal2802/Snappet/issues/60) §E; closes the
NEEDS-REAL-DATA loop in `experiments/hr-highlight-efficacy/RESULTS.md`.
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## Goal

Two things that turn the app's captured data into algorithm improvements:

1. **A feedback-replay tuner** (`experiments/feedback-replay/`) that reads the on-device
   `highlight-feedback.jsonl` the app writes (`FeedbackStore` → `HighlightFeedbackEvent`), reconstructs
   per-highlight outcomes, and scores each `(selectorName, configFingerprint)` so we can see *which
   config the user actually preferred* — and estimate `effort_mix` empirically. Ships with a seeded
   synthetic-feedback generator so it runs **now**, before any real data exists.

2. **Close the efficacy-harness gap** that `hr-highlight-efficacy/RESULTS.md` itself flagged as
   required before Phase 1: add an **HR+Scene fusion** selector and a **match-tolerance sweep** to the
   existing harness (it currently only has HR/Scene/Random at a fixed ±8 s tolerance, even though
   interpretation #3 says tolerance "materially changes the verdict").

## Context the implementer needs

- The JSONL schema = `HighlightFeedbackEvent` (see `HighlightEngine/.../Feedback.swift`): fields
  `workoutId, activity, action, atOffset?, score?, highlightKind?, selectorName, configFingerprint,
  timestamp`. Swift's `JSONEncoder` **omits nil optionals**, so the reader must tolerate missing keys.
  `action` ∈ shown/kept/removed/added/reordered/pinned/regenerated/exported.
- The efficacy harness lives in `experiments/hr-highlight-efficacy/` (`synth.py`, `selectors.py`,
  `metrics.py`, `run.py`). Keep its existing output stable; *add* fusion + a tolerance sweep.

## Approach

**Replay tuner** (`experiments/feedback-replay/`):
- `loader.py` — parse JSONL (tolerant of missing keys) → events grouped by workout.
- `replay.py` — per `(selectorName, configFingerprint)`: pin-rate, keep-rate, removal-rate, export
  survivorship, regenerate-rate → a single **satisfaction score**; estimate `effort_mix` = share of
  pinned/exported highlights with `highlightKind == high`. Rank configs; emit a recommended direction.
- `synth_feedback.py` — seeded generator emitting realistic JSONL for ≥2 fingerprints so the tool runs
  with no real data; clearly labelled synthetic.
- `run.py` — runs on a real file if given (`python3 run.py path/to/highlight-feedback.jsonl`), else on
  freshly generated synthetic data. Markdown report. `README.md` documenting the tuning loop.

**Efficacy harness** (`experiments/hr-highlight-efficacy/`):
- Add a `fusion_selector` (weighted HR+Scene, mirroring the Swift `FusionSelector.hrLeaning`) to
  `selectors.py`.
- Add a tolerance sweep (e.g. 5/8/12/15 s) to `run.py` output, since the spike flagged tolerance as
  decisive. Keep the original table; append the fusion column + the sweep.

## Output

- `experiments/feedback-replay/{loader,replay,synth_feedback,run}.py` + `README.md`.
- Updated `experiments/hr-highlight-efficacy/selectors.py` (+ fusion) and `run.py` (+ fusion col +
  tolerance sweep). Update its `RESULTS.md` "Required real-data re-run" note to say fusion + sweep now exist.

## Acceptance criteria

- [ ] `python3 experiments/feedback-replay/run.py` runs on synthetic data and prints per-config scores
      + an `effort_mix` estimate + a recommendation. Reproducible (seeded).
- [ ] The loader tolerates JSONL lines with missing optional keys (as Swift emits).
- [ ] Running on a real `highlight-feedback.jsonl` path works (document the format).
- [ ] `experiments/hr-highlight-efficacy/run.py` now reports a Fusion row and a tolerance sweep, still
      seeded/reproducible; existing HR/Scene/Random numbers unchanged.
- [ ] Honest: synthetic feedback proves the *tooling*, not the product; says so.

## Constraints

- Pure stdlib Python, seeded. No app code changes. The deliverable is analysis tooling + a decision path.
