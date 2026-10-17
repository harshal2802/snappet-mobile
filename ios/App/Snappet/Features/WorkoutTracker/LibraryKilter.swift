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
