import SwiftUI
import SwiftData

/// The Workout mini-app: a full gym/strength tracker — browse 870+ exercises, build
/// routines, run a guided session with set logging + a rest timer, and review history,
/// PRs and progress. Ported from the web Snappet suite's `workout` app. (Distinct from
/// the flagship "Workout Reels" module, which makes HR-driven highlight videos.)
///
/// Persists to Snappet Core (SwiftData) and logs meaningful actions so the Home dashboard
/// aggregates workout activity across the suite. Fully offline — the exercise catalog is
/// bundled.
enum WorkoutTrackerModule {
    static let id = "workout-log"

    @MainActor
    static var module: AppModule {
        AppModule(
            id: id,
            title: "Workout",
            subtitle: "Routines, set tracking & PRs",
            systemImage: "dumbbell.fill",
            tint: .orange,
            category: .fitness
        ) { WorkoutHomeView() }
    }
}

/// Which section of the workout app is showing. A top segmented control switches between
/// them — a bottom tab bar would collide with the suite's own Home/Apps tab bar.
enum WorkoutSection: String, CaseIterable, Identifiable {
    case dashboard, browse, routines, history, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Workout"
        case .browse: return "Exercises"
        case .routines: return "Routines"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .browse: return "figure.strengthtraining.traditional"
        case .routines: return "list.bullet.rectangle.portrait"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// Routing payload for pushing an exercise's progress screen (kept distinct from pushing
/// the exercise detail, which routes on `Exercise` itself).
struct ProgressRoute: Hashable { let exerciseId: String }

/// Routing payload for a completed session's detail. Pushed by id rather than the `WorkoutSession`
/// object so it never collides with the live-player `fullScreenCover(item:)`, which is also keyed on
/// `WorkoutSession` — pushing the model type directly while that cover exists wedges the push.
struct SessionRoute: Hashable { let id: UUID }

struct WorkoutHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Environment(SuiteRouter.self) private var router
    @Environment(AppModel.self) private var app

    @Query(sort: \Routine.updatedAt, order: .reverse) private var routines: [Routine]
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var customExercises: [CustomExercise]

    @AppStorage("workoutlog.preferredUnit") private var preferredUnitRaw = WeightUnit.kg.rawValue
    @AppStorage("workoutlog.dismissedStarters") private var dismissedStartersRaw = ""

    @State private var section: WorkoutSection = .dashboard
    @State private var showingNewRoutine = false
    @State private var showingNewExercise = false
    @State private var playing: WorkoutSession?
    @State private var startConflict: Routine?

