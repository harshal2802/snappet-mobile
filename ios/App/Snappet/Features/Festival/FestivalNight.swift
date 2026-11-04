import Foundation

// MARK: - The night (prompt 232, pure)
//
// Where you are across a festival night: at a set, on a break, walking to another stage, just
// arrived, or between things. The Halloween bug was that a claim never ended — "I'm here" at one
// set stuck for the rest of the night and the switcher only offered what the printed clock said was
// live. The fix is a decision made at each set's end: carry on to your next STARRED set if one is
// starting, otherwise ask "Where are you now?". Everything here takes `now`, so the whole flow
// unit-tests without a store or a clock.

enum FestivalNight {

    /// A non-set stretch of the night (`FestivalNightStretch.kindRaw`). None of these count as
    /// danced time — they're the gaps the user told us about.
    enum StretchKind: String, CaseIterable, Sendable {
        case arriving
        case rest = "break"
        case walking

        var title: String {
            switch self {
            case .arriving: "Arriving"
            case .rest: "On a break"
            case .walking: "Walking"
            }
        }

        var symbol: String {
            switch self {
            case .arriving, .walking: "figure.walk"
            case .rest: "cup.and.saucer"
            }
        }
    }

    /// The night as the bar / home card render it.
    enum Status: Equatable, Sendable {
        /// No night on for this festival.
        case off
        case atSet(UUID)
        case stretch(StretchKind, since: Date)
        /// The night is on but nothing is claimed — a set just ended and we're asking.
        case between(since: Date)

        var isOn: Bool { self != .off }
    }

    /// The minimal facts `status` needs, as values.
    struct Snapshot: Equatable, Sendable {
        var nightOn: Bool
        var openSetID: UUID?
        var openStretch: (kind: StretchKind, since: Date)?
        /// When the last claim or stretch closed (the "between since" clock).
        var lastClosedAt: Date?
        var nightStartedAt: Date?

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.nightOn == b.nightOn && a.openSetID == b.openSetID
                && a.openStretch?.kind == b.openStretch?.kind && a.openStretch?.since == b.openStretch?.since
                && a.lastClosedAt == b.lastClosedAt && a.nightStartedAt == b.nightStartedAt
        }
    }

    static func status(_ s: Snapshot) -> Status {
        if let id = s.openSetID { return .atSet(id) }
        if let stretch = s.openStretch { return .stretch(stretch.kind, since: stretch.since) }
        guard s.nightOn else { return .off }
        return .between(since: s.lastClosedAt ?? s.nightStartedAt ?? .distantPast)
    }

    // MARK: Set end

    enum SetEndOutcome: Equatable, Sendable {
        /// Carry on to this starred set (the claim moves itself; "Not there? Change" undoes).
        case moveTo(FestivalSet)
        /// Nothing starred is starting — ask where they are.
        case ask
    }

    /// How long after a set ends a starred set may start and still count as "next" — a stage walk
    /// plus a little slack. Past this it's a gap, and we ask.
    static let nextStarredWindow: TimeInterval = 30 * 60

    /// Whether the claim on `set` has run out: the set's (possibly edited) end has passed and the
    /// claim began before it. A claim made AFTER the scheduled end means the set is running late —
    /// the user knows better than the poster, so it's left alone until they change it.
    static func claimHasEnded(set: FestivalSet, claimedAt: Date, now: Date) -> Bool {
        now >= set.end && claimedAt < set.end
    }

    /// At `ended`'s end: the next starred set that's playing then or starts within the window,
    /// earliest first, same stage winning a tie (no walk). Otherwise ask.
    static func outcome(after ended: FestivalSet, in pack: FestivalPack,
                        starred: Set<UUID>) -> SetEndOutcome {
        let at = ended.end
        let candidates = pack.allSets.filter {
            starred.contains($0.id) && $0.id != ended.id
                && $0.end > at && $0.start <= at.addingTimeInterval(nextStarredWindow)
        }
        let next = candidates.min { a, b in
            if a.start != b.start { return a.start < b.start }
            let aSame = a.stage == ended.stage, bSame = b.stage == ended.stage
            if aSame != bSame { return aSame }
            return a.artist < b.artist
        }
        return next.map { .moveTo($0) } ?? .ask
    }

    // MARK: "Where are you now?" / "What's next?"

    struct WhereOptions: Equatable, Sendable {
        /// Playing now by the (edited) schedule — starred first.
        var onNow: [FestivalSet]
        /// Scheduled to have ended recently — "running late?" (the Halloween case).
        var runningLate: [FestivalSet]
        /// Starting soon.
        var upNext: [FestivalSet]
    }

    static let runningLateWindow: TimeInterval = 45 * 60
    static let upNextWindow: TimeInterval = 90 * 60

    static func whereOptions(in pack: FestivalPack, starred: Set<UUID>, excluding: UUID?,
                             now: Date) -> WhereOptions {
        let sets = pack.allSets.filter { $0.id != excluding }
        let onNow = sets.filter { $0.start <= now && now < $0.end }
            .sorted { a, b in
                let aStar = starred.contains(a.id), bStar = starred.contains(b.id)
                if aStar != bStar { return aStar }
                return a.start != b.start ? a.start < b.start : a.artist < b.artist
            }
        let late = sets.filter { $0.end <= now && $0.end > now.addingTimeInterval(-runningLateWindow) }
            .sorted { $0.end != $1.end ? $0.end > $1.end : $0.artist < $1.artist }
        let next = sets.filter { $0.start > now && $0.start <= now.addingTimeInterval(upNextWindow) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.artist < $1.artist }
        return WhereOptions(onNow: onNow, runningLate: late, upNext: next)
    }

    // MARK: Quiet nights

    /// "Still out?" — nothing claimed for this long nudges the user to say where they are or head
    /// home.
    static let stillOutAfter: TimeInterval = 2 * 3600
    /// A night left between things this long was forgotten, not danced: it ends itself, back-dated
    /// to when it went quiet, so the session doesn't run for days.
    static let abandonAfter: TimeInterval = 6 * 3600

    static func isStillOut(_ status: Status, now: Date) -> Bool {
        switch status {
        case .between(let since), .stretch(_, let since): now.timeIntervalSince(since) >= stillOutAfter
        default: false
        }
    }

    static func isAbandoned(_ status: Status, now: Date) -> Bool {
        if case .between(let since) = status { return now.timeIntervalSince(since) >= abandonAfter }
        return false
    }
}
