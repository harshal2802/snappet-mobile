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

/// **A board climb as activity history** (prompt 189): turns one Kilter climb's logs into transient (never inserted)
/// `WorkoutSession`s — one per board session, holding one climb entity (`exerciseId` "kilter:<uuid>", V grade,
/// "Kilter Board", the angle as its wall) whose sets are the logged ascents (outcome + attempts) — with the board
/// session's heart rate, and the climb's clips re-filed to that entity. So the Activity page's Progress / Clips /
/// About (dashboard, records, effort, clips, history) work for a board climb exactly as for a gym climb, unchanged.
enum KilterActivityHistory {
    static let entityPrefix = "kilter:"

    struct SessionInput: Sendable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date?
        let title: String?
        let hrSeries: [HRPoint]
        let maxHR: Double?
        let restHR: Double?
    }

    /// The climb's uuid when `ex` is a board-climb entity built here.
    static func climbUUID(_ ex: SessionExercise) -> String? {
        ex.exerciseId.hasPrefix(entityPrefix) ? String(ex.exerciseId.dropFirst(entityPrefix.count)) : nil
    }

    static func build(climbUUID: String, logs: [LibraryCatalog.KilterInput], sessions: [SessionInput],
                      media: [ActivityMediaInput]) -> (history: [WorkoutSession], media: [ActivityMediaInput]) {
        let mine = logs.filter { $0.uuid == climbUUID }.sorted { $0.date < $1.date }
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A log outside a board session (ad-hoc) groups with the others of its active day.
        var adHoc: [Date: UUID] = [:]
        func sessionID(_ e: LibraryCatalog.KilterInput) -> UUID {
            if let id = e.sessionId, byID[id] != nil { return id }
            let day = LibraryCatalog.activeDay(e.date)
            if let id = adHoc[day] { return id }
            let id = UUID(); adHoc[day] = id
            return id
        }
        let grouped = Dictionary(grouping: mine, by: sessionID)
        var entityBySession: [UUID: UUID] = [:]
        let history: [WorkoutSession] = grouped.map { sid, entries in
            let latest = entries.last!
            var ex = SessionExercise(exerciseId: entityPrefix + climbUUID, targetSets: 0, targetReps: "",
                                     targetRestSeconds: 0, sets: [], displayName: latest.name,
                                     kindRaw: SetKind.climbAttempt.rawValue)
            ex.climbTypeRaw = ClimbType.boulder.rawValue
            ex.climbGradeLabel = LibraryCatalog.kilterVGrade(latest.gradeLabel)
            ex.climbGradeScaleRaw = GradeScale.vScale.rawValue
            ex.gym = "Kilter Board"
            ex.wall = "\(latest.angle)°"
            ex.sets = entries.map { e in
                var s = SetLog()
                s.climbGradeLabel = LibraryCatalog.kilterVGrade(e.gradeLabel)
                s.climbStatusRaw = e.status.rawValue
                s.climbAttempts = max(1, e.attempts)
                s.completedAt = e.date
                return s
            }
            entityBySession[sid] = ex.id
            let board = byID[sid]
            let start = board?.startedAt ?? entries.first!.date
            return WorkoutSession(id: sid, routineName: board?.title ?? "Kilter session", startedAt: start,
                                  completedAt: board?.endedAt ?? entries.last!.date.addingTimeInterval(60),
                                  exercises: [ex], hrSeries: board?.hrSeries ?? [], maxHR: board?.maxHR,
                                  restHR: board?.restHR)
        }
        .sorted { $0.startedAt < $1.startedAt }
        let refiled = media.compactMap { m -> ActivityMediaInput? in
            guard m.assignedClimbUUID == climbUUID, let entity = entityBySession[m.sessionID] else { return nil }
            var m = m
            m.assignedExerciseID = entity
            m.assignedSetIndex = nil
            return m
        }
        return (history, refiled)
    }
}
