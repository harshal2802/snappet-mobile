import Foundation
import SwiftData

/// The thin SwiftData / live-services edge of a festival night (prompt 232) — every place that says
/// where you are (the schedule bar, the live sheet, a set's page, the Festival home card) goes
/// through here, so they can't disagree. The decisions are the pure `FestivalNight`; this only
/// reads and writes rows and drives the dance `WorkoutSession` spine (HR, Live Activity, finish).
/// Lifted from `FestivalScheduleView`, which used to own the claim logic alone.
@MainActor
struct FestivalNightController {
    let lineup: FestivalLineup
    let pack: FestivalPack
    let context: ModelContext
    let app: AppModel
    let core: SnappetCore
    private let notifications = FestivalNotifications()

    init(lineup: FestivalLineup, pack: FestivalPack, context: ModelContext,
         app: AppModel, core: SnappetCore) {
        self.lineup = lineup
        self.pack = pack
        self.context = context
        self.app = app
        self.core = core
    }

    // MARK: Reads

    var packID: String { lineup.packID }

    func attendance() -> [FestivalAttendance] {
        let packID = packID
        return (try? context.fetch(FetchDescriptor<FestivalAttendance>(
            predicate: #Predicate { $0.packID == packID }))) ?? []
    }

    func stretches() -> [FestivalNightStretch] {
        let packID = packID
        return (try? context.fetch(FetchDescriptor<FestivalNightStretch>(
            predicate: #Predicate { $0.packID == packID }))) ?? []
    }

    func starred() -> Set<UUID> {
        let packID = packID
        return Set(((try? context.fetch(FetchDescriptor<FestivalStar>(
            predicate: #Predicate { $0.packID == packID }))) ?? []).map(\.setID))
    }

    var openAttendance: FestivalAttendance? { attendance().first { $0.isOpen } }
    var openStretch: FestivalNightStretch? { stretches().first { $0.isOpen } }

    /// The live dance session this festival's night rides: an unfinished session that one of this
    /// lineup's claims or stretches points at.
    func nightSession() -> WorkoutSession? {
        let ids = Set(attendance().map(\.sessionID)).union(stretches().map(\.sessionID))
        guard !ids.isEmpty else { return nil }
        let active = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.completedAt == nil }))) ?? []
        return active.filter { ids.contains($0.id) }.max { $0.startedAt < $1.startedAt }
    }

    func snapshot() -> FestivalNight.Snapshot {
        let session = nightSession()
        let rows = attendance().filter { $0.sessionID == session?.id }
        let gaps = stretches().filter { $0.sessionID == session?.id }
        let open = attendance().first { $0.isOpen }
        let stretch = stretches().first { $0.isOpen }
        let closed = rows.compactMap(\.endedAt) + gaps.compactMap(\.endedAt)
        return FestivalNight.Snapshot(
            nightOn: session != nil,
            openSetID: open?.setID,
            openStretch: stretch.map { ($0.kind, $0.startedAt) },
            lastClosedAt: closed.max(),
            nightStartedAt: session?.startedAt)
    }

    func status() -> FestivalNight.Status { FestivalNight.status(snapshot()) }

    // MARK: Starting

    /// "Start the night": open (or ride) the dance session before any set — you're arriving.
    func startNight(now: Date = .now) {
        startStretch(.arriving, now: now)
        core.log(module: FestivalModule.id, action: "startNight",
                 summary: "Started the night at \(lineup.name)")
    }

    /// Claim `set` from `at` (a set-end auto-move back-dates to the previous set's end). Closes
    /// whatever was open, rides the night's session or starts one, records the stretch.
    func claim(_ set: FestivalSet, at: Date = .now, autoMoved: Bool = false) {
        if let open = openAttendance {
            if open.setID == set.id { open.autoMoved = false; try? context.save(); return }
            closeAttendance(open, at: at)
        }
        if let stretch = openStretch { stretch.endedAt = at }

        let session = nightSession() ?? activeSession() ?? startDanceSession(now: at)
        appendDanceExercise(for: set, to: session)
        let row = FestivalAttendance(packID: packID, setID: set.id, artist: set.artist,
                                     stage: set.stage, sessionID: session.id, startedAt: at)
        row.autoMoved = autoMoved
        context.insert(row)
        try? context.save()
        resumeLiveServicesIfNeeded(for: session, label: set.artist)
        app.liveActivity.update(hrBpm: app.liveWorkout.latestHR.map { Int($0.rounded()) },
                                exerciseName: set.artist, setProgress: "")
        scheduleSetEnd(for: set, claimedAt: at)
        notifications.cancelNight(packID: packID, setEnd: false)
        core.log(module: FestivalModule.id, action: "attend",
                 summary: "On the floor: \(set.artist) · \(set.stage)")
    }

    /// A break / walking / arriving stretch. Starts the night if it isn't on.
    func startStretch(_ kind: FestivalNight.StretchKind, now: Date = .now) {
        if let open = openAttendance { closeAttendance(open, at: now) }
        if let stretch = openStretch {
            guard stretch.kind != kind else { return }
            stretch.endedAt = now
        }
        let session = nightSession() ?? activeSession() ?? startDanceSession(now: now)
        context.insert(FestivalNightStretch(packID: packID, sessionID: session.id, kind: kind,
                                            startedAt: now))
        try? context.save()
        resumeLiveServicesIfNeeded(for: session, label: kind.title)
        app.liveActivity.update(hrBpm: app.liveWorkout.latestHR.map { Int($0.rounded()) },
                                exerciseName: kind.title, setProgress: "")
        notifications.cancelNight(packID: packID, stillOut: false)
        notifications.scheduleStillOut(since: now, pack: pack, now: now)
    }

    /// "End this set": close the claim; the night stays on and the caller asks what's next.
    func endSet(now: Date = .now) {
        if let open = openAttendance { closeAttendance(open, at: now) }
        if let stretch = openStretch { stretch.endedAt = now }
        try? context.save()
        notifications.cancelNight(packID: packID, stillOut: false)
        notifications.scheduleStillOut(since: now, pack: pack, now: now)
    }

    /// "Not there? Got it" — confirm an auto-move.
    func confirmAutoMove() {
        openAttendance?.autoMoved = false
        try? context.save()
    }

    // MARK: Ending

    /// End the night — heading home. Closes everything and, when the session is the festival's own,
    /// finishes it exactly like the tracker does. A gym session we merely annotated stays live.
    func endNight(at end: Date = .now) {
        let session = nightSession()
        if let open = openAttendance { closeAttendance(open, at: end) }
        if let stretch = openStretch { stretch.endedAt = end }
        try? context.save()
        notifications.cancelNight(packID: packID)
        guard let session, session.isActive, isFestivalOwned(session) else { return }
        WorkoutSessionFinisher.finish(session, app: app, context: context, at: end)
        core.log(module: FestivalModule.id, action: "session",
                 summary: "Danced at \(lineup.name)", metric: Double(Int(session.duration / 60)))
        let pack = pack, packID = packID, context = context, media = app.sessionMedia
        // One tagging pass now so the review sheet and Clips are ready before the user looks.
        Task { await FestivalTagSync.refresh(pack: pack, packID: packID, context: context,
                                             mediaService: media) }
    }

    // MARK: Set end — the Halloween fix

    /// Bring the night up to date with the clock: a claim whose set has ended moves on to the next
    /// starred set (back-dated to the end) or closes and leaves the night asking. Loops, so coming
    /// back to the phone two sets later lands on the right one. A claim on a set whose session is
    /// gone (or finished) just closes. A night left quiet for hours ends itself, back-dated.
    /// Returns true when the night is now asking "Where are you now?".
    @discardableResult
    func reconcile(now: Date = .now) -> Bool {
        var changed = false
        var asking = false
        let starred = starred()
        for _ in 0..<12 {
            guard let open = openAttendance else { break }
            guard let session = session(id: open.sessionID), session.isActive else {
                closeAttendance(open, at: min(now, session(id: open.sessionID)?.completedAt ?? now))
                changed = true
                break
            }
            guard let set = pack.setsByID[open.setID],
                  FestivalNight.claimHasEnded(set: set, claimedAt: open.startedAt, now: now) else { break }
            changed = true
            switch FestivalNight.outcome(after: set, in: pack, starred: starred) {
            case .moveTo(let next):
                claim(next, at: set.end, autoMoved: true)
            case .ask:
                closeAttendance(open, at: set.end)
                asking = true
            }
            if asking { break }
        }
        // Stretches whose session ended elsewhere close with it.
        if let stretch = openStretch, session(id: stretch.sessionID)?.isActive != true {
            stretch.endedAt = session(id: stretch.sessionID)?.completedAt ?? now
            changed = true
        }
        if changed { try? context.save() }
        let status = status()
        if FestivalNight.isAbandoned(status, now: now), case .between(let since) = status {
            endNight(at: since)
            return false
        }
        if asking { notifications.scheduleStillOut(since: now, pack: pack, now: now) }
        if case .between = status { return true }
        return false
    }

    // MARK: Session helpers

    func session(id: UUID) -> WorkoutSession? {
        (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.id == id })))?.first
    }

    private func activeSession() -> WorkoutSession? {
        let all = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.completedAt == nil }))) ?? []
        return all.min { $0.startedAt > $1.startedAt }
    }

