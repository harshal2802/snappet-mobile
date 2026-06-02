# Research: Smart-ring ("auto ring") data → WorkoutTracker live + post-hoc HR

**Created**: 2026-06-02
**Type**: PDD Research (feasibility + approach selection) — a decision record, not an implementation.
**Status**: complete — verdicts below; every claim that needs hardware is flagged **device-pending**
(HealthKit / CoreBluetooth are device-only, exactly as the prior wearable research notes).
**Source**: user request, 2026-06-02 — *"integrate auto ring data into this app for workout tracking."*
Target narrowed to the **Oura Ring** (user, 2026-06-02) — see the specific verdict in §3a.
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`;
`pdd/prompts/features/live-workout-studio/RESEARCH.md` §3.2–3.3 (the Apple-Watch + BLE-band decision this
extends), `A3-metrics-source-abstraction-ble.md` (the `MetricsSource` protocol).

---

## 1. The ask, restated (+ a scoping note)

> *Integrate "auto ring" data into Snappet for workout tracking.*

"Auto ring" is read here as a **smart ring** — a finger-worn wearable that tracks heart rate (and
sleep / SpO₂ / temperature): **Oura (Gen 3/4), Ultrahuman Ring AIR, Samsung Galaxy Ring, RingConn,
Circular**, and similar. The analysis is brand-agnostic; what matters is *how a given ring exposes its
HR to a third-party iOS app*, which sorts every ring into one of three access tiers (§3). If "auto ring"
means a specific product or a non-HR signal, the tier mapping still applies — only the per-brand
verdict in §3 changes.

The integration goal that matters for this app: get a ring's **heart-rate series** into a
`WorkoutTracker` session so the existing surfaces light up —
- **live** during the workout: the A4 HR overlay, the A2/A2 timers, the Live Activity, the watch face;
- **post-hoc** after it: the B2 summary (HR chart + time-in-zone) and the B4 engine-driven highlight reel.

## 2. What we already have to build on (codebase audit)

The live-workout-studio initiative already shipped the exact seam a new HR wearable plugs into — this is
**reuse + relabel + one narrow new path**, not new architecture.

| Asset | Where | Reuse for rings |
|---|---|---|
| Pluggable live-HR protocol | `Services/MetricsSource.swift` (`MetricsSource`, `MetricsSourceState`) | A ring is "just another source." A live-streaming ring is a *conformer*; nothing above the protocol changes. |
| Generic BLE HR source | `Services/BLEHeartRateMetricsSource.swift` (scans `0x180D`, subscribes `0x2A37`, pure `parseHeartRate`) | **A ring that broadcasts the standard BLE Heart Rate Service needs ZERO new code** — it's discovered + connected by this exact source. |
| Source coordinator + picker | `Services/LiveMetricsCoordinator.swift` (`resolve(...)`, forwarding), `Features/WorkoutTracker/HeartRateSourcePicker.swift` | Where a ring is selected/identified. Picker copy + the `resolve` rule extend to a ring with minimal change. |
| Post-hoc HR reads | `Services/HealthKitService.swift` (`heartRateSamples(for:)` over a workout window) | **The realistic mainstream-ring path:** read the ring's HR from Apple Health for the session's time window. Pattern already proven in the flagship Reels app. |
| Per-session HR series | `WorkoutSession.hrSeries: [HRPoint]` (B2), flushed from `app.liveWorkout.samples` on finish | The target field. Today it's **live-buffer-only** — a ring-only user with no live source finishes with an **empty** `hrSeries` (the B2 chart hides, B4 highlight is HR-blind). The gap to close. |
| Pure HR math | `WorkoutHRStats`, `HeartRateZone` (`Shared/`), `HighlightEngine.HeartRateSeries` | Consume the ring series unchanged — avg/max/min, time-in-zone, smoothed chart line, highlight selection. No engine change (engine stays platform-free). |
| The on-device / no-cloud rule | `project.md` constraints; `decisions.md` 2026-06-01 (Fitbit/Google cloud = NO-GO) | The hard boundary that decides Tier 3 below. |

**The one structural fact that drives everything:** rings are built for **passive, battery-frugal,
sync-when-convenient** tracking. The overwhelming majority do **not** broadcast a live standard-BLE HR
stream; they speak a **proprietary BLE GATT** to their own companion app, which then writes to Apple
Health (and/or a vendor cloud). So for most rings the data is **available post-hoc, not live** — that
single property, not the brand, decides the integration path.

## 3. Feasibility by access tier (verdicts)

### Tier 1 — Standard BLE Heart Rate Service broadcast (`0x180D` / `0x2A37`) → live
- **Mechanism:** identical to a chest strap. The ring advertises service `0x180D`, exposes the Heart Rate
  Measurement characteristic `0x2A37`, and pushes ~1 Hz notifications. `BLEHeartRateMetricsSource`
  **already** scans, connects, parses (UInt8/UInt16 per the flags byte), and emits `HRSample`s on the
  session timeline.
- **Reality check:** few-to-no mainstream consumer rings expose this for third-party apps today (Oura,
  Ultrahuman, Galaxy Ring, RingConn all use proprietary BLE + app/cloud sync; reverse-engineering a
  proprietary protocol is brittle, ToS-risky, and out of scope). Treat Tier 1 as the path for **any ring
  that documents a standard-HR / "broadcast" mode** — verify per device.
- **Cost if a target ring qualifies:** ~zero. Relabel the picker ("bands **and rings**"), maybe show the
  ring name from `CBPeripheral.name`. The transport, buffering, offset, parsing, pause/resume display,
  overlay, Live Activity, and B2/B4 flush all already work — a ring is indistinguishable from a band here.
- **Verdict: GO where supported, FREE.** No new code beyond copy. The single best outcome — pursue first
  for any ring that broadcasts standard HR.

### Tier 2 — Ring's companion app writes HR to Apple Health → post-hoc
- **Mechanism:** the ring syncs to its iOS app (proprietary BLE), and that app writes `HKQuantityType`
  `.heartRate` (and possibly `.activeEnergyBurned`, `HKWorkout`) into HealthKit. Snappet reads it with
  the **existing** `HealthKitService` pattern — `HKSampleQuery` over `[session.startedAt, completedAt]`.
  This is the **same authoritative post-hoc read** the flagship Reels app already uses, and `.heartRate`
  read access is **already** requested in `HealthKitService.requestAuthorization()`.
- **Reality check / caveats (the honest part):**
  - **It is NOT live.** The ring syncs minutes-to-hours later, so this **cannot** drive the A4 overlay /
    timers / Live Activity. It populates `hrSeries` **after** the fact. → it is a *backfill*, not a
    `MetricsSource` (the protocol assumes live samples; don't force a ring into it).
  - **Granularity varies by ring.** A dense in-workout series is ideal for the engine; some rings write
    sparse spot-HR outside an explicit "workout." The B2 chart + B4 selection degrade gracefully on a
    sparse series (`HeartRateSeries.make` resamples), but a too-sparse series yields a weak highlight
    ranking — note, don't promise.
  - **Sync timing.** At `finishWorkout`, the ring may not have synced yet → an immediate read returns
    nothing. The backfill must be **re-runnable** (on later app-foreground, or an explicit "Update from
    Health" button), not a one-shot at finish.
  - **Source attribution.** HealthKit HR samples in a window may come from *multiple* devices (e.g. a
    paired Watch *and* the ring). Filter/prefer by `HKSource`/`HKDevice` if the user has more than one,
    or surface the source name ("Heart rate from **Oura Ring**") — this is the rings' analog of the
    studio's *"identify the active band"* ask (#4).
- **Verdict: GO — and this is the realistic path for mainstream rings.** A post-finish, re-runnable
  HealthKit HR import that fills a session's `hrSeries`, so B2/B4 work for a ring-only user. Pure reuse of
  the `HealthKitService` query shape; no engine change; on-device.

### Tier 3 — Vendor cloud API (Oura API, Ultrahuman Partner API, …) → ruled out
- **Mechanism:** OAuth + REST to the vendor cloud (account, network, off-device data).
- **Verdict: NO-GO.** Directly violates the standing constraint — *on-device only, no backend, no
  network sync, no accounts; health data never leaves the device* (`project.md`). This is the **same
  ruling already made for Fitbit/Google** (`decisions.md` 2026-06-01, RESEARCH §3.3): *"NO-GO for cloud;
  revisit only as a post-hoc HealthKit source if the band writes to Health."* A ring's cloud API is the
  Fitbit case again — re-routed through Tier 2 (HealthKit) or not at all.

### Not feasible regardless of tier
- **"Trigger the relevant workout on the ring" (the #4 control ask).** There is no public iOS API to
  start/stop a ring's recording from a third-party app (rings auto-detect or are driven only by their own
  app). Out of scope — Snappet can *identify* the HR source (Tier 1 name / Tier 2 `HKSource`) but not
  *control* the ring. State this so it isn't mistaken for an oversight.
- **Energy/calories live.** The BLE HR profile carries none (`BLEHeartRateMetricsSource.energy == 0`,
  already true); Tier 2 can read `.activeEnergyBurned` post-hoc **if** the ring writes it.

## 3a. Oura Ring — the specific verdict (target, 2026-06-02)

Applying §3 to Oura (Gen 3 / 4 / 5) — verified against Oura's own docs (sources below):

- **Tier 1 (live BLE HR from the ring): NO — and Oura proves it the hard way.** The Oura ring does
  **not** advertise the standard BLE Heart Rate Service for third-party live streaming. More tellingly,
  Oura's *own* **"Live Activity Tracking / Live Heart Rate"** workout feature does **not** use the ring
  for real-time workout HR — it instructs the user to pair an **external Bluetooth chest strap or AirPods
  Pro** ("any Bluetooth-enabled chest strap, such as Polar") for live HR, because finger-PPG is
  unreliable during motion. So even Oura doesn't treat the ring as a live workout-HR source. There is
  **nothing for `BLEHeartRateMetricsSource` to connect to** — live ring HR during a workout isn't a
  thing. → **R1 ("rings are bands") does NOT apply to Oura** (the ring will never appear as a `0x180D`
  band); don't relabel the picker as if it will.
- **The useful corollary:** the *live* path for an Oura user is the **chest strap Oura itself tells them
  to buy** — and Snappet's existing `BLEHeartRateMetricsSource` connects that exact strap **directly**
  (`0x180D`/`0x2A37`), no Oura app in the loop. So a user who wants the live A4 overlay pairs the strap
  with *Snappet*; the *ring* contributes the post-hoc layer below. The two are complementary, not
  competing.
- **Tier 2 (post-hoc Apple Health): YES — this *is* the Oura integration.** Oura writes to Apple Health:
  **resting heart rate, HRV, heart-rate samples**, and — via "Record a Workout" / auto-detected activity
  — **workout HR + active energy + duration**. Snappet's R2 backfill reads that HR for the session window
  into `hrSeries`. Oura's *own-documented* caveats land exactly on R2's design:
  - **Granularity is limited.** Apple Health may get total active energy + duration but a **coarser HR
    series** and an imprecise/uncategorized workout *type* (vs. an Apple Watch). → good enough for B2's
    chart + time-in-zone + recovery context; **weaker for B4's fine-grained highlight ranking** (a sparse
    series gives the selector less to rank on). Promise the summary, hedge the reel.
  - **Sync is delayed** (ring → Oura app → Health, not instant). → confirms R2 must be **re-runnable**
    (foreground re-read + an explicit "Update from Health"), never a finish-time one-shot.
  - Actual in-workout **sample density** from a current Oura firmware is **device-pending** — measure
    before claiming the reel works well on ring-only HR.
- **Tier 3 (Oura cloud API v2): NO-GO.** Oura has a documented OAuth2 REST API (a `/heartrate` endpoint,
  ~5-min granularity), but it's cloud + account → ruled out by on-device-only, same as Fitbit. Route
  through HealthKit (Tier 2) or not at all.
- **Bonus Oura-only signals (post-hoc, out of scope for now):** HRV, resting HR, and readiness/recovery
  are things a *ring* gives that a strap doesn't — not workout HR, but they could enrich a session
  summary later ("recovery before this workout"). Noted, not built; HR-driven highlights don't need them.

**Bottom line for Oura:** there is **no live ring HR** (Oura itself says: use a strap — which Snappet
already supports live), so **skip R1** and build **R2** — integrate the Oura ring as a **post-hoc
Apple-Health HR backfill** into a session's `hrSeries`. Live overlay, if wanted, comes from a chest strap
paired straight to Snappet. No engine change, no cloud, no new live architecture.

## 4. Recommended approach & phasing

Mirror the studio's `MetricsSource` discipline: **live transport stays BLE-standard-only; rings that
can't stream live are a post-hoc HealthKit backfill, not a fake live source.** Phase by cost/value.

```
                          ┌─ Tier 1: standard BLE HR ring ──► BLEHeartRateMetricsSource (EXISTS) ─┐
 ring HR ─ how exposed? ──┤                                                                        ├─► WorkoutSession.hrSeries ─► B2 chart / B4 reel
                          └─ Tier 2: ring app → Apple Health ─► HealthKit window read (NEW path) ──┘        (+ live: A4 overlay / Live Activity, Tier 1 only)
                             Tier 3: vendor cloud ───────────────────────────────────────────────► ✗ NO-GO (on-device-only)
