import Foundation

// MARK: - Set detail + recap derivations (festival prompt 03, pure)
//
// The numbers behind wireframe frames 6 (set detail) and 11 (recap), computed over plain-value
// snapshots of the dance sessions / attendance stretches / clip tags — no SwiftData, no HealthKit.
// HR windowing reuses `HRWindowSlicer` (the one place that maps a series onto a window) so a set's
// curve obeys the same interpolation/edge-clamp/honest-empty contract every clip overlay does.

/// A plain-value snapshot of one dance `WorkoutSession` the festival rode (taken at the store edge).
struct FestivalSessionSnapshot: Sendable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var hrSeries: [HRPoint]
    /// Profile bounds recorded on the session (for %HRR in the reel engine); `nil` = estimated.
    var maxHR: Double? = nil
    var restHR: Double? = nil

    /// The session's absolute coverage (open sessions run to `now`).
    func interval(now: Date = .now) -> DateInterval {
        DateInterval(start: startedAt, end: max(startedAt, endedAt ?? now))
    }
}

/// One closed-or-open "I'm here" stretch as a value (mirrors `FestivalAttendance`).
struct FestivalAttendanceSnapshot: Sendable, Equatable {
    var setID: UUID
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date?

    func interval(now: Date = .now) -> DateInterval {
        DateInterval(start: startedAt, end: max(startedAt, endedAt ?? now))
    }
}

/// One resolved clip tag as a value (mirrors `FestivalClipTag`, sticky `none` rows excluded).
struct FestivalTagSnapshot: Sendable, Equatable {
    var mediaID: UUID
    var setID: UUID
    var artist: String
    var stage: String
    var isAuto: Bool
}

enum FestivalSetStats {

    /// The set's HR curve: the slice of `session.hrSeries` under the set's absolute window,
    /// rebased to seconds-into-the-set (`HRWindowSlicer` contract: ≥2 points or honest-empty).
    /// The window is clamped to the session's own coverage first so a set that outran the session
    /// (left early) charts what was actually recorded, not 40 minutes of clamped flat line.
    static func hrSlice(for set: FestivalSet, session: FestivalSessionSnapshot,
                        now: Date = .now) -> [HRPoint] {
        guard let overlap = session.interval(now: now).intersection(with: set.window),
              overlap.duration > 0 else { return [] }
        let start = overlap.start.timeIntervalSince(session.startedAt)
        return HRWindowSlicer.slice(session.hrSeries, start: start, span: overlap.duration)
    }

    /// The best session to chart a set from: the one whose attendance at this set covered the most
    /// time; a tagged-but-never-claimed set falls back to the session whose coverage overlaps the
    /// set window longest.
    static func chartSession(for set: FestivalSet,
                             sessions: [FestivalSessionSnapshot],
                             attendance: [FestivalAttendanceSnapshot],
                             now: Date = .now) -> FestivalSessionSnapshot? {
        let claimed = attendance.filter { $0.setID == set.id }
        if !claimed.isEmpty {
            let bySession = Dictionary(grouping: claimed, by: \.sessionID).mapValues { rows in
                rows.reduce(0.0) { $0 + ($1.interval(now: now).intersection(with: set.window)?.duration ?? 0) }
            }
            if let best = bySession.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.uuidString > $1.key.uuidString }),
               let session = sessions.first(where: { $0.id == best.key }) {
                return session
            }
        }
        return sessions
            .filter { ($0.interval(now: now).intersection(with: set.window)?.duration ?? 0) > 0 }
            .max { a, b in
                let ai = a.interval(now: now).intersection(with: set.window)?.duration ?? 0
                let bi = b.interval(now: now).intersection(with: set.window)?.duration ?? 0
                return ai != bi ? ai < bi : a.startedAt > b.startedAt
            }
    }

    /// The peak of a (set-rebased) slice: bpm + seconds into the slice. `nil` for an empty slice.
    static func peak(of slice: [HRPoint]) -> (bpm: Double, t: Double)? {
        guard let top = slice.max(by: { $0.bpm != $1.bpm ? $0.bpm < $1.bpm : $0.t > $1.t }) else { return nil }
        return (top.bpm, top.t)
    }

    /// "peak 171 ♥ at 23:12" — the drop callout (frame 6). The peak's slice-time is mapped back to
    /// an absolute instant, then formatted festival-local.
    static func peakCallout(slice: [HRPoint], sliceStart: Date, utcOffsetSeconds: Int) -> String? {
        guard let peak = peak(of: slice) else { return nil }
        let at = sliceStart.addingTimeInterval(peak.t)
        return "peak \(Int(peak.bpm.rounded())) ♥ at "
            + FestivalSchedule.timeLabel(at, offsetSeconds: utcOffsetSeconds)
    }

    /// Mean bpm of a slice (time-weighted would over-promise on sparse band data; the plain mean is
    /// what the session summary shows too). `nil` when empty.
    static func average(of slice: [HRPoint]) -> Double? {
        guard !slice.isEmpty else { return nil }
        return slice.reduce(0) { $0 + $1.bpm } / Double(slice.count)
    }

    /// Seconds the user spent "on the floor" at this set — the sum of its attendance stretches.
    static func dancedSeconds(for setID: UUID, attendance: [FestivalAttendanceSnapshot],
                              now: Date = .now) -> TimeInterval {
        attendance.filter { $0.setID == setID }
            .reduce(0) { $0 + $1.interval(now: now).duration }
    }

    /// "1:28" (h:mm) / "42 min" — the Danced stat.
    static func dancedLabel(_ seconds: TimeInterval) -> String {
        let mins = Int((seconds / 60).rounded())
        if mins < 60 { return "\(mins) min" }
        return String(format: "%d:%02d", mins / 60, mins % 60)
    }
}

