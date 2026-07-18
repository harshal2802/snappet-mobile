import SwiftUI
import SwiftData

/// The installed festival's day schedule (wireframe frame 4): day tabs, stage-grouped set rows with
/// past / **NOW** / upcoming state, ★ stars (the plan), ⚠︎ clash marks, and the one CTA — **I'm
/// here** — which starts (or annotates) a dance-discipline `WorkoutSession` and opens the live
/// sheet. All derivation is the pure `FestivalSchedule`; this view renders values and owns the thin
/// SwiftData / live-services edge (the `WorkoutHomeView` lifecycle precedent).
struct FestivalScheduleView: View {
    let lineup: FestivalLineup

    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Environment(AppModel.self) private var app

    @Query private var stars: [FestivalStar]
    @Query private var attendance: [FestivalAttendance]

    @State private var pack: FestivalPack?
    @State private var selectedDay: String?
    @State private var showingLive = false
    @State private var showingForYou = false
    /// The dance session the open attendance rides — resolved when the sheet opens/claims.
    @State private var liveSession: WorkoutSession?
    /// Tag review sheet (festival prompt 03). The recap is a value-typed push (`FestivalRecapRoute`)
    /// — the `WeeklyReelRoute` pattern; an `isPresented` destination on this often-invalidated
    /// view (30 s TimelineView + @Query writes) failed to push under XCUITest.
    @State private var showingReview = false

    @AppStorage(FestivalNotifications.leadStorageKey)
    private var leadMinutes = FestivalNotifications.defaultLeadMinutes
    private let notifications = FestivalNotifications()

