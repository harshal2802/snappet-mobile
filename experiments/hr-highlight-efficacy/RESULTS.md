# HR-highlight efficacy — RESULTS

**Spike:** Phase 0a (the make-or-break test) · prompt `41-native-00a` in
[harshal2802/Snappet](https://github.com/harshal2802/Snappet) · refs
[Snappet#60](https://github.com/harshal2802/Snappet/issues/60) §E.
**Date:** 2026-05-30
**Data:** synthetic (no real workout footage available yet).

## Verdict: 🟡 NEEDS-REAL-DATA (with a conditional GO)

The harness works end-to-end and the HR algorithm is mechanically sound — but **whether HR-driven
selection actually wins is decided by a parameter we cannot measure without real users.** Do **not**
treat this as a GO to build the full pipeline. Treat it as: *the approach is plausible and worth a
small real-data study; here is exactly what to measure.*

## What was tested

Three selectors ranked the top-8 highlight moments per session; each was scored against synthetic
"user manual picks" (precision/recall/F1 @8, ±8 s match tolerance) over 40 seeded sessions/scenario:

- **HR** — the candidate (#60 §4): smoothed HR → %heart-rate-reserve → peak + rate-of-change scoring,
  with a look-ahead that compensates for HR lagging the moment.
- **Scene** — a content/visual-saliency baseline (the non-biometric competitor).
- **Random** — the floor.

The synthetic generator mixes two kinds of memorable moments via `effort_mix`: **effort-driven**
(HR-capturable) vs **scenic/social** (a view, a friend, a laugh — *not* HR-capturable).

## Results

| scenario | HR F1 | Scene F1 | Random F1 | HR vs Scene |
|---|---|---|---|---|
| running, effort_mix=0.3 | 0.22 | **0.42** | 0.08 | Scene ≫ HR |
| running, effort_mix=0.5 | **0.39** | 0.34 | 0.08 | HR ≫ Scene |
| running, effort_mix=0.7 | **0.55** | 0.22 | 0.08 | HR ≫ Scene |
| climbing, effort_mix=0.5 | **0.47** | 0.32 | 0.08 | HR ≫ Scene |

Spearman(selector score, latent engagement) tracks the same story (HR 0.36→0.66 as effort_mix rises;
Scene the inverse).

## Interpretation

1. **HR clears the floor everywhere** (0.22–0.55 vs random's 0.08). The smoothing + %HRR +
   derivative + lag-compensation pipeline does locate effort moments — the algorithm mechanics are correct.
2. **HR vs Scene flips entirely on `effort_mix`.** When most memorable moments are effort-driven
   (≥0.5), HR wins clearly; when scenery dominates (0.3), a content detector wins. They are
   **complementary signals**, which matches the #60 finding that scene-detectors catch visual saliency
   and HR catches exertion.
3. **Therefore the make-or-break question reduces to one empirical unknown:** *for our actual users
   filming actual climbs/runs/raves, what fraction of the moments they want in a reel are effort-driven?*
   The synthetic model cannot answer this — it was an assumption fed in, not a measurement.

### Honesty caveat (important)

This experiment **cannot prove the product premise.** The HR↔engagement relationship was *invented* by
`synth.py`; any scenario where HR "wins" only reflects an `effort_mix` we chose. The value here is:
(a) the harness, metrics, and algorithm are validated and reusable on real data; (b) we now know the
single variable that determines success and exactly how to measure it. A small synthetic dataset
"confirming" the premise would prove nothing, so we explicitly do **not** mark GO.

## Required real-data re-run (before any Phase-1 commitment)

Run the *same* harness (`run.py` swapping `synth.generate_session` for a real-data loader) on **≥8–10
real sessions across the 3 target activities** (climbing, running, dance):

1. **Capture** each session: continuous HR (Apple Watch export / HealthKit) + the videos/photos shot
   during it.
2. **Ground truth:** have the participant (and ideally 1–2 others) pick the moments they'd actually
   put in a highlight reel — *blind to the HR curve*.
3. **Run** HR vs Scene vs Random against those human picks (same precision/recall/F1@N, ±tolerance).
4. **Decision rule:**
   - HR F1 ≥ Scene F1 **and** HR F1 ≥ ~0.4 across activities → **GO** (HR-led, optionally fuse Scene).
   - HR ≈ Scene → **GO as a fusion** (HR + scene-detection combined), not HR alone.
   - HR ≈ Random or ≪ Scene → **NO-GO** for HR-as-edit-engine; fall back to scene-detection + manual.
5. **Also estimate `effort_mix` empirically** (what share of human picks coincide with HR peaks) — it
   tells us how much to weight HR vs content in the real selector.

## Reproduce

```bash
cd experiments/hr-highlight-efficacy
python3 run.py 40        # pure stdlib, no install; seeded → identical numbers
```

Files: `synth.py` (data model), `selectors.py` (HR / Scene / Random), `metrics.py`
(precision/recall/F1 + Spearman), `run.py` (sweep + report).
