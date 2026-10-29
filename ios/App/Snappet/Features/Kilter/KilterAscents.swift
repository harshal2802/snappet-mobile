import Foundation

/// **Filter by what you've climbed** (prompt 208, wireframe `docs/ux-research/kilter-ascent-filters/`): browse and
/// Plan a session read the climber's own log. Pure — built from `KilterLogEntry` values, unit-tested in
/// `KilterAscentsTests`.
///
/// User's picks (2026-10-28): a send at ANY angle counts as sent (Kilter logs are per angle; the row says
/// "sent at 50°" when it wasn't this angle); a project is a climb tried but never sent.

/// The browse list's "My ascents" narrowing.
enum KilterAscentFilter: String, CaseIterable, Sendable {
    case any, notTried, projects, sent
    var label: String {
        switch self {
        case .any: return "All"
        case .notTried: return "Not tried"
        case .projects: return "Projects"
        case .sent: return "Sent"
        }
    }
}

/// What the climber has done on one climb, across every angle.
struct KilterAscentSummary: Equatable, Sendable {
    var isSent: Bool
    /// Every logged try (the sum of `attempts`, at least one per log).
    var tries: Int
    var lastLogged: Date
    /// The angles it was sent at (empty for a project).
    var sentAngles: Set<Int>
    /// Sent first go, never needing a second try.
    var isFlash: Bool
}

/// The climber's log, indexed by climb.
struct KilterAscentIndex: Equatable, Sendable {
    struct Log: Sendable, Equatable {
        var climbUUID: String
        var status: KilterAscentStatus
        var attempts: Int
        var date: Date
        var angle: Int
    }

    private(set) var byClimb: [String: KilterAscentSummary] = [:]

    init(_ logs: [Log]) {
        for l in logs {
            var s = byClimb[l.climbUUID]
                ?? KilterAscentSummary(isSent: false, tries: 0, lastLogged: l.date, sentAngles: [], isFlash: false)
            s.tries += max(1, l.attempts)
            s.lastLogged = max(s.lastLogged, l.date)
            if l.status.isSend {
                s.isSent = true
                s.sentAngles.insert(l.angle)
            }
            byClimb[l.climbUUID] = s
        }
        for (uuid, s) in byClimb where s.isSent {
            let sends = logs.filter { $0.climbUUID == uuid }
            byClimb[uuid]?.isFlash = sends.count == 1 && sends[0].status == .flash
        }
    }

    func summary(_ uuid: String) -> KilterAscentSummary? { byClimb[uuid] }

    /// Every climb in the log (tried or sent) — "Not tried" excludes these.
    var loggedUUIDs: [String] { byClimb.keys.sorted() }

    /// Sent at any angle, most recently logged first.
    var sentUUIDs: [String] { ordered { $0.isSent } }

    /// Tried, never sent at any angle — open projects, most recently tried first.
    var projectUUIDs: [String] { ordered { !$0.isSent } }

    private func ordered(_ keep: (KilterAscentSummary) -> Bool) -> [String] {
        byClimb.filter { keep($0.value) }
            .sorted { ($0.value.lastLogged, $0.key) > ($1.value.lastLogged, $1.key) }
            .map(\.key)
    }

    /// The row badge: "✓ Sent", "✓ Sent at 50°", "◐ 3 tries"; `nil` for a climb never logged.
    func badge(_ uuid: String, angle: Int) -> String? {
        guard let s = byClimb[uuid] else { return nil }
        if s.isSent {
            if s.sentAngles.contains(angle) { return "✓ Sent" }
            return "✓ Sent at " + s.sentAngles.sorted().map { "\($0)°" }.joined(separator: ", ")
        }
        return "◐ \(s.tries) \(s.tries == 1 ? "try" : "tries")"
    }

    /// The row's "you: …" line: "you: flashed", "you: sent · 2 tries", "you: 1 try".
    func youLine(_ uuid: String) -> String? {
        guard let s = byClimb[uuid] else { return nil }
        if s.isFlash { return "you: flashed" }
        let tries = "\(s.tries) \(s.tries == 1 ? "try" : "tries")"
        return s.isSent ? "you: sent · \(tries)" : "you: \(tries)"
    }
}

/// Plan a session's "Climbs to pick" — two plain switches (user, 2026-10-28: "just have boolean filters … simple to
/// enable or disable"). Both off = only climbs you've never tried. Off means off: a plan comes back shorter rather
/// than sneaking a sent climb or a project in.
struct KilterPlanClimbs: Equatable, Sendable {
    /// Climbs you've sent (at any angle) may be picked.
    var includeSent = false
    /// Your open projects (tried, never sent) may be picked — and go into the project slots first.
    var includeProjects = false
    /// Only benchmark ("classic") climbs — the browse "Classics only" filter. Strategies leave it as the user set it.
    var classicsOnly = false

    static let newOnly = KilterPlanClimbs()
}
