import Foundation
import HealthKit
import HighlightEngine

/// What a `MetricsSource` needs to begin a live session, decoupled from any one feature's
/// session model. Originally `start(for:)` took a `WorkoutSession`, but the sources only ever
/// read two things from it: the wall-clock `startedAt` (to re-base samples onto the engine's
/// `HRSample.t` timeline) and the `HKWorkoutActivityType` the watch should record. Lifting those
/// into a tiny value type lets a **Kilter climbing session** (or any future surface) drive live
/// HR without pretending to be a `WorkoutSession` (decisions.md 2026-06-06).
struct LiveMetricsContext: Sendable {
    /// The session's authoritative zero for `HRSample.t` (seconds since the session began).
    var startedAt: Date
    /// The workout type the Apple Watch should start (`HKWorkoutSession`). The BLE band ignores
    /// it — it just streams HR — so only the watch path reads this.
    var activityType: HKWorkoutActivityType
}

/// Source-agnostic lifecycle of a live-metrics source, exposed so the UI (A4 overlay,
/// the source picker) can show a graceful state without knowing whether HR is coming
/// from an Apple Watch (`WCSession`) or a BLE band (`CoreBluetooth`).
///
/// This generalizes `LiveWorkoutService.ConnectionState` (A1, watch-specific) into a
/// surface every `MetricsSource` shares (decisions.md 2026-06-01, A3). The Apple-Watch
/// source maps its `ConnectionState` onto these cases; the BLE source maps its
/// `CBPeripheral`/`CBCentralManager` lifecycle onto the same cases.
enum MetricsSourceState: Equatable, Sendable {
    /// The transport is unavailable on this device (no watch capability / Bluetooth off
    /// or unauthorized). The UI surfaces a "no source" state.
    case unavailable
    /// Available but not doing anything yet (activated / powered-on, idle).
    case idle
    /// Establishing a link (watch reachable but no workout yet / BLE connecting).
    case connecting
    /// Linked (watch running a workout / BLE peripheral connected + subscribed) but no
    /// sample has arrived yet.
    case connected
    /// Linked **and** delivering samples (the first HR sample has arrived).
    case streaming
}

/// A pluggable live heart-rate / energy source for the WorkoutTracker live path.
///
/// Mirrors the `HighlightSelector` pluggability pattern (decisions.md 2026-05-30): the
/// app talks to *this* protocol, never a concrete transport, so HR can come from an
/// Apple Watch (A1), a generic BLE chest strap / band (`0x180D`/`0x2A37`, A3), or a
/// future source — switching is a swap, never a rewrite. `HighlightEngine` stays
/// platform-free; live HR becomes plain `HRSample` value types at this `Services`
/// boundary, exactly like the post-hoc HealthKit path.
///
/// The surface is the A1 `LiveWorkoutService` public surface, generalized: the
/// watch-specific `isWatchReachable` became `isReachable` and `connectionState` became
/// the source-agnostic `state` (decisions.md 2026-06-01, A3).
@MainActor
protocol MetricsSource: AnyObject {
    /// Latest heart rate (bpm), or `nil` before the first sample.
    var latestHR: Double? { get }
    /// Latest cumulative active energy (kcal). BLE HR-only sources report `0`
    /// (energy isn't in the Heart Rate Profile).
    var energy: Double { get }
    /// Buffered HR series for the active session, `t` relative to its `startedAt`
    /// (engine convention). The single engine-boundary buffer B2/B4 will flush.
    var samples: [HRSample] { get }
    /// Source-agnostic connection lifecycle.
    var state: MetricsSourceState { get }
    /// Whether the source is currently reachable for an immediate exchange (watch
    /// reachable / BLE peripheral connected).
    var isReachable: Bool { get }
    /// A user-facing name for this source (e.g. "Apple Watch", "Polar H10").
    var displayName: String { get }
    /// Whether the source currently reports the sensor has lost skin/strap contact. `nil` when the
    /// source can't report contact at all (the Apple Watch, or a band that doesn't support the
    /// optional Heart Rate Measurement sensor-contact flag) — distinct from `false` ("contact is
    /// fine"). Drives the "adjust strap" affordance + the no-contact sample drop (decisions.md 2026-06-08).
    var isContactLost: Bool? { get }

    /// Start a live session: map the context to whatever the source needs and reset the
    /// HR buffer onto its `startedAt` timeline.
    func start(_ context: LiveMetricsContext)
    /// End the live session. Buffered `samples` are retained for B2.
    func stop()

    /// Pause the live session. For an Apple Watch this pauses the on-wrist `HKWorkoutSession`
    /// (so HR/energy collection stops); for a transport with no session concept (a BLE band
    /// that just streams) this is a no-op and pause is purely a UI/Live-Activity state tracked
    /// by the coordinator. Default: no-op.
    func pause()
    /// Resume a paused live session. Default: no-op.
    func resume()
}

extension MetricsSource {
    // Default no-ops so a stream-only source (BLE) needn't implement pause/resume — the
    // coordinator still tracks the paused *display* state for those sources.
    func pause() {}
    func resume() {}

    // Sources that can't report sensor contact (the Apple Watch, unsupported bands) default to
    // `nil` so only the BLE band needs to implement it.
    var isContactLost: Bool? { nil }
}
