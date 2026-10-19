import Foundation

/// The identity of an **activity** across sessions (activity progress P1, prompt 178): "Bench Press",
/// or the named climb "Blue crimp roof", or the timed exercise "Max hangs". A `SessionExercise.id` is
/// per-session, so cross-session identity is the catalog `exerciseId` — plus, for ad-hoc entities
/// (`adhoc-*`, whose id is shared by every climb / timed exercise / run), the normalized display name.
/// The same rule `QuickSessionPager.lastSessionSets` uses, with the name compared case- and
/// whitespace-insensitively so "Blue crimp" and "blue crimp " are one climb.
struct ActivityKey: Hashable, Sendable {
    let exerciseId: String
    /// Normalized display name for an ad-hoc entity; `""` for a catalog / custom exercise.
    let nameKey: String

    /// A NON-climb entity's activity, or `nil` when it has no cross-session identity — an UNNAMED ad-hoc entity.
    /// Climbs return `nil` here on purpose: a climb's identity depends on history (gyms reset — the set window), so
    /// it only comes from `ActivityIdentity` (prompt 183). Use `ActivityIdentity.key(for:)` everywhere.
    /// Festival sets likewise: they're keyed per festival, which needs the session (prompt 183 follow-up).
    static func plain(_ ex: SessionExercise) -> ActivityKey? {
        guard ex.discipline != .climb, ex.exerciseId != ActivityIdentity.festivalExerciseId else { return nil }
        let name = normalize(ex.displayName ?? "")
        if ex.exerciseId.hasPrefix("adhoc-") {
            guard !name.isEmpty else { return nil }
            return ActivityKey(exerciseId: ex.exerciseId, nameKey: name)
        }
        return ActivityKey(exerciseId: ex.exerciseId, nameKey: "")
    }

    /// A whole DISCIPLINE as one activity ("Climbing", "Running" — prompt 181): matches every entity of it.
    static func discipline(_ d: WorkoutDiscipline) -> ActivityKey {
        ActivityKey(exerciseId: disciplinePrefix + d.rawValue, nameKey: "")
    }

    private static let disciplinePrefix = "discipline:"

    /// The discipline this key spans, or `nil` for a single activity.
    var disciplineScope: WorkoutDiscipline? {
        guard exerciseId.hasPrefix(Self.disciplinePrefix) else { return nil }
        return WorkoutDiscipline(rawValue: String(exerciseId.dropFirst(Self.disciplinePrefix.count)))
    }

    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased()
    }
}

/// A value snapshot of a `SessionMedia` row — what the index needs, nothing SwiftData, so the join is
/// unit-testable without a container (the `SessionMediaAssignment.ClipInput` precedent).
struct ActivityMediaInput: Sendable, Equatable {
    var id: UUID
    var sessionID: UUID
    var assignedExerciseID: UUID?
    var assignedSetIndex: Int?
    var kindRaw: String
    var offsetSec: Double
    var durationSec: Double?
    var localIdentifier: String
    /// A posted highlight reel is rendered OUTPUT, never a clip of one set — excluded.
    var isReel: Bool = false
    /// A Studio-baked clip carries its HR tile in the pixels — the viewer must not draw another.
    var isBaked: Bool = false
    /// The Kilter board climb it's filed to (prompt 188) — board clips are filed by climb, not exercise.
    var assignedClimbUUID: String? = nil
}

/// One clip of an activity, stamped with the set it was filmed during and the heart rate around it —
/// the numbers are what turn footage into progress evidence.
struct ActivityClip: Identifiable, Sendable, Equatable {
    let media: ActivityMediaInput
    let sessionID: UUID
    let sessionDate: Date
    /// The set/attempt index in its exercise (`nil` = filed to the exercise as a whole).
    let setIndex: Int?
    /// The set's one-line summary ("75 kg × 8", "0:42", "V5 · Sent"); `nil` when not tied to a set.
    let setSummary: String?
    /// Average BPM over the clip's window (video) or around its instant (photo); `nil` without HR.
    let avgBPM: Int?
    var id: UUID { media.id }
}

/// One session's clips of an activity — the History sheet's section.
struct ActivitySessionGroup: Identifiable, Sendable, Equatable {
    let sessionID: UUID
    let date: Date
    let title: String
    let clips: [ActivityClip]
    var id: UUID { sessionID }
}

/// **Pure** cross-session join (activity progress P1): history + media snapshots → every clip ever
/// tagged to an activity, grouped by session, newest first. Foundation only — no SwiftData, Photos or
/// UI — so it runs in `SnappetTests` with no device.
enum ActivityMediaIndex {

    /// Seconds either side of a photo's instant that count as "its" heart rate.
    static let photoHRWindowSec: Double = 10

    /// Every activity's clip count across `history`, skipping `excludingSession` (the live session —
    /// its own clips are already on the page's media shelf). Feeds the pager's "▶ N past clips" chip.
    static func counts(history: [WorkoutSession], media: [ActivityMediaInput],
                       excludingSession: UUID? = nil, identity: ActivityIdentity? = nil) -> [ActivityKey: Int] {
        let keys = entityKeys(history: history, excludingSession: excludingSession,
                              identity: identity ?? ActivityIdentity(sessions: history))
        var out: [ActivityKey: Int] = [:]
        for m in media where !m.isReel {
            guard let exID = m.assignedExerciseID, let key = keys[EntityRef(sessionID: m.sessionID, exerciseID: exID)]
            else { continue }
            out[key, default: 0] += 1
        }
        return out
    }

