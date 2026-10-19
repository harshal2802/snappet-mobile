import Foundation

/// **Kilter board climbs in Yours** (Library redesign L4c, prompt 188; wireframe decision 4 B): every board climb
/// you've logged in the Kilter module shows in the Library's Yours as a climb row with a KILTER badge — its V grade,
/// the angle you last climbed it at, attempts, best outcome, and how often — so Climbing covers the board too.
/// One row per board climb (the Kilter catalog's uuid is already a stable identity; boards don't reset). Pure, built
/// from snapshots of `KilterLogEntry` so it's unit-tested without a device; tapping a row opens the climb in the
/// Kilter module (the `pendingKilterClimb` jump), and board climbs aren't offered by the session/routine pickers.
extension LibraryCatalog {

    static let kilterExerciseId = "kilter"

    /// One logged ascent, snapshotted from `KilterLogEntry`.
    struct KilterInput: Sendable {
        let uuid: String
        let name: String
        let angle: Int
        let gradeLabel: String
        let status: KilterAscentStatus
        let attempts: Int
        let date: Date
        let sessionId: UUID?
    }

    static func isKilter(_ key: ActivityKey) -> Bool { key.exerciseId == kilterExerciseId }

    /// The V part of a Kilter grade label ("6c/V5" → "V5"); the label itself when it has none.
    static func kilterVGrade(_ label: String) -> String {
        label.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("V") }
            ?? label
    }

    static func kilterRows(_ logs: [KilterInput], now: Date = .now) -> [Row] {
        let recentCutoff = now.addingTimeInterval(-Double(recentWindowDays) * 86_400)
        let rank: (KilterAscentStatus) -> Int = {
            switch $0 { case .flash: return 3; case .sent: return 2; case .project: return 1; case .attempt: return 0 }
        }
        return Dictionary(grouping: logs, by: \.uuid).compactMap { uuid, entries -> Row? in
            guard let latest = entries.max(by: { $0.date < $1.date }),
                  let first = entries.min(by: { $0.date < $1.date }) else { return nil }
            // A session is the board session it was logged in; an ad-hoc log counts by its day.
            func sessionKey(_ e: KilterInput) -> String {
                e.sessionId?.uuidString ?? "day-\(activeDay(e.date).timeIntervalSince1970)"
            }
            let recent = entries.filter { $0.date >= recentCutoff }
            let attempts = entries.reduce(0) { $0 + max(1, $1.attempts) }
            let grade = kilterVGrade(latest.gradeLabel)
            let best = entries.map(\.status).max { rank($0) < rank($1) }
            let climb = Row.Climb(type: .boulder, grade: grade, status: best, attempts: attempts, gym: nil, wall: nil,
                                  setStart: first.date, isReset: false, angle: latest.angle)
            return Row(key: ActivityKey(exerciseId: kilterExerciseId, nameKey: uuid), title: latest.name,
                       discipline: .climb, sessions: Set(entries.map(sessionKey)).count,
                       days: Set(entries.map { activeDay($0.date) }).count,
                       recentDays: Set(recent.map { activeDay($0.date) }).count,
                       efforts: attempts, recentSessions: Set(recent.map(sessionKey)).count, lastDate: latest.date,
                       headline: grade, bestValue: GradeScale.vScale.difficulty(for: grade), climb: climb)
        }
    }
}

/// A board climb opened from the Library (prompt 188).
struct LibraryKilterRoute: Hashable { let uuid: String }

/// **Every clip of one board climb** (prompt 188, device feedback "how can I see all clips for Kilter climbs?"): the
/// Kilter counterpart of `ActivityMediaIndex.groups` — media filed to the climb (`assignedClimbUUID`) across board
/// sessions, newest session first, each clip stamped with how that session went on it ("V5 · Sent", the angle on the
/// session header) and the
/// heart rate around it. Feeds the same Clips sheet (viewer, Compare, Progress reel) the gym activities use.
enum KilterClipIndex {
    struct SessionInput: Sendable {
        let id: UUID
        let startedAt: Date
        let title: String?
        let hrSeries: [HRPoint]
    }

    static func groups(climbUUID: String, media: [ActivityMediaInput], sessions: [SessionInput],
                       logs: [LibraryCatalog.KilterInput]) -> [ActivitySessionGroup] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = media.filter { $0.assignedClimbUUID == climbUUID && !$0.isReel }
        let rank: (KilterAscentStatus) -> Int = {
            switch $0 { case .flash: return 3; case .sent: return 2; case .project: return 1; case .attempt: return 0 }
        }
        return Dictionary(grouping: mine, by: \.sessionID).compactMap { sid, clips -> ActivitySessionGroup? in
            guard let session = byID[sid] else { return nil }
            let entries = logs.filter { $0.uuid == climbUUID && $0.sessionId == sid }
            // The tile stamp is short ("V5 · Sent" — a 76 pt tile); the angle rides on the session header.
            let best = entries.max { rank($0.status) < rank($1.status) }
            let summary = best.map { "\(LibraryCatalog.kilterVGrade($0.gradeLabel)) · \($0.status.label)" }
            let stamped = clips.sorted { $0.offsetSec < $1.offsetSec }.map { m in
                ActivityClip(media: m, sessionID: sid, sessionDate: session.startedAt, setIndex: nil,
                             setSummary: summary,
                             avgBPM: ActivityMediaIndex.averageBPM(for: m, hrSeries: session.hrSeries))
            }
            return ActivitySessionGroup(sessionID: sid, date: session.startedAt,
                                        title: [session.title ?? "Kilter session", best.map { "\($0.angle)°" }]
                                            .compactMap { $0 }.joined(separator: " · "),
                                        clips: stamped)
        }
        .sorted { $0.date > $1.date }
    }
}
