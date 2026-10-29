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

/// Plan a session's "Climbs to pick" (replaces the on/off "Prefer climbs I haven't sent").
enum KilterPlanClimbChoice: String, CaseIterable, Sendable {
    /// Sends and projects the climber hasn't sent yet (the old switch on).
    case newOnly
    /// Revisit sent climbs too (the old switch off) — volume, recovery.
    case includeSent
    /// Open projects fill the project slots first, then new climbs.
    case projectsFirst

    var label: String {
        switch self {
        case .newOnly: return "New climbs only"
        case .includeSent: return "Include sent"
        case .projectsFirst: return "Projects first"
        }
    }

    var detail: String {
        switch self {
        case .newOnly: return "Only climbs you haven’t sent — warm-ups too"
        case .includeSent: return "Revisit favourites too — good for volume"
        case .projectsFirst: return "Your open projects fill the project slots, then new climbs"
        }
    }

    /// Sent climbs may fill send / project slots.
    var allowsSent: Bool { self == .includeSent }
}