// MARK: - Recap (frame 11)

enum FestivalRecap {

    /// The weekend hero numbers.
    struct Hero: Equatable, Sendable {
        var nights: Int
        var setsSeen: Int
        var dancedSeconds: TimeInterval
        var clipCount: Int
        var peakBpm: Int?

        var nightsLine: String { "\(nights) night\(nights == 1 ? "" : "s") on the floor" }
        /// "9:42" hero-stat style (hours:minutes).
        var dancedStat: String {
            let mins = Int((dancedSeconds / 60).rounded())
            return String(format: "%d:%02d", mins / 60, mins % 60)
        }
    }

    /// One "By artist" row, ranked by YOUR heart rate at their set(s).
    struct ArtistRow: Equatable, Sendable, Identifiable {
        var setID: UUID
        var artist: String
        var stage: String
        var dayLabel: String       // "Sat"
        var clipCount: Int
        var dancedSeconds: TimeInterval
        var peakBpm: Int?
        var id: UUID { setID }
    }

    /// Everything frame 11 shows, derived in one pass. "Sets seen" = sets you claimed OR that have
    /// tagged clips (either is evidence you were there); "nights" = distinct poster days those sets
    /// fall on (rollover-aware, so a 01:00 set doesn't mint a phantom night).
    static func build(pack: FestivalPack,
                      sessions: [FestivalSessionSnapshot],
                      attendance: [FestivalAttendanceSnapshot],
                      tags: [FestivalTagSnapshot],
                      now: Date = .now) -> (hero: Hero, artists: [ArtistRow]) {
        let byID = pack.setsByID
        let seenIDs = Set(attendance.map(\.setID)).union(tags.map(\.setID))
            .filter { byID[$0] != nil }

        var rows: [ArtistRow] = []
        var peakOverall: Double = 0
        for setID in seenIDs {
            guard let set = byID[setID] else { continue }
            var peakBpm: Int?
            if let session = FestivalSetStats.chartSession(for: set, sessions: sessions,
                                                           attendance: attendance, now: now),
               let peak = FestivalSetStats.peak(of: FestivalSetStats.hrSlice(for: set, session: session,
                                                                             now: now)) {
                peakBpm = Int(peak.bpm.rounded())
                peakOverall = max(peakOverall, peak.bpm)
            }
            rows.append(ArtistRow(
                setID: setID,
                artist: set.artist,
                stage: set.stage,
                dayLabel: String(FestivalTagging.posterWeekday(
                    for: set.start, utcOffsetSeconds: pack.utcOffsetSeconds).prefix(3)),
                clipCount: tags.filter { $0.setID == setID }.count,
                dancedSeconds: FestivalSetStats.dancedSeconds(for: setID, attendance: attendance,
                                                              now: now),
                peakBpm: peakBpm))
        }
        // Ranked by peak ♥ ("who actually made you move"); un-charted sets sink, ties break by
        // danced time then artist for stability.
        rows.sort { a, b in
            let ap = a.peakBpm ?? -1, bp = b.peakBpm ?? -1
            if ap != bp { return ap > bp }
            if a.dancedSeconds != b.dancedSeconds { return a.dancedSeconds > b.dancedSeconds }
            return a.artist < b.artist
        }

        let nights = Set(seenIDs.compactMap { byID[$0].flatMap { pack.day(containing: $0.start)?.date } }).count
        let hero = Hero(
            nights: nights,
            setsSeen: seenIDs.count,
            dancedSeconds: attendance.reduce(0) { $0 + $1.interval(now: now).duration },
            clipCount: tags.count,
            peakBpm: peakOverall > 0 ? Int(peakOverall.rounded()) : nil)
        return (hero, rows)
    }
}
