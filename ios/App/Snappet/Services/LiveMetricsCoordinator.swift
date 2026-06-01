import Foundation
import Observation
import HighlightEngine

/// Which kind of live-metrics source is active. The picker (from `WorkoutSettingsView`)
/// sets this; the coordinator forwards the `MetricsSource` surface to the matching source.
enum MetricsSourceKind: String, CaseIterable, Identifiable, Sendable {
    case appleWatch
    case ble
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleWatch: return "Apple Watch"
        case .ble: return "Heart-rate band"
        }
    }
}

/// The single live-metrics entry point the app talks to (kept as `AppModel.liveWorkout`
/// so A2/A4 call sites don't churn — decisions.md 2026-06-01, A3). It is itself a
/// `MetricsSource`: it holds an `AppleWatchMetricsSource` + a `BLEHeartRateMetricsSource`,
/// tracks the user-`selectedSource` + the discovered-BLE list, and **forwards** the whole
/// protocol surface to the active source. `start`/`stop` drive only the active source.
///
/// Mirrors the `HighlightSelector` pluggability pattern (decisions.md 2026-05-30): swapping
/// HR transports is a coordinator concern, invisible to the player / Live Activity / overlay.
@MainActor
@Observable
final class LiveMetricsCoordinator: MetricsSource {

    let watch: AppleWatchMetricsSource
    let ble: BLEHeartRateMetricsSource

    /// The user's explicit pick, or `nil` to use the automatic default (watch when usable,
    /// else BLE if a band was chosen). Setting it pins the source.
    var selectedSource: MetricsSourceKind?

    /// Whether a workout session is currently driving a source (`start()` called, `stop()` not
    /// yet). Source-agnostic — the resume guard reads this instead of the watch-specific
    /// `connectionState`, so a **BLE** session isn't needlessly restarted on resume (which would
    /// clear its HR buffer and reconnect the band).
    private(set) var isSessionActive = false

    init(watch: AppleWatchMetricsSource = AppleWatchMetricsSource(),
         ble: BLEHeartRateMetricsSource = BLEHeartRateMetricsSource()) {
        self.watch = watch
        self.ble = ble
    }

    /// Discovered BLE bands, surfaced for the picker.
    var discoveredBLE: [BLEDevice] { ble.discovered }

    /// The active source kind, resolving the automatic default when nothing is pinned.
    var activeKind: MetricsSourceKind {
        Self.resolve(selected: selectedSource,
                     watchUsable: watch.watchUsable,
                     hasBLEDevice: ble.connectedName != nil)
    }

    /// Pure source-selection rule (unit-testable, no device):
    /// an explicit pick wins; otherwise prefer the Apple Watch when it's usable
    /// (paired + app installed), else fall back to BLE when a band has been chosen.
    /// With neither available we still default to the watch (its `.unavailable` state
    /// drives the UI's "no source" message — the same as A1's behavior).
    nonisolated static func resolve(selected: MetricsSourceKind?,
                                    watchUsable: Bool,
                                    hasBLEDevice: Bool) -> MetricsSourceKind {
        if let selected { return selected }
        if watchUsable { return .appleWatch }
        if hasBLEDevice { return .ble }
        return .appleWatch
    }

    /// The currently active concrete source.
    private var active: any MetricsSource {
        activeKind == .ble ? ble : watch
    }

    // MARK: - MetricsSource (forwarded to the active source)

    var latestHR: Double? { active.latestHR }
    var energy: Double { active.energy }
    var samples: [HRSample] { active.samples }
    var state: MetricsSourceState { active.state }
    var isReachable: Bool { active.isReachable }
    var displayName: String { active.displayName }

    func start(for session: WorkoutSession, sport: SportTag?, category: ExerciseCategory?) {
        isSessionActive = true
        active.start(for: session, sport: sport, category: category)
    }

    func stop() {
        isSessionActive = false
        // Stop both so neither transport is left running after a source switch mid-session.
        watch.stop()
        ble.stop()
    }

    // MARK: - A1 compatibility shims (so A2/A4 call sites don't churn)

    /// The Apple-Watch connection state, used by the session lifecycle in
    /// `WorkoutHomeView` (the "is a workout already running on the watch?" guard) and by
    /// the player's watch-specific status text. Forwards to the watch source — the one
    /// allowed surface that stays watch-shaped because resume/replace logic is watch-specific.
    var connectionState: AppleWatchMetricsSource.ConnectionState { watch.connectionState }
}
