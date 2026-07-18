import Foundation

/// A shareable reference to a catalog climb, encoded as a compact `snappet://` URL. Both phones ship
/// the *same* read-only catalog (same `climb_uuid`s), so a scanned link resolves fully **offline** —
/// no account, no network. Kept a pure value type + codec so it's unit-testable without a camera.
///
/// Wire form: `snappet://kilter/climb/<uuid>?angle=<n>` (the angle is optional — the scanner opens
/// the climb at that angle when present).
struct KilterClimbLink: Equatable, Sendable {
    let uuid: String
    /// The angle the sharer was viewing, if any.
    var angle: Int?

    init(uuid: String, angle: Int? = nil) {
        self.uuid = uuid
        self.angle = angle
    }

    var url: URL? {
        var c = URLComponents()
        c.scheme = "snappet"
        c.host = "kilter"
        c.path = "/climb/\(uuid)"
        if let angle { c.queryItems = [URLQueryItem(name: "angle", value: String(angle))] }
        return c.url
    }

    /// The string actually encoded into the QR symbol (empty only if the uuid is unrepresentable).
    var encoded: String { url?.absoluteString ?? "" }

    /// Parse a scanned/opened string back into a climb link, or nil if it isn't one of ours.
    init?(decoding string: String) {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "snappet",
              c.host?.lowercased() == "kilter" else { return nil }
        // path = "/climb/<uuid>"
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "climb", !parts[1].isEmpty else { return nil }
        self.uuid = parts[1]
        self.angle = c.queryItems?.first { $0.name == "angle" }?.value.flatMap { Int($0) }
    }
}

/// The app-wide `snappet://` route table for `onOpenURL` (#75 — the scheme is registered in
/// `Resources/Info.plist` `CFBundleURLTypes`, so the iOS Camera's QR scan / Safari / another app
/// can open us cold or warm). Pure parse → typed route; the shell switches over the result and
/// carries the intent through `SuiteRouter` (`pendingKilterClimb`, the `pendingWorkoutResume`
/// pattern) because the climb push needs the Kilter root's `navigationDestination` + catalog.
/// One case today; App Intents / future modules (#81) add cases, not string-matching in the shell.
enum SnappetDeepLink: Equatable, Sendable {
    /// `snappet://kilter/climb/<uuid>?angle=<n>` — a shared climb (the QR payload).
    case kilterClimb(KilterClimbLink)
    /// `snappet://pomodoro/start` — open Pomodoro and start a focus timer (the #81 Today widget's
    /// Start-focus button). The shell routes to the module + a one-shot `pendingPomodoroStart`.
    case startFocus
    /// `snappet://exercise/<id>` — open a catalog exercise's detail (the #81 Phase-4 Spotlight tap).
    case exercise(id: String)
    /// `snappet://routine/v1/<blob>` — a shared workout routine (workout-redesign E6's QR/link payload).
    /// The shell routes to the gym tracker + a one-shot `pendingRoutineImport` (the `pendingKilterClimb`
    /// pattern), which the tracker root consumes into an import-confirm preview (NEW local UUID).
    case routine(SharedRoutine)
    /// `snappet://festival/v1/<blob>` (a payload lineup/plan) or `snappet://festival/install/<packID>`
    /// (the install-link fallback) — a shared festival lineup (festival prompt 05, the `.routine`
    /// pattern). The shell routes to the Festival mini-app + a one-shot `pendingFestivalImport`, which
    /// the root consumes into an import-confirm preview (new lineup / applied plan, never silent).
    case festivalLineup(SharedLineup)

    /// Parse an incoming URL into a route, or nil when it isn't one of ours (the shell ignores it).
    static func route(for url: URL) -> SnappetDeepLink? {
        if let link = KilterClimbLink(decoding: url.absoluteString) { return .kilterClimb(link) }
        if let routine = SharedRoutine(decoding: url.absoluteString) { return .routine(routine) }
        if let lineup = SharedLineup(decoding: url.absoluteString) { return .festivalLineup(lineup) }
        if isStartFocus(url) { return .startFocus }
        if let id = exerciseID(url) { return .exercise(id: id) }
        return nil
    }

    /// `snappet://exercise/<id>` → the exercise id (scheme + host checked case-insensitively). Pure.
    private static func exerciseID(_ url: URL) -> String? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "snappet",
              c.host?.lowercased() == "exercise" else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count == 1, !parts[0].isEmpty else { return nil }
        return parts[0]
    }

    /// `snappet://pomodoro/start` (scheme + host + path checked, case-insensitively). Pure, so the
    /// route table stays unit-testable without the shell.
    private static func isStartFocus(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "snappet",
              c.host?.lowercased() == "pomodoro" else { return false }
        return c.path.split(separator: "/").map(String.init) == ["start"]
    }
}

/// Where an arriving climb link should land once the catalog's knowledge is in hand — pure, so the
/// graceful-landing rules are unit-testable without a catalog/camera/simulator (#75). Used by BOTH
/// entry points (the registered URL scheme and the in-app scanner), so they can't drift.
enum KilterDeepLinkRouting {
    enum Destination: Equatable, Sendable {
        /// Push the climb. `adoptAngle` is the sharer's angle when this board offers it
        /// (mirrors the scanner's pre-#75 behavior), nil to leave the user's angle alone.
        case openClimb(uuid: String, adoptAngle: Int?)
        /// The climb isn't on this device (trimmed/smaller catalog, or none installed) — land
        /// gracefully on the module root and explain, instead of a dead detail screen.
        case explainMissing(uuid: String)
    }

    /// `climbInstalled`: resolvable on this device (active catalog OR a user-created climb).
    /// `availableAngles`: the angles the installed catalog offers (empty when none installed).
    static func destination(for link: KilterClimbLink,
                            climbInstalled: Bool,
                            availableAngles: [Int]) -> Destination {
        guard climbInstalled else { return .explainMissing(uuid: link.uuid) }
        let adopt = link.angle.flatMap { availableAngles.contains($0) ? $0 : nil }
        return .openClimb(uuid: link.uuid, adoptAngle: adopt)
    }
}