    private var unit: WeightUnit { WeightUnit(rawValue: preferredUnitRaw) ?? .kg }
    private var resolver: ExerciseResolver { ExerciseResolver(custom: customExercises) }
    private var history: [WorkoutSession] { sessions.filter { !$0.isActive } }
    private var activeSession: WorkoutSession? { sessions.first { $0.isActive } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(WorkoutSection.allCases) { s in
                    Image(systemName: s.symbol).tag(s)
                        .accessibilityLabel(s.title)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            sectionContent
        }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .navigationDestination(for: Exercise.self) { ex in
            ExerciseDetailView(exercise: ex, history: history, unit: unit)
        }
        .navigationDestination(for: Routine.self) { r in
            RoutineDetailView(routine: r, resolver: resolver, unit: unit,
                              start: { startWorkout(from: r) })
        }
        .navigationDestination(for: SessionRoute.self) { route in
            if let s = sessions.first(where: { $0.id == route.id }) {
                SessionDetailView(session: s, resolver: resolver, unit: unit)
            }
        }
        .navigationDestination(for: ProgressRoute.self) { route in
            ExerciseProgressView(exerciseId: route.exerciseId, resolver: resolver,
                                 history: history, unit: unit)
        }
        .sheet(isPresented: $showingNewRoutine) {
            RoutineEditorView(routine: nil, resolver: resolver, defaultUnit: unit)
        }
        .sheet(isPresented: $showingNewExercise) {
            ExerciseEditorView(existing: nil)
        }
        .fullScreenCover(item: $playing) { session in
            WorkoutPlayerView(session: session, resolver: resolver, defaultUnit: unit) { saved in
                finishWorkout(session, saved: saved)
            }
        }
        .confirmationDialog("A workout is already in progress.",
                            isPresented: Binding(get: { startConflict != nil },
                                                 set: { if !$0 { startConflict = nil } }),
                            titleVisibility: .visible) {
            Button("Resume current workout") {
                if let s = activeSession { resume(s) }
                startConflict = nil
            }
            Button("Discard it & start new", role: .destructive) {
                if let conflict = startConflict { replaceActiveAndStart(with: conflict) }
                startConflict = nil
            }
            Button("Cancel", role: .cancel) { startConflict = nil }
        }
        .task { seedStarters() }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .dashboard:
            WorkoutDashboardSection(history: history, routines: routines, resolver: resolver,
                                    unit: unit, activeSession: activeSession,
                                    resume: { if let s = activeSession { resume(s) } },
                                    goToRoutines: { section = .routines },
                                    goToBrowse: { section = .browse },
                                    openRoutine: { router.push($0) },
                                    openProgress: { router.push(ProgressRoute(exerciseId: $0)) })
        case .browse:
            ExerciseBrowserView(resolver: resolver, open: { router.push($0) })
        case .routines:
            RoutinesSectionView(routines: routines, resolver: resolver, unit: unit,
                                open: { router.push($0) },
                                start: startWorkout(from:),
                                deleteRoutine: deleteRoutine,
                                newRoutine: { showingNewRoutine = true })
        case .history:
            HistorySectionView(history: history, resolver: resolver, unit: unit,
                               deleteSession: deleteSession)
        case .settings:
            WorkoutSettingsView(unitRaw: $preferredUnitRaw, customExercises: customExercises,
                                history: history, open: { router.push($0) },
                                deleteCustom: deleteCustomExercise)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if section == .routines {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewRoutine = true } label: { Label("New Routine", systemImage: "plus") }
            }
        } else if section == .browse {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewExercise = true } label: { Label("New Exercise", systemImage: "plus") }
            }
        }
    }

    // MARK: - Session lifecycle

    private func startWorkout(from routine: Routine) {
        if let active = activeSession {
            if active.routineID == routine.id { resume(active) }
            else { startConflict = routine }
            return
        }
        let session = makeSession(from: routine)
        context.insert(session)
        try? context.save()
        startLiveMetrics(for: session, routine: routine)
        playing = session
    }

    private func replaceActiveAndStart(with routine: Routine) {
        // Stop the watch session for the workout being discarded *before* starting the
        // new one — otherwise the watch's `!isRunning` guard drops the new start and it
        // keeps recording the old activity (and HR rebases onto the wrong session).
        app.liveWorkout.stop()
        if let active = activeSession { context.delete(active) }
        let session = makeSession(from: routine)
        context.insert(session)
        try? context.save()
        startLiveMetrics(for: session, routine: routine)
        playing = session
    }

    /// Resume an already-active session (dashboard banner / "Resume current workout" /
    /// re-tapping the same routine). After a cold relaunch the watch isn't recording, so
    /// (re)start live metrics — guarded so a warm resume (watch already running) doesn't
    /// double-start. Falls back to a default type if the routine was since deleted.
    private func resume(_ session: WorkoutSession) {
        if app.liveWorkout.connectionState != .workoutRunning {
            if let routine = routines.first(where: { $0.id == session.routineID }) {
                startLiveMetrics(for: session, routine: routine)
            } else {
                app.liveWorkout.start(for: session, sport: nil, category: nil)
            }
        }
        playing = session
    }

    /// Ask the watch to start an `HKWorkoutSession` of the type that matches the
    /// routine (sport tag first, then its dominant exercise category). A1's
    /// watch-trigger: the phone chooses the activity type, the watch records it and
    /// streams HR back into `LiveWorkoutService`. No-op when no watch is reachable.
    private func startLiveMetrics(for session: WorkoutSession, routine: Routine) {
        let category = WorkoutActivityMapping.dominantCategory(
            of: routine.exercises.compactMap { resolver.exercise(id: $0.exerciseId)?.category })
        app.liveWorkout.start(for: session, sport: routine.sport, category: category)
    }

    private func makeSession(from routine: Routine) -> WorkoutSession {
        let exercises = routine.exercises.map { re in
            SessionExercise(
                exerciseId: re.exerciseId,
                targetSets: re.sets,
                targetReps: re.reps,
                targetRestSeconds: re.restSeconds,
                targetWeight: re.weight,
                targetWeightUnit: re.weightUnit ?? unit,
                sets: Array(repeating: SetLog(weightUnit: re.weightUnit ?? unit), count: max(1, re.sets)),
                displayName: re.displayName
            )
        }
        return WorkoutSession(routineID: routine.id, routineName: routine.name, exercises: exercises)
    }

    /// Called when the player closes. `saved == false` means "discard": delete the session.
    private func finishWorkout(_ session: WorkoutSession, saved: Bool) {
        // End the watch session regardless of save/discard so the watch isn't left
        // recording. (Buffered HRSamples are retained on the service for B2.)
        app.liveWorkout.stop()
        if saved {
            session.completedAt = .now
            try? context.save()
            let mins = Int(session.duration / 60)
            core.log(module: WorkoutTrackerModule.id, action: "session",
                     summary: "Completed \(session.routineName)", metric: Double(mins))
            section = .dashboard
        } else {
            context.delete(session)
            try? context.save()
        }
        playing = nil
    }

    // MARK: - Mutations

    private func deleteRoutine(_ routine: Routine) {
        if routine.isStarter, let key = routine.starterKey {
            var dismissed = dismissedStarters
            dismissed.insert(key)
            dismissedStartersRaw = dismissed.sorted().joined(separator: ",")
        }
        context.delete(routine)
        try? context.save()
    }

    private func deleteSession(_ session: WorkoutSession) {
        context.delete(session)
        try? context.save()
    }

    private func deleteCustomExercise(_ custom: CustomExercise) {
        context.delete(custom)
        try? context.save()
    }

    // MARK: - Starter seeding

    private var dismissedStarters: Set<String> {
        Set(dismissedStartersRaw.split(separator: ",").map(String.init))
    }

    private func seedStarters() {
        StarterRoutines.seedIfNeeded(context: context, existing: routines, dismissed: dismissedStarters)
    }
}
