# Prompt: Phase-0b SPIKE — media ↔ HR time-sync accuracy

**File**: pdd/prompts/features/05-spike-media-hr-timesync.md
**Created**: 2026-05-30
**Project type**: R&D spike — throwaway measurement code in `experiments/`.
**Chain**: `pdd/prompts/features/PLAN-ios-to-shippable.md` → P5 (ports the web repo's `42-native-00b`).
**Source**: GitHub issue [#60](https://github.com/harshal2802/Snappet/issues/60) §3, Open Question 3.
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## ⚠️ This is a SPIKE, not a feature

The deliverable is a **measured number + a recommended alignment strategy**, not product. The app
currently matches media to a workout by `creationDate` within the workout window ± **90 s**
(`PhotoLibraryService`). That 90 s is an **unvalidated guess** (see decisions.md). This spike pressure-
tests it and recommends a real padding/strategy.

## The question to answer

When media is matched to the HR series purely by timestamps, how accurate is the alignment, and what
strategy minimizes the error?
1. **Clock drift** between the HR-source (watch) and the camera over a session.
2. Does **clip-internal mapping** work (offset *within* a long clip via creation_time + offset)?
3. **Timezone / metadata pitfalls** (QuickTime UTC vs EXIF local-no-TZ vs Android DATE_TAKEN) that can
   throw alignment off by hours.

## Approach (no device available here → modeled, with a real-data re-run plan)

A seeded, stdlib-only Python harness that models the error budget and compares alignment strategies
against a stopwatch ground-truth:
- A true wall-clock timeline; the watch HR is authoritative (on true time). The camera reports
  `capturedAt = t_true + skew + drift_rate·elapsed + tz_error`.
- Strategies: **naive** (trust creation_time), **tz-resolved** (snap gross integer-hour TZ errors),
  **session-sync** (one start-of-session reference marker removes skew; residual = drift only).
- Test clip-internal mapping by mapping frames at increasing in-clip offsets and measuring drift growth.
- Sweep realistic drift magnitudes; report error distribution (median / p95 / max) per strategy.

## Output

- `experiments/media-hr-timesync/` — `synth.py` (error model), `strategies.py` (the 3 aligners),
  `run.py` (sweep + markdown report), `README.md`, `RESULTS.md`.
- `RESULTS.md`: error distribution per strategy, drift over a session, the TZ pitfalls modeled, a
  **recommended alignment strategy + justified padding window**, whether ~1 s accuracy is achievable,
  and an explicit **real-data re-run plan** (this is modeled, not measured on a device).

## Acceptance criteria

- [ ] All three strategies run end-to-end on the same seeded input; `python3 run.py` is reproducible.
- [ ] Error vs stopwatch ground-truth is quantified (median / p95 / max seconds), not asserted.
- [ ] Clip-internal mapping (offset within a long clip) is tested, not just whole-clip matching.
- [ ] A gross timezone error case is included and shown to be (un)recoverable per strategy.
- [ ] `RESULTS.md` gives a concrete recommended strategy + a padding number that ties back to
      `PhotoLibraryService` (validate or revise the 90 s).
- [ ] Honesty: states this is modeled and gives the device re-run plan; verdict is NEEDS-REAL-DATA-grade.

## Constraints

- No app code, no device APIs. Pure stdlib Python, seeded. The deliverable is a decision + a number.
