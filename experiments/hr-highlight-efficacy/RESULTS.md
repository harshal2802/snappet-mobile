# HR-highlight efficacy — RESULTS

**Spike:** Phase 0a (the make-or-break test) · prompt `41-native-00a` in
[harshal2802/Snappet](https://github.com/harshal2802/Snappet) · refs
[Snappet#60](https://github.com/harshal2802/Snappet/issues/60) §E.
**Date:** 2026-05-30
**Data:** synthetic (no real workout footage available yet).

## Verdict: 🟡 NEEDS-REAL-DATA

The harness, metrics, and HR algorithm work end-to-end, and **HR beats the random floor in every
scenario** — but in this synthetic model a **scene-detection baseline beats HR everywhere**, and that
outcome is an artifact of modeling assumptions we can only replace with real data. So this is **not a
GO** and also **not a NO-GO** — it is "the approach is plausible, the harness is ready, now run the
small real-data study before committing to Phase 1."

## What was tested

Three selectors ranked the top-8 highlight moments per session, scored against synthetic "user manual
picks" (precision/recall/F1 @8, ±8 s match tolerance), 40 seeded sessions/scenario:

- **HR** — the candidate (#60 §4): smoothed HR → %heart-rate-reserve → peak + rate-of-change scoring,
  with look-ahead compensating for HR lagging the moment.
- **Scene** — a content/visual-saliency baseline (the non-biometric competitor).
- **Random** — the floor.

`effort_mix` = the fraction of memorable moments that are effort-driven (HR-capturable) vs
scenic/social (not HR-capturable).

## Results (actual, reproducible — `python3 run.py 40`)

| scenario | HR F1 | Scene F1 | Random F1 | Spearman: HR / Scene vs engagement |
|---|---|---|---|---|
| running, effort_mix=0.3 | 0.22 | **0.49** | 0.09 | 0.37 / 0.26 |
| running, effort_mix=0.5 | 0.21 | **0.45** | 0.08 | 0.38 / 0.25 |
| running, effort_mix=0.7 | 0.24 | **0.33** | 0.11 | 0.40 / 0.24 |
| climbing, effort_mix=0.5 | 0.36 | **0.53** | 0.06 | 0.48 / 0.36 |

## Interpretation (read carefully — the headline is nuanced)

1. **HR clears the floor everywhere** (F1 0.21–0.36 vs random ~0.08). The smoothing + %HRR +
   derivative + lag-compensation pipeline genuinely locates effort moments. Mechanics: ✅.

2. **Scene-detection wins F1 in every scenario here — but that is by construction.** In `synth.py`
   the visual saliency signal is `0.7·scenic + 0.25·motion + noise`, i.e. the scene baseline sees
   *both* scenic events *and* motion (a proxy for effort), while HR sees only effort. We deliberately
   did **not** hand the advantage to HR — and it shows. The Scene win reflects that modeling choice,
   not a real-world fact.

3. **Tell-tale tension: HR has HIGHER rank-correlation with true engagement (Spearman 0.37–0.48) than
   Scene (0.24–0.36), yet LOWER F1.** Why: effort moments are *broad* humps, so HR's top picks often
   land within the right region but miss the exact ground-truth instant by >8 s; scenic events are
   *sharp*, so Scene's picks pin inside the ±8 s window. → On real data, **the tolerance window and
   clip-padding (#60 §3) materially change the verdict.** This is itself a finding: tune tolerance and
   pad HR clips generously.

4. **Net:** the HR-vs-content comparison is dominated by two things we *assumed* rather than measured —
   how much memorable content is effort-driven (`effort_mix`) and how much a content detector also
   captures effort (the motion term). **Only real users can settle both.**

### Honesty caveat

This experiment **cannot prove or disprove the product premise.** The HR↔engagement relationship and
the Scene↔effort overlap were *invented* by `synth.py`. The result above is best read as: "HR is a
real signal (beats random and tracks engagement), the harness is trustworthy and not rigged for HR
(Scene actually wins as modeled), and the decision now genuinely depends on real data."

> ⚠️ *Process note:* an earlier draft of this file reported different, more HR-favorable numbers due
> to a mis-transcription during a tooling glitch. Those were wrong. The numbers above are the actual,
> reproducible output of `run.py` (seeded) and supersede any earlier figures.

## Required real-data re-run (before any Phase-1 commitment)

Run the *same* harness (swap `synth.generate_session` for a real-data loader) on **≥8–10 real sessions
across climbing, running, and dance**:

1. **Capture:** continuous HR (Apple Watch / HealthKit export) + the videos/photos shot during it.
2. **Ground truth:** the participant (and ideally 1–2 others) pick the moments they'd actually put in
   a reel — *blind to the HR curve*.
3. **Run** HR vs Scene vs Random vs **HR+Scene fusion** against those human picks (same metrics; also
   sweep the match tolerance 5–15 s and HR clip-padding).
4. **Decision rule:**
   - HR ≥ Scene **and** HR F1 ≳ 0.4 → **GO**, HR-led.
   - HR ≈ Scene, or fusion ≫ either → **GO as a fusion** (HR + scene-detection), not HR alone.
   - HR ≈ Random or ≪ Scene even after padding/fusion → **NO-GO** for HR-as-edit-engine; fall back to
     scene-detection + manual, and reposition HR as an *overlay/stat* feature (still valuable, cf.
     Motion Studio in #60 §8).
5. **Measure `effort_mix` empirically** (share of human picks coinciding with HR peaks) → sets the
   HR-vs-content weighting in the real selector.

**Given this spike, the likely real-world answer is a fusion, not HR-alone** — so Phase 1 should keep
the selector pluggable (HR score + content score + manual pins), not hardwire HR.

## Reproduce

```bash
cd experiments/hr-highlight-efficacy
python3 run.py 40        # pure stdlib, no install; seeded → identical numbers
```

Files: `synth.py` (data model), `selectors.py` (HR / Scene / Random), `metrics.py`
(precision/recall/F1 + Spearman), `run.py` (sweep + report).
