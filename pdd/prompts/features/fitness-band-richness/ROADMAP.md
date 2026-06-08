# Roadmap: Feature-rich fitness-band data (multi-phase)

**Created**: 2026-06-08
**Origin**: multi-agent exploration of "can we get fitness-band tracking data more feature rich?"
**Phase 1 prompt**: `pdd/prompts/features/24-ios-hr-contact-redline-climb-effort.md` (shipped, PR #56)
**Context**: `pdd/context/{project,conventions,decisions}.md`

The big insight: the BLE band already sends richer data every `0x2A37` packet than we use, and a
large class of derived metrics is pure math over the bpm series we already buffer — all on-device,
no cloud, no vendor SDK (honoring the 2026-06-01 generic-BLE-only decision).

---

## ⚖️ Parity invariant (applies to EVERY phase — this is the standing rule)

Every fitness-band enhancement must, unless explicitly justified otherwise in that phase, land:

1. **In both apps.** WorkoutTracker (unit = a logged **set**) **and** Kilter (unit = a logged
   **climb**). A feature that only makes sense in one (e.g. Kilter "sends") gets its WorkoutTracker
   analogue (e.g. peak-effort sets), not silence.
2. **Across all exercise types.** In WorkoutTracker that means every `SetKind` a Quick/freeform
   session logs — `.repsWeight`, `.duration`, `.climbAttempt` — and legacy routine sets. In Kilter,
   all ascent types. Never a kind that silently renders nothing.
3. **On every relevant HR surface, in both contexts:** the live HR pill (`LiveHRPill` /
   `KilterHRPill`), the session summary (`SessionDetailView` / `KilterSessionDetailView`), the Live
   Activity (`LiveActivityController`+`WorkoutLiveActivity` / `KilterLiveActivityController`+
   `KilterLiveActivity`), the **watchOS** face (`SnappetWatch`), and the **widget** (`SnappetWidgets`).
   Use the Shared/ wire types + `HeartRateZone` so phone, watch and widget render identically.
4. **As shared logic, not per-app duplication.** Pure math in `HighlightEngine` (platform-free);
   one shared SwiftUI component for shared visuals (the Phase-1 precedent: `ClimbEffort` engine
   helper + `HREffortBadge` view, reused by both the Kilter per-climb timeline and the WorkoutTracker
   per-set tiles).
5. **With honest, symmetric gating.** Degrade cleanly + identically when data is absent: HR-less /
   simulator sessions, no user profile (bpm-only), a non-RR band, or the Apple-Watch path. Both apps
   must hide the same way.

**Known structural parity gap to close first (Phase 2):** `KilterSession` has `maxHR` / `restHR` /
`metricsSourceRaw`; `WorkoutSession` has only `hrSeries`. Until `WorkoutSession` gains the same
fields, any profile/%HRR/source-label work personalizes Kilter but not WorkoutTracker.

**Parity checklist (paste into each phase's PR):**
- [ ] Lands in WorkoutTracker **and** Kilter (or the analogue is built + named).
- [ ] Works for every `SetKind` / ascent type; verified by a test per kind.
- [ ] Reaches the live pill, summary, Live Activity, watch, and widget where applicable.
- [ ] Pure logic in the engine; shared view for shared visuals (no duplication).
- [ ] Symmetric absent-data gating in both apps; tests for the gated paths.

---

## Phase 1 — bpm-only quick wins ✅ SHIPPED (PR #56)

Sensor-contact gating, redline/strain tiles, per-effort scoring. **Parity already applied:**
contact gating + redline/strain in both apps; per-effort is per-climb (Kilter) and per-set
(WorkoutTracker, all `SetKind`s) via the shared `ClimbEffort` + `HREffortBadge`. Still device-only:
the live "adjust strap" + live per-effort HR.

## Phase 2 — on-device user HR profile (the keystone)

A small app-agnostic `UserHRProfile` (age/resting/max/weight/sex; manual + HealthKit prefill)
replaces the fixed `maxHR = 190`, lighting up personalized zones, real `%HRR`, and HR-based calories.

**Parity requirements:**
- The profile store lives once on `AppModel` (already shared by both apps).
- **Close the gap:** add `maxHR` / `restHR` / `metricsSourceRaw` to `WorkoutSession` (mirror
  `KilterSession`) and feed both on session end, so per-set **and** per-climb `%HRR`/effort/redline
  personalize. Per-set `peakHRR` is already plumbed (`setEfforts`) and just lights up.
- HR-based **calorie estimation** (Keytel) over the bpm series applies to **both** apps' BLE
  sessions (BLE only — never overrides the watch's measured energy).
- The profile `maxHR` must travel to the **watch + widget** as a wire field in **both**
  `WorkoutActivityAttributes` and `KilterActivityAttributes` (those processes can't read the store),
  so zone colors are personalized off-device in both contexts.
- Gating: no profile → today's bpm-only behavior, identically in both apps.

## Phase 3 — RR-intervals → on-device HRV (device-gated)

Parse the RR-interval array we discard and compute RMSSD/SDNN/pNN50 purely in the engine.

**Parity requirements:**
- Capture is at the **shared** `BLEHeartRateMetricsSource` → both apps get RR for free; thread an
  optional `rrIntervalsMs` through `HRSample`/`HRPoint` (additive/Optional, no migration).
- The HRV deriver is a **pure engine** helper (sibling to `ClimbEffort`); a **shared** HRV badge
  view (sibling to `HREffortBadge`).
- Surface per-rest HRV in **both**: between-climbs (Kilter) **and** between-sets (WorkoutTracker, all
  `SetKind`s) — the rest windows already exist on both sides.
- Honest gating (both apps): RR is trustworthy only from chest straps; optical bands / the Apple
  Watch path emit no genuine RR → degrade to the bpm-only effort/recovery already shipped. Use a
  Device-Info (`0x180A`) model gate to decide trust.

## Phase 4 — bigger bets (build on 2 & 3)

- **Live "recovery ready" nudge.** Both the **Kilter** HUD/Live Activity **and** the
  **WorkoutTracker** live player overlay/Live Activity — "rested enough for the next burn" = next
  climb (Kilter) / next set (WorkoutTracker). Shared readiness logic (live bpm vs profile rest
  baseline, sharper with RR-HRV rebound); reuse each side's throttled Live-Activity push + reach the
  watch + widget.
- **Effort-aligned highlight selector.** One engine selector taking an injected per-offset boost
  closure (the existing `SceneHighlightSelector.visualScore` pattern): Kilter boosts moments inside
  **sent**-climb windows; WorkoutTracker boosts **peak-effort set** windows. Both auto-reels feature
  the achievement, not raw HR peaks. Tune weights from replayed `HighlightFeedbackEvent`, never
  intuition.

## Explicitly out (all phases)

Vendor SDKs / cloud (Whoop strain, Garmin Body Battery, Oura readiness, Polar PMD raw accel) —
brand lock-in + cloud, against the generic-BLE-only / on-device stance. On-device RMSSD/SDNN from
standard RR is the constraint-compatible substitute.