    /// The activity's clips grouped by session, newest session first; clips inside a session in capture
    /// order. Sessions with no clip of the activity are omitted.
    static func groups(for key: ActivityKey, history: [WorkoutSession], media: [ActivityMediaInput],
                       excludingSession: UUID? = nil, unit: WeightUnit,
                       distanceUnit: DistanceUnit, identity: ActivityIdentity? = nil) -> [ActivitySessionGroup] {
        let ids = identity ?? ActivityIdentity(sessions: history)
        let byMedia = Dictionary(grouping: media.filter { !$0.isReel && $0.assignedExerciseID != nil },
                                 by: \.sessionID)
        var groups: [ActivitySessionGroup] = []
        for session in history where session.id != excludingSession {
            guard let rows = byMedia[session.id] else { continue }
            let entities = session.exercises.filter { ids.matches(key, $0) }
            guard !entities.isEmpty else { continue }
            let entityByID = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let clips: [ActivityClip] = rows
                .compactMap { m -> ActivityClip? in
                    guard let exID = m.assignedExerciseID, let ex = entityByID[exID] else { return nil }
                    let set = m.assignedSetIndex.flatMap { ex.sets.indices.contains($0) ? ex.sets[$0] : nil }
                    return ActivityClip(
                        media: m, sessionID: session.id, sessionDate: session.startedAt,
                        setIndex: set == nil ? nil : m.assignedSetIndex,
                        setSummary: set.map { summary($0, of: ex, unit: unit, distanceUnit: distanceUnit) },
                        avgBPM: averageBPM(for: m, hrSeries: session.hrSeries))
                }
                .sorted { $0.media.offsetSec < $1.media.offsetSec }
            guard !clips.isEmpty else { continue }
            groups.append(ActivitySessionGroup(sessionID: session.id, date: session.startedAt,
                                               title: session.routineName, clips: clips))
        }
        return groups.sorted { $0.date > $1.date }
    }

    /// Clips in the General bucket (no exercise) of the sessions that DID include the activity — the
    /// "these might be yours too, tag them" nudge. Reels excluded.
    static func untaggedCount(for key: ActivityKey, history: [WorkoutSession], media: [ActivityMediaInput],
                              excludingSession: UUID? = nil, identity: ActivityIdentity? = nil) -> Int {
        let ids = identity ?? ActivityIdentity(sessions: history)
        let sessionIDs = Set(history.filter { s in
            s.id != excludingSession && s.exercises.contains { ids.matches(key, $0) }
        }.map(\.id))
        return media.filter { !$0.isReel && $0.assignedExerciseID == nil && sessionIDs.contains($0.sessionID) }.count
    }

    /// Mean BPM over a clip: a video's `[offset, offset + duration]`, a photo's `± photoHRWindowSec`.
    /// `nil` when no HR sample falls inside.
    static func averageBPM(for m: ActivityMediaInput, hrSeries: [HRPoint]) -> Int? {
        let (start, end): (Double, Double) = m.kindRaw == "video"
            ? (m.offsetSec, m.offsetSec + max(1, m.durationSec ?? 1))
            : (m.offsetSec - photoHRWindowSec, m.offsetSec + photoHRWindowSec)
        let inWindow = hrSeries.filter { $0.t >= start && $0.t <= end }.map(\.bpm)
        guard !inWindow.isEmpty else { return nil }
        return Int((inWindow.reduce(0, +) / Double(inWindow.count)).rounded())
    }

    // MARK: - Private

    private struct EntityRef: Hashable { let sessionID: UUID; let exerciseID: UUID }

    private static func entityKeys(history: [WorkoutSession], excludingSession: UUID?,
                                   identity: ActivityIdentity) -> [EntityRef: ActivityKey] {
        var out: [EntityRef: ActivityKey] = [:]
        for session in history where session.id != excludingSession {
            for ex in session.exercises {
                if let key = identity.key(for: ex, loggedAt: session.startedAt) { out[EntityRef(sessionID: session.id, exerciseID: ex.id)] = key }
            }
        }
        return out
    }

    /// The set's stamp. A climb attempt carries its grade too ("V5 · Sent") — across sessions the grade is
    /// part of the story, unlike the live card where it sits once in the header.
    private static func summary(_ set: SetLog, of ex: SessionExercise, unit: WeightUnit,
                                distanceUnit: DistanceUnit) -> String {
        if ex.kind == .climbAttempt {
            let row = SetMeasure.attemptRow(set, type: ex.climbType)
            let grade = set.climbGradeLabel ?? ex.climbGradeLabel
            guard let grade, !grade.isEmpty else { return row }
            return row == "—" ? grade : "\(grade) · \(row)"
        }
        return SetMeasure.displaySummary(set, discipline: ex.discipline, kind: ex.kind,
                                         unit: unit, distanceUnit: distanceUnit)
    }
}