```

- **Phase R1 — "rings are bands" (copy-only, free) — N/A for Oura.** For a ring that *does* advertise
  standard `0x180D` (not Oura — see §3a), generalize the HR-source picker + footer to name **rings**
  alongside chest straps/Polar/Garmin and surface the connected ring's BLE name; **no transport code**,
  since `BLEHeartRateMetricsSource`, the coordinator, the overlay, and the B2/B4 flush already cover it.
  **Skip this for the Oura target** — the Oura ring never appears as a BLE band, so relabeling the picker
  for it would mislead. (If a strap is paired for live HR, that already shows correctly today.)

- **Phase R2 — post-hoc HealthKit HR backfill (the mainstream-ring path).** Add a re-runnable import that
  fills a finished session's `hrSeries` from Apple Health for `[startedAt, completedAt]` when the live
  buffer is empty (ring-only) — and lets a Watch+ring user prefer a chosen `HKSource`.
  - *New:* a small `Services/` helper (or a method on `HealthKitService`) `heartRateSamples(start:end:
    preferredSource:) -> [HRSample]` reusing the existing `HKSampleQuery` + `count/min` unit mapping;
    map `HRSample → HRPoint` with the **existing** `WorkoutHRStats.points(from:)` so the math stays
    unit-tested and pure.
  - *Trigger:* not a one-shot at finish (the ring may not have synced) — an **"Update heart rate from
    Health"** action in `SessionDetailView`, plus an opportunistic re-read on app-foreground for a recent
    session whose `hrSeries` is still empty. Idempotent (replace, keyed on the session window).
  - *Honors:* `HighlightEngine` untouched; HealthKit read auth already requested; on-device. The B2/B4
    code already consumes `hrSeries` — no change there.
  - *Pure, testable seam:* a window/source-filter/merge rule over plain `HRSample`s (no HealthKit type
    crossing the boundary), unit-tested in `SnappetTests` — the same discipline as `SessionMediaService`
    / `BLEHeartRateMetricsSource.parseHeartRate`.

- **Phase R3 — vendor cloud:** **do not build.** Record the NO-GO so it isn't re-litigated.

## 5. Constraints honored / risks / what's device-pending

- **On-device only.** Tier 1 (BLE) and Tier 2 (HealthKit) never touch the network; Tier 3 (cloud) is
  rejected for exactly that reason. No accounts, no analytics, health data stays on device.
- **Layering rule intact.** `HighlightEngine` gains **zero** platform imports — ring HR becomes plain
  `HRSample`/`HRPoint` at the `Services` boundary, identical to the watch/band/post-hoc paths. New I/O is
  a `Services/` type; pure logic is unit-tested with no device.
- **Knowledge graph.** R1/R2 touch user-facing surfaces (picker copy; a new "import from Health" action),
  so `docs/knowledge-graph/data.js` must be updated **in the same change** that implements them (this
  research doc itself changes no UX, so it adds no node).
- **Risks / device-pending (the honest bar — none of this is verified off hardware):**
  - Which target ring (if any) actually broadcasts standard `0x180D` (Tier 1) is **unconfirmed** until
    measured on a device — likely *none* of the big-brand rings do today.
  - Tier 2 HR **density + sync latency** per ring is unknown until measured; a sparse series weakens B4.
  - Multi-source HealthKit disambiguation (Watch vs ring in the same window) needs a real two-device
    setup to validate the `HKSource` preference.
  - Battery/latency of a sustained BLE notify stream **from a ring** (smaller battery than a strap) is a
    device check, same caveat as the existing BLE band.

## 6. Open questions (for the user / device validation)

1. **Which ring(s)?** A specific brand (Oura / Ultrahuman / Galaxy Ring / RingConn) pins the tier and the
   exact HealthKit data it writes. Without one, R1+R2 cover the field generically.
2. **Live or post-hoc enough?** If a live in-workout overlay from the ring is required and the target ring
   has no standard-BLE broadcast, the honest answer is **post-hoc only** (Tier 2) — confirm that's
   acceptable, or the ring must be paired with a live source (Watch/strap) for the overlay.
3. **Watch + ring together?** If users wear both, define the preference (default: Watch live for the
   overlay; ring can still backfill/augment post-hoc via `HKSource` selection).

## 7. Bottom line

The studio's `MetricsSource` + `HealthKitService` seams were built precisely so a new HR wearable is a
plug-in. In the **general** case: a standard-BLE ring works for free (R1), the realistic mainstream path
is a post-hoc Apple-Health HR backfill into `hrSeries` (R2), and vendor cloud APIs are out (R3),
consistent with the existing Fitbit/Google ruling.

**For the Oura target specifically (§3a):** there is **no live HR from the ring** — Oura itself routes
live workout HR through an external chest strap, which Snappet already supports directly. So **skip R1
and build R2**: integrate Oura as a **post-hoc Apple-Health HR backfill** into a finished session's
`hrSeries` (re-runnable, source-filterable), good for the B2 summary and recovery context, hedged for the
B4 reel (Oura's HR series is coarser than a Watch/strap). Live overlay, if the user wants it, comes from a
chest strap paired straight to Snappet — not the ring. No `HighlightEngine` change, no backend, no new
live architecture — one narrow post-hoc read.

## Sources

- Oura — Apple Health Integration (which data types sync): <https://support.ouraring.com/hc/en-us/articles/360025438734-Apple-Health-Integration>
- Oura — Live Heart Rate (ring shows spot HR at rest): <https://support.ouraring.com/hc/en-us/articles/4410651298963-Live-Heart-Rate>
- Oura — Live Activity Tracking (pairs an external BT chest strap / AirPods for live workout HR): <https://ouraring.com/blog/live-activity-tracking/>
- Oura — Record a Workout / Workout Heart Rate: <https://ouraring.com/blog/oura-workout-heart-rate/>
- Oura — Developer / Cloud API (Tier 3, cloud + OAuth → out of scope): <https://ouraring.com/developer>
- 9to5Mac — Oura 2025 fitness metrics + Apple Health updates: <https://9to5mac.com/2025/05/21/oura-ring-gets-better-fitness-metrics-and-more-integrations/>
- Acciyo — "Does Oura Work With Apple Health?" (granularity limitation summary): <https://www.acciyo.com/does-oura-ring-work-with-apple-health/>
