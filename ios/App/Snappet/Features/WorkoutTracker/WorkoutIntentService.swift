import Foundation
import SwiftData

/// **Logging from outside the app** (prompt 199): what Shortcuts / Siri / the Action button / another app's
/// automation — and `snappet://log…` links — do to the store. Logs land in the RUNNING session (a Quick Session is
/// started when none is), on the activity's entity in it (added, set up as last time, when it isn't there yet) — the
/// same entity "Log it now" and the pickers create. Main-actor, on the app's own `ModelContext`, so an open player
/// sees the set immediately.
@MainActor
enum WorkoutIntentService {

    struct Outcome: Equatable {
        /// What happened, in a sentence ("Logged 8 × 75 kg on Bench Press.").
        let message: String
        let startedSession: Bool
    }

    enum Failure: Error, Equatable {
        case unknownActivity(String)
        case notAClimb(String)
        case nothingToLog
    }

    // MARK: Activities

    /// Your activities, most used first — what a Shortcuts picker offers (and what a typed name is matched against).
    static func activities(in context: ModelContext, unit: WeightUnit = .kg) -> [LibraryCatalog.Row] {
        let history = sessions(in: context)
        let identity = ActivityIdentity(sessions: history)
        let entries = (try? context.fetch(FetchDescriptor<LibraryEntry>())) ?? []
        let created: [LibraryCatalog.CreatedInput] = entries.compactMap { e in
            guard let key = e.key, let t = e.template else { return nil }
            return .init(key: key, template: t, createdAt: e.createdAt ?? e.updatedAt)
        }
        let hidden = Set(entries.filter(\.isHidden).compactMap(\.key))
        let rows = LibraryCatalog.yours(history: history, identity: identity, unit: unit, created: created,
                                        title: LibraryCatalog.fallbackTitle)
        return LibraryPick.rows(rows, hidden: hidden, query: "", discipline: nil)
    }

