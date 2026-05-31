# media ↔ HR time-sync (Phase-0b spike)

**Question:** when we match media to a workout purely by timestamps, how accurate is the alignment,
and what strategy minimizes the error? Refs [Snappet#60](https://github.com/harshal2802/Snappet/issues/60)
§3, Open Question 3. Prompt: `pdd/prompts/features/05-spike-media-hr-timesync.md`.

This validates (or revises) the **±90 s** padding `PhotoLibraryService` uses to match `PHAsset`s to a
workout window, and the clip-internal mapping the reel relies on.

> ⚠️ **Modeled, not measured.** No device is available in this environment, so this is an
> **error-budget model**, not field data. The parameters in `synth.py` (skew/drift/TZ ranges) are
> conservative guesses — `RESULTS.md` states the re-run plan that replaces them with real numbers.

## Run

```bash
cd experiments/media-hr-timesync
python3 run.py 200        # pure stdlib, seeded → identical numbers
```

## Files

- `synth.py` — the error model: `capturedAt = t_true + skew + drift·elapsed + tz_error`, plus seeded
  session/marker generation.
- `strategies.py` — three aligners: `naive`, `tz_resolved` (snap gross hour offsets), `session_sync`
  (one start reference removes skew). Includes clip-internal mapping (offset within a long clip).
- `run.py` — sweeps sessions, reports median/p95/max error per strategy.
- `RESULTS.md` — the distribution, the recommended strategy + padding, and the device re-run plan.
