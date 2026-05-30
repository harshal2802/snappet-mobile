# Experiments (Phase-0 spikes)

Throwaway measurement code whose deliverable is a **decision**, not product. Driven by the spike
prompts in the web repo (`pdd/prompts/features/native-mobile/`):

- `hr-highlight-efficacy/` — **make-or-break.** Does a user's own HR pick the highlights they prefer,
  vs scene-detection and random? (prompt `41-native-00a`) → `RESULTS.md` with a GO / NO-GO /
  NEEDS-REAL-DATA verdict.
- `media-hr-timesync/` — how accurately can media be aligned to the HR curve by timestamps alone?
  (prompt `42-native-00b`) → `RESULTS.md` with a recommended alignment strategy + padding window.

Each spike is self-contained and disposable. Do not build app UI or integrations here.