    init(lineup: FestivalLineup) {
        self.lineup = lineup
        let packID = lineup.packID
        _stars = Query(filter: #Predicate<FestivalStar> { $0.packID == packID })
        _attendance = Query(filter: #Predicate<FestivalAttendance> { $0.packID == packID })
    }

    private var starredIDs: Set<UUID> { Set(stars.map(\.setID)) }
    private var openAttendance: FestivalAttendance? { attendance.first { $0.isOpen } }

    var body: some View {
        Group {
            if let pack {
                // 30 s cadence keeps NOW/countdowns honest without per-second re-renders of the list.
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    schedule(pack: pack, now: timeline.date)
                }
            } else {
                ContentUnavailableView("This lineup couldn't be read",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("Remove it and install the festival again."))
            }
        }
        .navigationTitle(lineup.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Prompt 04's For-You entry.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingForYou = true
                } label: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(SnappetColor.festival)
                }
                .accessibilityLabel("For you")
                .accessibilityIdentifier("festival.forYou")
            }
            // Prompt 03's two payoff entries: the tag-review sheet and the recap push.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingReview = true
                } label: {
                    Label("Review tags", systemImage: "sparkles.rectangle.stack")
                }
                .accessibilityIdentifier("festival.reviewTags")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: FestivalRecapRoute()) {
                    Label("Recap", systemImage: "chart.bar")
                }
                .accessibilityIdentifier("festival.recap")
            }
        }
        .task {
            guard pack == nil else { return }
            pack = lineup.pack()
            if let pack, selectedDay == nil {
                selectedDay = FestivalSchedule.defaultDayDate(in: pack, now: .now)
            }
            // Bring pending reminders in line with the stored plan (a star toggled last session, or
            // this lineup was reinstalled). Silent — no permission prompt here (festival prompt 04).
            if let pack { rescheduleReminders(pack: pack) }
            // One silent tagging pass on arrival (festival prompt 03): retroactive — everything
            // already danced/filmed tags itself the first time this screen opens after a night.
            if let pack {
                await FestivalTagSync.refresh(pack: pack, packID: lineup.packID, context: context,
                                              mediaService: app.sessionMedia)
            }
        }
        // A set row pushes its detail (frame 6); recap's artist rows reuse the same registration.
        .navigationDestination(for: FestivalSet.self) { set in
            if let pack {
                FestivalSetDetailView(lineup: lineup, pack: pack, set: set)
            }
        }
        .navigationDestination(for: FestivalRecapRoute.self) { _ in
            if let pack {
                FestivalRecapView(lineup: lineup, pack: pack)
            }
        }
        .sheet(isPresented: $showingReview) {
            if let pack {
                FestivalTagReviewView(lineup: lineup, pack: pack, initialDay: selectedDay)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showingLive) {
            if let pack, let open = openAttendance {
                FestivalLiveSheet(pack: pack,
                                  attendance: open,
                                  session: liveSession,
                                  onSwitch: { set in claim(set, in: pack) },
                                  onEnd: { endNight(in: pack) })
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showingForYou) {
            if let pack {
                FestivalForYouView(lineup: lineup, pack: pack)
            }
        }
    }

    // MARK: - Schedule

    private func schedule(pack: FestivalPack, now: Date) -> some View {
        VStack(spacing: 0) {
            dayTabs(pack: pack)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(FestivalSchedule.stageGroups(for: selectedDay ?? "", in: pack,
                                                         starred: starredIDs, now: now)) { group in
                        stageSection(group, pack: pack)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
        }
        .safeAreaInset(edge: .bottom) { imHereBar(pack: pack, now: now) }
    }

    private func dayTabs(pack: FestivalPack) -> some View {
        HStack(spacing: 8) {
            ForEach(FestivalSchedule.dayTabs(for: pack)) { tab in
                let on = tab.date == selectedDay
                Button {
                    selectedDay = tab.date
                } label: {
                    VStack(spacing: 1) {
                        Text(tab.weekday).font(.caption2.weight(.bold))
                            .foregroundStyle(on ? .white : SnappetColor.textSecondary)
                        Text(tab.dayNumber).font(.headline)
                            .foregroundStyle(on ? .white : SnappetColor.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(on ? AnyShapeStyle(SnappetColor.festival)
                                   : AnyShapeStyle(SnappetColor.surfaceMuted),
                                in: RoundedRectangle(cornerRadius: SnappetRadius.md))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("festival.day.\(tab.date)")
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func stageSection(_ group: FestivalSchedule.StageGroup, pack: FestivalPack) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(group.stage.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(SnappetColor.textSecondary)
                .kerning(1)
            ForEach(group.rows) { row in
                setRow(row, pack: pack)
            }
        }
    }

    /// One set row. NOT collapsed into a single accessibility element and no identifier on the
    /// container — a container id flattens the child ★ button out of the XCUITest tree (the
    /// highlights-P5 gotcha); the star carries its own id instead.
    private func setRow(_ row: FestivalSchedule.Row, pack: FestivalPack) -> some View {
        HStack(spacing: 10) {
            // The time/artist area pushes SET DETAIL (frame 6, prompt 03) — a NavigationLink
            // around just this area, NOT the whole row, so the ★ button beside it keeps its own
            // hit target (and its own XCUITest id — the container-id gotcha).
            NavigationLink(value: row.set) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(FestivalSchedule.timeLabel(row.set.start, offsetSeconds: pack.utcOffsetSeconds))
                        Text(FestivalSchedule.timeLabel(row.set.end, offsetSeconds: pack.utcOffsetSeconds))
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .frame(width: 44, alignment: .leading)

                    Text(row.set.artist)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(row.state == .past ? SnappetColor.textSecondary : SnappetColor.ink)

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("festival.set.\(row.set.artist)")

            badges(for: row)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: SnappetRadius.md)
                .fill(row.isNow ? SnappetColor.festival.opacity(0.14) : Color.clear)
                .background(SnappetColor.surface,
                            in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SnappetRadius.md)
                .strokeBorder(row.isNow ? SnappetColor.festival : SnappetColor.hairline,
                              lineWidth: row.isNow ? 1.5 : 1)
        )
    }

    @ViewBuilder private func badges(for row: FestivalSchedule.Row) -> some View {
        if case .now(let remaining) = row.state {
            Text("NOW · \(FestivalSchedule.remainingLabel(remaining))")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(SnappetColor.festival, in: Capsule())
                .foregroundStyle(.white)
        } else if case .upcoming(let startsIn) = row.state,
                  let label = FestivalSchedule.startsInLabel(startsIn) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SnappetColor.textSecondary)
        }
        if row.clashing {
            Text("⚠︎ clash")
                .font(.caption2.weight(.bold))
                .foregroundStyle(SnappetColor.perfModerate)
                .accessibilityIdentifier("festival.clash.\(row.set.artist)")
        }
        Button {
            toggleStar(row.set)
        } label: {
            Image(systemName: row.starred ? "star.fill" : "star")
                .font(.subheadline)
                .foregroundStyle(row.starred ? SnappetColor.festival : SnappetColor.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.starred ? "Unstar \(row.set.artist)" : "Star \(row.set.artist)")
        .accessibilityIdentifier("festival.star.\(row.set.artist)")
    }

    /// The one CTA (frame 4): **I'm here — <artist>** while a set plays; **On the floor** re-opens
    /// the live sheet once claimed. Hidden between sets — there's nothing to claim.
    @ViewBuilder private func imHereBar(pack: FestivalPack, now: Date) -> some View {
        if let open = openAttendance {
            Button {
                reopenLive(open)
            } label: {
                Label("On the floor — \(open.artist)", systemImage: "waveform")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.festival)
            .padding(.horizontal).padding(.bottom, 6)
            .accessibilityIdentifier("festival.imHere")
        } else if let live = FestivalSchedule.liveSet(in: pack, starred: starredIDs, now: now) {
            Button {
                claim(live, in: pack)
                showingLive = true
            } label: {
                Label("I'm here — \(live.artist)", systemImage: "smallcircle.filled.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.festival)
            .padding(.horizontal).padding(.bottom, 6)
            .accessibilityIdentifier("festival.imHere")
        }
    }

    // MARK: - Stars

    private func toggleStar(_ set: FestivalSet) {
        let adding = !stars.contains { $0.setID == set.id }
        if let existing = stars.first(where: { $0.setID == set.id }) {
            context.delete(existing)
        } else {
            context.insert(FestivalStar(packID: lineup.packID, setID: set.id))
            core.log(module: FestivalModule.id, action: "star",
                     summary: "Starred \(set.artist) at \(lineup.name)")
        }
        try? context.save()

        guard let pack else { return }
        let newStarred = adding ? starredIDs.union([set.id]) : starredIDs.subtracting([set.id])
        // Surface a clash to the lock screen the moment the new star overlaps an existing one
        // (frame 7's "Two stars clash at 23:30"). Only when adding — unstarring can only clear a
        // clash. The in-app ⚠︎ marks (prompt 02) already flag both rows.
        if adding, let clash = FestivalPlan(starredSetIDs: newStarred)
            .clashes(in: pack).first(where: { $0.first.id == set.id || $0.second.id == set.id }) {
            notifications.postClashAlert(clash, pack: pack)
        }
        rescheduleReminders(pack: pack, starred: newStarred)
    }

    /// Bring pending local reminders in line with the current (or just-changed) plan. Silent — the
    /// permission prompt is owned by the For-You sheet, a deliberate surface.
    private func rescheduleReminders(pack: FestivalPack, starred: Set<UUID>? = nil) {
        notifications.reschedule(plan: FestivalPlan(starredSetIDs: starred ?? starredIDs),
                                 pack: pack, leadMinutes: leadMinutes)
    }

    // MARK: - The dance-session spine ("I'm here")

    /// Claim `set`: close any other open claim, ride the active `WorkoutSession` if one is live
    /// (never stack a second), else start a dance session + live HR + the Live Activity — then
    /// record the attendance stretch (the matcher's future hint).
    private func claim(_ set: FestivalSet, in pack: FestivalPack) {
        let now = Date()
        if let open = openAttendance {
            guard open.setID != set.id else {
                reopenLive(open)
                return
            }
            closeAttendance(open, at: now)
        }

        let session = activeSession() ?? startDanceSession(now: now)
        appendDanceExercise(for: set, to: session)
        context.insert(FestivalAttendance(packID: lineup.packID, setID: set.id,
                                          artist: set.artist, stage: set.stage,
                                          sessionID: session.id, startedAt: now))
        try? context.save()
        liveSession = session
        resumeLiveServicesIfNeeded(for: session, artist: set.artist)
        app.liveActivity.update(hrBpm: app.liveWorkout.latestHR.map { Int($0.rounded()) },
                                exerciseName: set.artist, setProgress: "")
        core.log(module: FestivalModule.id, action: "attend",
                 summary: "On the floor: \(set.artist) · \(set.stage)")
    }

    /// Re-open the live sheet for an existing claim (including after a relaunch: re-resolve the
    /// session and restart HR/Live Activity if nothing is streaming — the `resume` precedent).
    private func reopenLive(_ open: FestivalAttendance) {
        liveSession = session(id: open.sessionID)
        if let session = liveSession, session.isActive {
            resumeLiveServicesIfNeeded(for: session, artist: open.artist)
        }
        showingLive = true
    }

    /// End the night: close the open claim and — only when the session is festival-owned — finish
    /// the dance `WorkoutSession` exactly like the tracker does (flush HR, stop sources, end the
    /// Live Activity, stamp `completedAt`, feed the Recap log). A gym session we merely annotated
    /// stays live; its own player owns its lifecycle.
    private func endNight(in pack: FestivalPack) {
        let now = Date()
        if let open = openAttendance { closeAttendance(open, at: now) }
        showingLive = false
        guard let session = liveSession ?? activeSession(),
              session.isActive, isFestivalOwned(session) else {
            liveSession = nil
            return
        }
        session.hrSeries = WorkoutHRStats.points(from: app.liveWorkout.samples)
        if !session.hrSeries.isEmpty {
            let profile = app.userProfile.profile
            session.metricsSourceRaw = app.liveWorkout.activeKind.rawValue
            session.maxHR = profile.resolvedMaxHR
            session.restHR = profile.restingBound
            if app.liveWorkout.activeKind == .ble {
                session.kcalEstimate = profile.estimatedKcal(forSeries: session.hrSeries,
                                                             durationSec: session.duration)
            }
        }
        app.liveWorkout.stop()
        app.liveActivity.end()
        session.completedAt = now
        FeedActivityWriter.recordWorkoutFinish(session, in: context)
        try? context.save()
        let mins = Int(session.duration / 60)
        core.log(module: FestivalModule.id, action: "session",
                 summary: "Danced at \(lineup.name)", metric: Double(mins))
        liveSession = nil
        // The night is over — run one tagging pass now (festival prompt 03) so the review sheet
        // and Clips payoff are ready before the user even looks. Silent; discovery only when
        // Photos is already authorized.
        Task {
            await FestivalTagSync.refresh(pack: pack, packID: lineup.packID, context: context,
                                          mediaService: app.sessionMedia)
        }
    }

    // MARK: Session helpers (thin SwiftData edges)

    private func activeSession() -> WorkoutSession? {
        let all = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.completedAt == nil }))) ?? []
        return all.min { $0.startedAt > $1.startedAt }
    }

    private func session(id: UUID) -> WorkoutSession? {
        (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.id == id })))?.first
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
    /// the still-open session. Guarded exactly like the tracker's `resume` (never steal a running
    /// source, never re-create a live activity that's already up).
    private func resumeLiveServicesIfNeeded(for session: WorkoutSession, artist: String) {
        if !app.liveWorkout.isSessionActive {
            app.liveWorkout.start(for: session, disciplines: [.dance], sport: nil, category: nil,
                                  maxHR: app.userProfile.profile.resolvedMaxHR,
                                  restHR: app.userProfile.profile.restingBound)
        }
        if !app.liveActivity.isRunning {
            app.liveActivity.start(routineName: session.routineName, startedAt: session.startedAt,
                                   exerciseName: artist, setProgress: "",
                                   maxHR: app.userProfile.profile.resolvedMaxHR)
        }
    }

    /// One dance-discipline entity per claimed set ("Fred again.. · Pyramid Stage") — the freeform
    /// `addOpenEffort` shape, so the session detail reads like the night.
    private func appendDanceExercise(for set: FestivalSet, to session: WorkoutSession) {
        var entity = SessionExercise(
            exerciseId: "festival-set", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: [], displayName: "\(set.artist) · \(set.stage)",
            kindRaw: SetKind.duration.rawValue)
        entity.disciplineRaw = WorkoutDiscipline.dance.rawValue
        session.exercises.append(entity)
    }

    /// Close an attendance stretch and log its duration onto the matching dance entity, so the
    /// session detail shows a real effort per set (`SetLog.durationSec`, the `.duration` kind).
    private func closeAttendance(_ open: FestivalAttendance, at now: Date) {
        open.endedAt = now
        guard let session = session(id: open.sessionID) else { return }
        let name = "\(open.artist) · \(open.stage)"
        if let index = session.exercises.lastIndex(where: { $0.displayName == name && $0.sets.isEmpty }) {
            session.exercises[index].sets.append(
                SetLog(completedAt: now, durationSec: max(0, now.timeIntervalSince(open.startedAt))))
        }
    }

    /// A session festival started (vs a gym session it annotated): routineless, and every entity is
    /// a festival set. Content-derived, so it survives relaunches with no stored flag.
    private func isFestivalOwned(_ session: WorkoutSession) -> Bool {
        session.routineID == nil && !session.exercises.isEmpty
            && session.exercises.allSatisfy { $0.exerciseId == "festival-set" }
    }
}
