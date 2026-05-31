# media ↔ HR time-sync — RESULTS

**Spike:** Phase 0b · prompt `05-spike-media-hr-timesync` · refs
[Snappet#60](https://github.com/harshal2802/Snappet/issues/60) §3, Open Question 3.
**Date:** 2026-05-30
**Data:** **modeled** (no device in this environment) — an error-budget estimate, seeded/reproducible.

## Verdict: 🟡 NEEDS-REAL-DATA — but the ±90 s window pad is a sound provisional value; the real fix is TZ normalization + generous clip padding

The model can't *prove* field accuracy, but it cleanly separates the error sources and shows which
strategy each one needs. The actionable conclusions hold regardless of the exact parameter values.

## Results (`python3 run.py 200`, error in seconds vs a stopwatch ground truth)

**With gross timezone errors present (realistic worst case):**

| strategy | median | p95 | max |
|---|---|---|---|
| naive | 3560.81 | 28798.85 | 28838.1 |
| tz_resolved | 24.01 | 1774.96 | 1797.7 |
| session_sync | 0.03 | 0.12 | 0.2 |

**With timezone already correct (drift + skew only):**

| strategy | median | p95 | max |
|---|---|---|---|
| naive | 22.72 | 42.57 | 45.0 |
| tz_resolved | 22.72 | 42.57 | 45.0 |
| session_sync | 0.03 | 0.12 | 0.2 |

## Interpretation (the three error sources are independent and need different fixes)

1. **Timezone mislabels are catastrophic, not subtle (hours).** A QuickTime UTC time read as local,
   or an EXIF time with no TZ, throws alignment off by **whole hours** (p95 ≈ 8 h in the model).
   **But for *this app* that doesn't corrupt the reel — it changes which media gets matched.**
   `PhotoLibraryService` fetches assets whose `creationDate` ∈ `[workoutStart−90s, workoutEnd+90s]`.
   A clip an hour off simply **falls outside the window and is silently dropped** (false negative) —
   or a clip from another session falls inside (false positive). So the TZ risk is **missing/extra
   media**, not misplaced highlights.

2. **Hour-snapping doesn't save half-hour zones.** `tz_resolved` removes integer-hour errors but
   leaves **~30 min** for +5:30 (India), +9:30, etc. (p95 ≈ 1775 s ≈ 29.6 min in the model). Snapping
   to the hour is the *wrong* fix — TZ must be resolved from real metadata, not guessed.

3. **Skew + drift are the only sources that matter once TZ is correct, and they're small.** With the
   timezone right, naive p95 ≈ **43 s**, max **45 s** — dominated by constant clock skew; crystal
   drift over an hour is sub-second. **The current ±90 s window pad covers this p95 with ~2× margin.**

4. **~1 s precision needs a session-sync reference.** `session_sync` (film the watch / clap once at
   the start to measure skew) collapses residual error to **drift only, p95 ≈ 0.1 s**. v1 has no such
   reference, so do **not** assume second-accurate clip placement — pad clip windows.

## Recommended alignment strategy for Phase 1

1. **Keep the ~90 s window-matching pad** (`PhotoLibraryService`). The model says skew+drift p95 ≈ 43 s,
   so 90 s is a safe ~2× margin for *inclusion*. ✅ the guess is reasonable — no change needed here yet.
2. **Resolve timezone at the metadata edge — don't guess.** For video, trust QuickTime/AVAsset
   `creationDate` (UTC-backed on iOS) over EXIF. For photos with no TZ, resolve against the asset's
   location/`PHAsset` TZ. This prevents the hour-scale **missing-media** failures (incl. the +5:30 case
   hour-snapping can't fix). This is the highest-value change.
3. **Do not trust second-level clip placement in v1.** Lean on the engine's existing generous clip
   padding (`clipLeadSec`/`clipTrailSec` + `hrLagSec` bias) rather than precise alignment. The reel
   tolerates a few seconds of slop by design.
4. **Optional later: a session-sync affordance** ("point the camera at your watch to start") buys ~1 s
   alignment for power users / overlays. Defer past v1.

## Required real-data re-run (before trusting any number above)

On a real iPhone + Apple Watch, ≥3 sessions:
1. Record a session video containing a **visible synced stopwatch** (or clap markers at known HR-series times).
2. Read `PHAsset.creationDate`, AVAsset/QuickTime `creation_time`, and EXIF `DateTimeOriginal`; **note
   where they disagree** (they will).
3. For several known frames, compute predicted-vs-true error; tabulate median/p95/max. Compare two
   far-apart markers to estimate real drift.
4. Repeat with a clip whose capture TZ ≠ device TZ (travel case) to confirm the resolution in step 2.
5. Confirm p95 < the chosen window pad; if not, widen it. Decide whether session-sync is worth shipping.

## Reproduce

```bash
cd experiments/media-hr-timesync
python3 run.py 200
```

Files: `synth.py` (error model), `strategies.py` (naive / tz_resolved / session_sync), `run.py` (sweep + report).
