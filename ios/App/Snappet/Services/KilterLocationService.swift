import CoreLocation
import Foundation

/// A thin, when-in-use CoreLocation wrapper that publishes the device's **current coarse place** for the
/// pre-connect arrival suggestion (Flow 1, Option B). It is deliberately minimal: a single coarse fix
/// (reduced accuracy), bucketed immediately into a `CoarsePlace`, and **never reverse-geocoded, never
/// networked** — the coarse value stays on the device. Authorization is requested **lazily** (only when
/// the feature is actually used), and every denied / restricted / unavailable path degrades to a `nil`
/// place so the module falls back to BLE-only with no crash and no prompt loop.
///
/// All CoreLocation I/O lives here behind the Services edge; the pure place-match (`KilterPlaceMatcher`,
/// in `KilterBoardMemory.swift`) is what the unit tests exercise. The live fix is device-pending.
@MainActor
@Observable
final class KilterLocationService: NSObject {
    /// Authorization state, mapped to a small enum the view can switch on without importing CoreLocation.
    enum Authorization: Equatable {
        case notDetermined   // never asked — the lazy `requestIfNeeded` will prompt
        case denied          // user said no, or it's restricted/unavailable → BLE-only, no prompts
        case authorized      // when-in-use granted
    }

    /// The most recent coarse place, or `nil` when location is unavailable / not yet resolved. Bucketed
    /// (≈110 m) the instant a fix arrives; the precise `CLLocation` is dropped immediately.
    private(set) var currentPlace: CoarsePlace?
    private(set) var authorization: Authorization = .notDetermined

    /// Whether the feature is usable — derived **live** from the current authorization (the view hides
    /// the feature entirely when location is denied/restricted, rather than show a dead toggle). We do
    /// NOT freeze this at init: the global `CLLocationManager.locationServicesEnabled()` is documented as
    /// main-thread-blocking, and CoreLocation already reports a services-off device through the
    /// denied/failure delegate paths, so gating on the status is sufficient and never blocks.
    var isSupported: Bool { authorization != .denied }

    private let manager: CLLocationManager
    /// Guards the single one-shot retry in `didFailWithError` so a failing fix can't trigger a storm.
    /// Main-actor isolated (every read/write is inside a main-actor method or `MainActor.assumeIsolated`);
    /// not UI state, so it's excluded from observation.
    @ObservationIgnored private var didRetryThisRequest = false

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        // Coarse by design: never ask for precise location for a gym-bucket match.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        authorization = Self.map(manager.authorizationStatus)
    }

    /// Lazily request when-in-use authorization the first time the feature wants a fix (so the very first
    /// app launch never prompts). When already authorized, also asks for one fresh coarse fix. A no-op
    /// once denied/restricted (no prompt loop) — degrades silently to BLE-only.
    func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            requestFix()
        default:
            break   // denied / restricted — degrade silently to BLE-only
        }
    }

    /// Ask for one fresh coarse fix (e.g. on entering Kilter). No-op unless authorized.
    func refresh() {
        guard manager.authorizationStatus == .authorizedWhenInUse
                  || manager.authorizationStatus == .authorizedAlways else { return }
        requestFix()
    }

    /// Start a one-shot fix request, resetting the per-request retry guard so a fresh request is allowed
    /// its single delayed retry again.
    private func requestFix() {
        didRetryThisRequest = false
        manager.requestLocation()
    }

    private static func map(_ status: CLAuthorizationStatus) -> Authorization {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied   // .denied / .restricted
        }
    }
}

extension KilterLocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        nonisolated(unsafe) let manager = manager
        MainActor.assumeIsolated {
            authorization = Self.map(manager.authorizationStatus)
            // Newly granted → grab the first coarse fix so the suggestion can appear without another tap.
            if authorization == .authorized { manager.requestLocation() }
            if authorization == .denied { currentPlace = nil }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Bucket immediately and drop the precise coordinate — only the coarse square is ever kept.
        guard let coord = locations.last?.coordinate else { return }
        let bucket = CoarsePlace(latitude: coord.latitude, longitude: coord.longitude)
        MainActor.assumeIsolated {
            currentPlace = bucket
            // A fix landed — clear the retry guard so the next request gets its retry budget back.
            didRetryThisRequest = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed fix is not fatal — keep the last known place (if any) and stay BLE-capable. A first
        // failure is often a transient indoor miss, so allow ONE bounded, delayed retry before giving up
        // (no retry storm — the per-request guard permits exactly one).
        nonisolated(unsafe) let manager = manager
        MainActor.assumeIsolated {
            guard !didRetryThisRequest,
                  manager.authorizationStatus == .authorizedWhenInUse
                      || manager.authorizationStatus == .authorizedAlways else { return }
            didRetryThisRequest = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak manager] in
                manager?.requestLocation()
            }
        }
    }
}