    private func startDanceSession(now: Date) -> WorkoutSession {
        let session = WorkoutSession(routineID: nil, routineName: lineup.name,
                                     startedAt: now, exercises: [])
        context.insert(session)
        app.liveWorkout.start(for: session, disciplines: [.dance], sport: nil, category: nil,
                              maxHR: app.userProfile.profile.resolvedMaxHR,
                              restHR: app.userProfile.profile.restingBound)
        app.liveActivity.start(routineName: lineup.name, startedAt: now,
                               exerciseName: "Dancing", setProgress: "",
                               maxHR: app.userProfile.profile.resolvedMaxHR)
        return session
    }

    /// After a cold relaunch nothing is streaming — restart live metrics + the Live Activity for
    /// the still-open session. Never steals a running source or re-creates a live activity.
    func resumeLiveServicesIfNeeded(for session: WorkoutSession, label: String) {
        guard session.isActive else { return }
        if !app.liveWorkout.isSessionActive {
            app.liveWorkout.start(for: session, disciplines: [.dance], sport: nil, category: nil,
                                  maxHR: app.userProfile.profile.resolvedMaxHR,
                                  restHR: app.userProfile.profile.restingBound)
        }
        if !app.liveActivity.isRunning {
            app.liveActivity.start(routineName: session.routineName, startedAt: session.startedAt,
                                   exerciseName: label, setProgress: "",
                                   maxHR: app.userProfile.profile.resolvedMaxHR)
        }
    }