    /// A typed or picked activity → its row: the key's raw id, else an exact title, else a title containing it.
    static func resolve(_ query: String, in rows: [LibraryCatalog.Row]) -> LibraryCatalog.Row? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let key = LibraryEntry.key(q), let row = rows.first(where: { $0.key == key }) { return row }
        if let row = rows.first(where: { $0.title.localizedCaseInsensitiveCompare(q) == .orderedSame }) { return row }
        return rows.first { $0.title.localizedStandardContains(q) }
    }

    // MARK: Logging

    /// Log a set (reps × weight, or a duration / distance) on an activity. Missing numbers repeat the activity's
    /// last set — "log a set of bench" logs what you did last time.
    static func logSet(activity: String, reps: Int? = nil, weight: Double? = nil, unit: WeightUnit? = nil,
                       seconds: Double? = nil, meters: Double? = nil, in context: ModelContext,
                       now: Date = .now) throws -> Outcome {
        let rows = activities(in: context)
        guard let row = resolve(activity, in: rows) else { throw Failure.unknownActivity(activity) }
        let (session, entityIndex, started) = try entity(for: row, in: context, now: now)
        let ex = session.exercises[entityIndex]
        let last = lastSet(of: row.key, in: context)
        guard let set = IntentSetBuilder.set(kind: ex.kind, discipline: ex.discipline, reps: reps, weight: weight,
                                             unit: unit ?? last?.weightUnit ?? .kg, seconds: seconds, meters: meters,
                                             last: last, now: now) else { throw Failure.nothingToLog }
        session.exercises[entityIndex].sets.append(set)
        try? context.save()
        // Worded the way the player's ledger shows it ("5 × 82.5 kg"), so the dialog matches what you'll see.
        let shown = set.weightUnit ?? .kg
        let summary = ex.kind == .repsWeight && ex.discipline != .run
            ? SetMeasure.summary(set, kind: .repsWeight, unit: shown)
            : SetMeasure.displaySummary(set, discipline: ex.discipline, kind: ex.kind, unit: shown,
                                        distanceUnit: shown == .lb ? .mi : .km)
        return Outcome(message: "Logged \(summary) on \(row.title).", startedSession: started)
    }

    /// Log a climb attempt with its outcome.
    static func logAttempt(climb: String, outcome: KilterAscentStatus, seconds: Double? = nil,
                           in context: ModelContext, now: Date = .now) throws -> Outcome {
        let rows = activities(in: context).filter { $0.discipline == .climb }
        guard let row = resolve(climb, in: rows) else {
            if resolve(climb, in: activities(in: context)) != nil { throw Failure.notAClimb(climb) }
            throw Failure.unknownActivity(climb)
        }
        let (session, i, started) = try entity(for: row, in: context, now: now)
        var set = SetLog(durationSec: (seconds ?? 0) > 0 ? seconds : nil,
                         climbGradeLabel: session.exercises[i].climbGradeLabel,
                         climbStatusRaw: outcome.rawValue, climbAttempts: 1)
        set.completedAt = now
        session.exercises[i].sets.append(set)
        try? context.save()
        let label = session.exercises[i].climbType.statusLabel(outcome)
        return Outcome(message: "Logged an attempt on \(row.title) — \(label).", startedSession: started)
    }

    // MARK: Helpers

    static func runningSession(in context: ModelContext) -> WorkoutSession? {
        (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.completedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])))?.first
    }

    private static func sessions(in context: ModelContext) -> [WorkoutSession] {
        (try? context.fetch(FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? []
    }

    /// The running session (or a new Quick Session) and the index of the activity's entity in it (added when absent).
    private static func entity(for row: LibraryCatalog.Row, in context: ModelContext,
                               now: Date) throws -> (WorkoutSession, Int, Bool) {
        var started = false
        let session: WorkoutSession
        if let running = runningSession(in: context) {
            session = running
        } else {
            session = WorkoutSession(routineID: nil, routineName: "Quick session", startedAt: now)
            context.insert(session)
            started = true
        }
        let history = sessions(in: context)
        let identity = ActivityIdentity(sessions: history)
        if let i = session.exercises.lastIndex(where: { identity.matches(row.key, $0) }) { return (session, i, started) }
        let template = LibraryEntry.entry(for: row.key, in: context, create: false)?.template
        guard let fresh = ActivityLauncher.sessionExercise(for: row.key, history: history.filter { !$0.isActive },
                                                           identity: identity, template: template)
        else { throw Failure.unknownActivity(row.title) }
        session.exercises.append(fresh)
        return (session, session.exercises.count - 1, started)
    }

    /// The activity's most recent completed set — what "log a set" repeats when numbers are missing.
    private static func lastSet(of key: ActivityKey, in context: ModelContext) -> SetLog? {
        let history = sessions(in: context)
        let identity = ActivityIdentity(sessions: history)
        for s in history {
            for ex in s.exercises.reversed() where identity.matches(key, ex) {
                if let set = ex.sets.last(where: { $0.completedAt != nil }) { return set }
            }
        }
        return nil
    }
}

/// The set a "Log a set" request becomes (prompt 199). Pure.
enum IntentSetBuilder {
    /// Reps × weight for a lift, a duration for a hold / run / other (with a run's distance); the activity's last set
    /// fills what wasn't given. `nil` when there's nothing to log (no numbers and no last set).
    static func set(kind: SetKind, discipline: WorkoutDiscipline, reps: Int?, weight: Double?, unit: WeightUnit,
                    seconds: Double?, meters: Double?, last: SetLog?, now: Date) -> SetLog? {
        var set: SetLog
        switch kind {
        case .repsWeight:
            let r = reps ?? last?.actualReps
            let w = weight ?? last?.actualWeight
            guard r != nil || w != nil else { return nil }
            set = SetLog(actualReps: r, actualWeight: (w ?? 0) > 0 ? w : nil, weightUnit: unit,
                         durationSec: (seconds ?? 0) > 0 ? seconds : nil)
        case .duration:
            let d = seconds ?? last?.durationSec
            let m = meters ?? (discipline == .run ? last?.distanceMeters : nil)
            guard (d ?? 0) > 0 || (m ?? 0) > 0 else { return nil }
            set = SetLog(durationSec: d)
            set.distanceMeters = m
        case .climbAttempt:
            set = SetLog(durationSec: (seconds ?? 0) > 0 ? seconds : nil, climbStatusRaw: KilterAscentStatus.attempt.rawValue,
                         climbAttempts: 1)
        }
        set.completedAt = now
        return set
    }
}

/// **`snappet://` workout links** (prompt 199) — the same actions as the App Intents, for another app, an NFC tag on
/// the gym wall, or a Shortcuts "Open URL":
/// `snappet://quick[?activity=Bench Press]` · `snappet://finish` ·
/// `snappet://log?activity=Bench Press&reps=8&weight=75[&unit=kg][&seconds=42][&meters=5000]` ·
/// `snappet://attempt?climb=Blue arete&outcome=sent`. Pure parse.
enum WorkoutLinkAction: Equatable, Sendable {
    case quick(activity: String?)
    case finish
    case log(activity: String, reps: Int?, weight: Double?, unit: WeightUnit?, seconds: Double?, meters: Double?)
    case attempt(climb: String, outcome: KilterAscentStatus)

    init?(url: URL) {
        guard let c = URLComponents(url: SnappetWebLink.appForm(url), resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "snappet",
              let host = c.host?.lowercased() else { return nil }
        let q = Dictionary((c.queryItems ?? []).compactMap { i in i.value.map { (i.name.lowercased(), $0) } },
                           uniquingKeysWith: { a, _ in a })
        switch host {
        case "quick":
            self = .quick(activity: q["activity"].flatMap { $0.isEmpty ? nil : $0 })
        case "finish":
            self = .finish
        case "log":
            guard let a = q["activity"], !a.isEmpty else { return nil }
            self = .log(activity: a, reps: q["reps"].flatMap(Int.init), weight: q["weight"].flatMap(Double.init),
                        unit: q["unit"].flatMap { WeightUnit(rawValue: $0.lowercased()) },
                        seconds: q["seconds"].flatMap(Double.init), meters: q["meters"].flatMap(Double.init))
        case "attempt":
            guard let climb = q["climb"], !climb.isEmpty else { return nil }
            let outcome: KilterAscentStatus
            switch q["outcome"]?.lowercased() {
            case "sent", "send": outcome = .sent
            case "flash": outcome = .flash
            case "project": outcome = .project
            default: outcome = .attempt
            }
            self = .attempt(climb: climb, outcome: outcome)
        default:
            return nil
        }
    }
}
