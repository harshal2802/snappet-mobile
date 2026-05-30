# Spike: HR-highlight efficacy (Phase 0a — make-or-break)

**Question:** does a user's *own* heart-rate time-series pick the workout highlights *they* prefer —
better than scene-detection, and well above random?

Driven by prompt `41-native-00a-spike-hr-highlight-efficacy.md` in the
[Snappet web repo](https://github.com/harshal2802/Snappet) · refs
[Snappet#60](https://github.com/harshal2802/Snappet/issues/60) §E.

⚠️ **This is a throwaway spike. The deliverable is a decision, not product.** No app code, no
HealthKit — just measurement.

## Run

```bash
python3 run.py 40     # pure Python stdlib, no dependencies; seeded & reproducible
```

## Files

| file | purpose |
|---|---|
| `synth.py` | synthetic session generator (HR series, latent engagement, ground-truth picks, visual saliency) |
| `selectors.py` | the three selectors: **HR** (candidate, #60 §4), **Scene** (baseline), **Random** (floor) |
| `metrics.py` | precision/recall/F1 @N with tolerance matching + Spearman (stdlib only) |
| `run.py` | runs the sweep over `effort_mix`, prints the report |
| `RESULTS.md` | **the output that matters** — numbers, interpretation, verdict, and the real-data re-run plan |

## Bottom line

🟡 **NEEDS-REAL-DATA.** The algorithm beats the random floor everywhere and the harness is sound, but
HR-vs-scene-detection flips on one unknown (`effort_mix`) that only real users can settle. See
`RESULTS.md` for the decision rule and the ≥8–10-session real-data study to run before Phase 1.