    /// One dance-discipline entity per claimed set ("Fred again.. · Pyramid Stage").
    private func appendDanceExercise(for set: FestivalSet, to session: WorkoutSession) {
        var entity = SessionExercise(
            exerciseId: "festival-set", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: [], displayName: "\(set.artist) · \(set.stage)",
            kindRaw: SetKind.duration.rawValue)
        entity.disciplineRaw = WorkoutDiscipline.dance.rawValue
        session.exercises.append(entity)
    }

    /// Close a claim and log its duration onto the matching dance entity.
    private func closeAttendance(_ open: FestivalAttendance, at end: Date) {
        let end = max(open.startedAt, end)
        open.endedAt = end
        open.autoMoved = false
        guard let session = session(id: open.sessionID) else { return }
        let name = "\(open.artist) · \(open.stage)"
        if let index = session.exercises.lastIndex(where: { $0.displayName == name && $0.sets.isEmpty }) {
            session.exercises[index].sets.append(
                SetLog(completedAt: end, durationSec: end.timeIntervalSince(open.startedAt)))
        }
    }

    private func scheduleSetEnd(for set: FestivalSet, claimedAt: Date) {
        // A running-late claim (made after the scheduled end) has no end to announce.
        guard set.end > claimedAt else {
            notifications.cancelNight(packID: packID, stillOut: false)
            return
        }
        let next: FestivalSet? = switch FestivalNight.outcome(after: set, in: pack, starred: starred()) {
        case .moveTo(let n): n
        case .ask: nil
        }
        notifications.scheduleSetEnd(set, next: next, pack: pack)
    }

    /// A session the festival started (vs a gym session it annotated): routineless and every entity
    /// a festival set — empty counts too (a night started before the first set).
    private func isFestivalOwned(_ session: WorkoutSession) -> Bool {
        session.routineID == nil && session.exercises.allSatisfy { $0.exerciseId == "festival-set" }
    }
}
