import SwiftUI
import SwiftData

/// The **Gym Tracker** mini-app: a full gym/strength tracker — browse 870+ exercises, build
/// routines, run a guided session with set logging + a rest timer, and review history,
/// PRs, progress and the multi-clip Video Studio. Ported from the web Snappet suite's
/// `workout` app. (Distinct from the flagship "Workout Reels" module, which cuts highlight
/// videos from completed Apple Watch workouts — the dashboard cross-links there, #74.)
///
/// Persists to Snappet Core (SwiftData) and logs meaningful actions so the Home dashboard
/// aggregates workout activity across the suite. Fully offline — the exercise catalog is
/// bundled.
enum WorkoutTrackerModule {
    /// Stable persisted id (`UsageRecord.module`, routes, accent mapping). The *display* title was
    /// renamed "Workout" → "Gym Tracker" to disambiguate from "Workout Reels" (#74); the id must
    /// never follow a display rename or historical usage records / deep links would orphan.
    static let id = "workout-log"

    @MainActor
    static var module: AppModule {
        AppModule(
            id: id,
            title: "Gym Tracker",
            subtitle: "Routines, sets, PRs & a video studio",
            systemImage: "dumbbell.fill",
            tint: SnappetColor.moduleAccent(id),
            category: .fitness
        ) { WorkoutHomeView() }
    }
}

/// Which section of the gym tracker is showing. A top segmented control switches between
/// them — a bottom tab bar would collide with the suite's own Home/Apps tab bar. Segments are
/// **text-labelled** (#74: the icon-only symbols made the module learnable only by trial-and-error);
/// Settings is no longer a segment — it pushes from the toolbar gear (`WorkoutSettingsRoute`).
enum WorkoutSection: String, CaseIterable, Identifiable {
    case dashboard, browse, routines, history
    var id: String { rawValue }
    /// The navigation-bar title while the section is showing. The `browse` segment now reads **Library**
    /// (workout-redesign E3 — it's no longer a flat strength catalog but a discipline-spined library of all
    /// workout types); the `browse` *case id* and the `workout.sectionPicker` a11y id stay stable so
    /// historical state / deep links / the XCUITest segment query never orphan (the #74 id-vs-display rule).
    var title: String {
        switch self {
        case .dashboard: return "Gym Tracker"
        case .browse: return "Library"
        case .routines: return "Routines"
        case .history: return "History"
        }
    }
    /// The segmented-control label — same as `title` except the root section, whose nav title is
    /// the module name (too wide for a segment).
    var segmentTitle: String { self == .dashboard ? "Dashboard" : title }
}

/// Routing payload for the Settings screen, pushed from the toolbar gear (#74 — Settings used to
/// be a fifth icon-only segment, which both hid it and crowded the section control).
struct WorkoutSettingsRoute: Hashable {}

/// Routing payload for pushing an exercise's progress screen (kept distinct from pushing
/// the exercise detail, which routes on `Exercise` itself).
struct ProgressRoute: Hashable { let exerciseId: String }

/// Routing payload for a workout **library** item's discipline-adaptive detail (workout-redesign E3). A
/// `LibraryItem` is `Hashable` on its `id`, so it pushes directly; the destination renders the strength
/// detail or the climb/run/timed adaptive detail. Kept distinct from pushing `Exercise` (which the routine
/// builder / progress still use) so both routes coexist.
struct LibraryItemRoute: Hashable { let item: LibraryItem }

/// Routing payload for a completed session's detail. Pushed by id rather than the `WorkoutSession`
/// object so it never collides with the live-player `fullScreenCover(item:)`, which is also keyed on
/// `WorkoutSession` — pushing the model type directly while that cover exists wedges the push.
struct SessionRoute: Hashable { let id: UUID }

/// A pending "Save as routine" pre-fill handed from the smart planner (E7) to the routine editor sheet —
/// the plan's `[RoutineExercise]` + a suggested name. `Identifiable` so it drives a `sheet(item:)`.
struct PlannerRoutinePrefill: Identifiable {
    let id = UUID()
    let name: String
    let exercises: [RoutineExercise]
}

struct WorkoutHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Environment(SuiteRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: \Routine.updatedAt, order: .reverse) private var routines: [Routine]
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var customExercises: [CustomExercise]
    /// All tagged session media — feeds the module-level Video Studio entry (#74): the dashboard's
    /// "Open in Studio" candidates and the History rows' studio shortcut both derive from it via
    /// the pure `StudioEntry`.
    @Query private var sessionMedia: [SessionMedia]

    @AppStorage("workoutlog.preferredUnit") private var preferredUnitRaw = WeightUnit.kg.rawValue
    @AppStorage("workoutlog.dismissedStarters") private var dismissedStartersRaw = ""

    @State private var section: WorkoutSection = .dashboard
    @State private var showingNewRoutine = false
    @State private var showingNewExercise = false
    /// A planner "Save as routine" pre-fill — opens the routine editor seeded with the plan (E7). `nil` ⇒
    /// the plain "New Routine" path (no pre-fill).
    @State private var plannerPrefill: PlannerRoutinePrefill?
    @State private var playing: WorkoutSession?
    @State private var startConflict: Routine?
    /// A routine arriving over QR / a `snappet://routine/v1/…` link (E6) awaiting the import-confirm
    /// preview. Set by `consumePendingImport` from the router one-shot; cleared when the sheet closes.
    @State private var importingRoutine: SharedRoutine?
    /// The Video Studio opened from the module level (#74) — dashboard candidates or a History
    /// row's swipe shortcut. Same find-or-create + full-screen presentation as the session detail.
    @State private var studioProject: StudioProject?
    /// Drives the zoom transition between the live-workout banner and the full-screen player.
    @Namespace private var playerZoom

    private var unit: WeightUnit { WeightUnit(rawValue: preferredUnitRaw) ?? .kg }
    private var resolver: ExerciseResolver { ExerciseResolver(custom: customExercises) }
    // Tracked gym history excludes Apple Watch imports (watch-workouts-clips): those anchors carry no
    // exercises/sets, so they'd render as broken empty rows here and pollute the set-based analytics,
    // plan, dashboard, and Studio candidates this list feeds. They surface in Clips + their own
    // "From Apple Watch" section (P3), never in the tracked-workout pipeline.
    private var history: [WorkoutSession] { sessions.filter { !$0.isActive && !$0.isFromAppleWatch } }
    /// Completed Apple Watch imports — surfaced only in the History screen's "From Apple Watch" section,
    /// never in `history` (the tracked-gym pipeline). Newest first (`sessions` is already sorted).
    private var watchSessions: [WorkoutSession] { sessions.filter { !$0.isActive && $0.isFromAppleWatch } }
    private var activeSession: WorkoutSession? { sessions.first { $0.isActive } }

    var body: some View {
        VStack(spacing: 0) {
            // Text segments (#74): every section is identifiable without tapping. Staying on the
            // native segmented style keeps the control under `segmentedControls` for the XCUITests.
            Picker("Section", selection: $section) {
                ForEach(WorkoutSection.allCases) { s in
                    Text(s.segmentTitle).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("workout.sectionPicker")
            .padding(.horizontal)
            .padding(.bottom, 8)

            sectionContent
                .id(section)
                .transition(.sectionSwap(reduceMotion: reduceMotion))
                .snappetAnimation(SnappetMotion.standard, value: section)
        }
        // While a workout runs but the player is minimized, keep a live banner pinned to the
        // bottom (live metrics in-app + a one-tap way back in — the background-workout ask).
        .safeAreaInset(edge: .bottom) { liveWorkoutBanner }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .navigationDestination(for: Exercise.self) { ex in
            ExerciseDetailView(exercise: ex, history: history, unit: unit)
        }
        .navigationDestination(for: LibraryItemRoute.self) { route in
            LibraryItemDetailView(item: route.item, history: history, unit: unit)
        }
        .navigationDestination(for: Routine.self) { r in
            RoutineDetailView(routine: r, resolver: resolver, unit: unit,
                              start: { startWorkout(from: r) })
        }
        .navigationDestination(for: SessionRoute.self) { route in
            if let s = sessions.first(where: { $0.id == route.id }) {
                // The routine's sport feeds the B4 highlight engine's activity mapping (it may
                // have since been deleted → nil, then the bridge falls back to the dominant
                // exercise category / a generic gym default).
                let sport = routines.first(where: { $0.id == s.routineID })?.sport
                SessionDetailView(session: s, resolver: resolver, unit: unit, sport: sport,
                                  history: history.filter { $0.id != s.id })
            }
        }
        .navigationDestination(for: ProgressRoute.self) { route in
            ExerciseProgressView(exerciseId: route.exerciseId, resolver: resolver,
                                 history: history, unit: unit)
        }
        // Smart workout planning (workout-redesign E7): the pure WorkoutRecommender + per-muscle
        // WorkoutHistoryStats fed by the @MainActor resolver join, surfaced as an editable draft.
        .navigationDestination(for: WorkoutPlanRoute.self) { _ in
            WorkoutPlanView(history: history, resolver: resolver, unit: unit,
                            start: { exercises, name in startPlannedSession(exercises, name: name) },
                            saveAsRoutine: { exercises, name in
                                plannerPrefill = PlannerRoutinePrefill(name: name, exercises: exercises)
                            })
        }
        // Settings is pushed from the toolbar gear (#74) — it used to be a fifth segment.
        .navigationDestination(for: WorkoutSettingsRoute.self) { _ in
            WorkoutSettingsView(unitRaw: $preferredUnitRaw, customExercises: customExercises,
                                history: history, open: { router.push($0) },
                                deleteCustom: deleteCustomExercise)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showingNewRoutine) {
            RoutineEditorView(routine: nil, resolver: resolver, defaultUnit: unit)
        }
        // The planner's "Save as routine" → the routine editor pre-filled with the plan for review/rename
        // (E7), through the SAME `prefill: RoutineDraft?` seam E5 uses (unified, was prefillExercises/Name).
        .sheet(item: $plannerPrefill) { prefill in
            RoutineEditorView(routine: nil,
                              prefill: RoutineDraft(name: prefill.name, sport: nil, level: nil,
                                                    detail: nil, exercises: prefill.exercises),
                              resolver: resolver, defaultUnit: unit)
        }
        .sheet(isPresented: $showingNewExercise) {
            ExerciseEditorView(existing: nil)
        }
        // The import-confirm preview for a routine arriving over QR / a snappet:// link (E6). Never
        // silent: the user reviews it (incl. the "not in your library" landing) and confirms an insert.
        .sheet(item: $importingRoutine) { shared in
            RoutineImportSheet(shared: shared, resolver: resolver, unit: unit,
                               onImport: { blocks in importRoutine(shared, blocks: blocks) })
        }
        .fullScreenCover(item: $playing) { session in
            // One player for every session — routine and freeform alike. The saved routine's
            // prescription (planned sets from `targetSets`, reps/weight, prescribed rest, climb grade)
            // is seeded into the same grow-as-you-go pager, so both flows render from one source of
            // truth and a routine stays expandable (extra sets, add exercise, history). The old guided
            // set-by-set `WorkoutPlayerView` was retired here. (routine-in-pager convergence)
            FreeformPlayerView(session: session, resolver: resolver, history: history,
                               defaultUnit: unit,
                               onClose: { saved in finishWorkout(session, saved: saved) },
                               onMinimize: { minimizeWorkout() },
                               onViewDetail: { s in
                                   finishWorkout(s, saved: true)   // sets playing = nil (dismiss cover)
                                   // Defer the push one runloop tick: dismissing the fullScreenCover
                                   // and appending to the NavigationStack path in the same
                                   // transaction can drop the push (the SwiftUI hazard the
                                   // pendingWorkoutResume/Kilter deferrals already work around).
                                   let id = s.id
                                   Task { @MainActor in router.push(SessionRoute(id: id)) }
                               })
            .navigationTransition(.zoom(sourceID: "workoutPlayer", in: playerZoom))
        }
        // The module-level Video Studio (#74): presented from the dashboard's "Open in Studio"
        // rows / a History row's swipe shortcut, on this stable host (the session detail keeps
        // its own identical cover for the in-detail entry).
        .fullScreenCover(item: $studioProject) { project in
            StudioEditorView(project: project, context: context)
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
        .task {
            seedStarters()
            consumePendingResume()
        }
        // Consume the one-shot routine-import intent (E6, the `pendingKilterClimb` pattern): `initial: true`
        // covers cold start (the intent was set before this view existed), the change closure the warm case
        // (the shell replaced the path with this root, then set a new intent). Clearing the router flag
        // before presenting makes it one-shot even if the sheet re-renders us.
        .onChange(of: router.pendingRoutineImport, initial: true) { _, pending in
            guard let pending else { return }
            router.pendingRoutineImport = nil
            section = .routines
            importingRoutine = pending
        }
    }

    /// Consume the router's one-shot resume intent (#71 review fix): Home's "Resume <routine>" card
    /// can't open this view's local `fullScreenCover`, so it flags the router and this view re-opens
    /// the player through the existing `resume(_:)` path (live-metrics / Live-Activity restart logic
    /// included). Always clears the flag (one-shot); a no-op when no session is actually active.
    private func consumePendingResume() {
        guard router.pendingWorkoutResume else { return }
        router.pendingWorkoutResume = false
        if let s = activeSession { resume(s) }
    }

    /// Insert a NEW local `Routine` from a confirmed import (E6). A fresh UUID — it NEVER overwrites an
    /// existing routine (the design's "new local UUID, never overwrite" rule); the blocks already carry
    /// fresh ids from `SharedRoutine.routineExercises()`.
    private func importRoutine(_ shared: SharedRoutine, blocks: [RoutineExercise]) {
        let routine = Routine(name: shared.name, exercises: blocks, isStarter: false,
                              detail: (shared.detail?.isEmpty == false) ? shared.detail : nil)
        context.insert(routine)
        try? context.save()
        core.log(module: WorkoutTrackerModule.id, action: "routine",
                 summary: "Imported routine: \(shared.name)")
        section = .routines
    }

    /// The live-workout banner — shown only while a workout is active *and* the player is
    /// minimized. Tapping it zooms back into the player (matched via `playerZoom`).
    @ViewBuilder private var liveWorkoutBanner: some View {
        if playing == nil, let active = activeSession {
            LiveWorkoutBanner(
                routineName: active.routineName,
                startedAt: active.startedAt,
                bpm: app.liveWorkout.latestHR.map { Int($0.rounded()) },
                paused: app.liveWorkout.isPaused,
                resume: { resume(active) })
                .matchedTransitionSource(id: "workoutPlayer", in: playerZoom)
                .transition(.liveBanner(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .dashboard:
            WorkoutDashboardSection(history: history, routines: routines, resolver: resolver,
                                    unit: unit, activeSession: activeSession,
                                    studioCandidates: StudioEntry.candidates(history: history,
                                                                             media: sessionMedia),
                                    resume: { if let s = activeSession { resume(s) } },
                                    goToRoutines: { section = .routines },
                                    goToBrowse: { section = .browse },
                                    openRoutine: { router.push($0) },
                                    openProgress: { router.push(ProgressRoute(exerciseId: $0)) },
                                    openStudio: { id in
                                        if let s = sessions.first(where: { $0.id == id }) {
                                            openStudio(for: s)
                                        }
                                    },
                                    openReels: { router.open(module: "workout") },
                                    openSession: { id in router.push(SessionRoute(id: id)) },
                                    startQuick: { startFreeform() },
                                    openPlan: { router.push(WorkoutPlanRoute()) })
        case .browse:
            WorkoutLibraryView(resolver: resolver, history: history, unit: unit,
                               open: { router.push(LibraryItemRoute(item: $0)) },
                               openSession: { id in router.push(SessionRoute(id: id)) })
        case .routines:
            RoutinesSectionView(routines: routines, resolver: resolver, unit: unit,
                                open: { router.push($0) },
                                start: startWorkout(from:),
                                deleteRoutine: deleteRoutine,
                                newRoutine: { showingNewRoutine = true })
        case .history:
            HistorySectionView(history: history, resolver: resolver, unit: unit,
                               videoSessionIDs: StudioEntry.videoSessionIDs(media: sessionMedia),
                               deleteSession: deleteSession,
                               openStudio: { openStudio(for: $0) },
                               watchSessions: watchSessions)
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
        } else if section == .dashboard {
            // Quick Start: a freeform session you build on the fly (no routine needed).
            ToolbarItem(placement: .primaryAction) {
                Button { startFreeform() } label: { Label("Quick Start", systemImage: "bolt.fill") }
                    .accessibilityIdentifier("workout.quickStart")
            }
        }
        // The Settings gear — always present (#74), replacing the old fifth segment.
        ToolbarItem(placement: .topBarTrailing) {
            Button { router.push(WorkoutSettingsRoute()) } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("workout.settings")
        }
    }

    /// Find-or-create the session's `StudioProject` and present the full studio — the module-level
    /// entry (#74). Shares `StudioEntry.findOrCreateProject` with the session detail's button so
    /// both paths open the same project.
    private func openStudio(for session: WorkoutSession) {
        studioProject = StudioEntry.findOrCreateProject(for: session, media: sessionMedia,
                                                        context: context)
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

    /// Start a freeform (routineless) session — an empty `WorkoutSession` you grow on the fly in
    /// `FreeformPlayerView` (add exercises + sets / climb attempts). If a workout is already active,
    /// resume it instead of stacking a second one. (dynamic-sessions D3)
    private func startFreeform() {
        if let active = activeSession { resume(active); return }
        let session = WorkoutSession(routineID: nil, routineName: "Quick session", exercises: [])
        context.insert(session)
        try? context.save()
        app.liveWorkout.start(for: session, sport: nil, category: nil,
                              maxHR: app.userProfile.profile.resolvedMaxHR,
                              restHR: app.userProfile.profile.restingBound)
        startLiveActivity(for: session)
        playing = session
    }

    /// Start a session from the smart planner's draft (workout-redesign E7). The plan is a `[RoutineExercise]`;
    /// we seed a freeform (routineless) session from it via the same `RoutineSessionBuilder` the guided player
    /// uses, so the planned exercises arrive as proper session entities and the user grows/edits them in the
    /// freeform logbook. If a workout is already active, resume it instead of stacking a second one.
    private func startPlannedSession(_ exercises: [RoutineExercise], name: String) {
        if let active = activeSession { resume(active); return }
        let sessionExercises = exercises.map { RoutineSessionBuilder.sessionExercise(from: $0, defaultUnit: unit) }
        let session = WorkoutSession(routineID: nil, routineName: name, exercises: sessionExercises)
        context.insert(session)
        try? context.save()
        app.liveWorkout.start(for: session, sport: nil, category: nil,
                              maxHR: app.userProfile.profile.resolvedMaxHR,
                              restHR: app.userProfile.profile.restingBound)
        startLiveActivity(for: session)
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
        // Source-agnostic: restart metrics only when no session is driving a source (e.g. after a
        // cold relaunch). Using the watch-specific `connectionState` here would always restart a
        // BLE session — clearing its HR buffer — since a BLE source never sets `.workoutRunning`.
        if !app.liveWorkout.isSessionActive {
            if let routine = routines.first(where: { $0.id == session.routineID }) {
                startLiveMetrics(for: session, routine: routine)
            } else {
                app.liveWorkout.start(for: session, sport: nil, category: nil,
                              maxHR: app.userProfile.profile.resolvedMaxHR,
                              restHR: app.userProfile.profile.restingBound)
                startLiveActivity(for: session)
            }
        } else if !app.liveActivity.isRunning {
            // Watch is already streaming (warm resume) so we skip restarting live metrics. Only
            // (re)start the Live Activity if one isn't already showing — otherwise a warm resume
            // would needlessly end+recreate the activity already on the Lock Screen.
            startLiveActivity(for: session)
        }
        withAnimation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion)) { playing = session }
    }

    /// Ask the watch to start an `HKWorkoutSession` of the type that matches the
    /// routine (sport tag first, then its dominant exercise category). A1's
    /// watch-trigger: the phone chooses the activity type, the watch records it and
    /// streams HR back into the active `MetricsSource`. No-op when no watch is reachable.
    private func startLiveMetrics(for session: WorkoutSession, routine: Routine) {
        let category = WorkoutActivityMapping.dominantCategory(
            of: routine.exercises.compactMap { resolver.exercise(id: $0.exerciseId)?.category })
        // E4: the routine's per-block disciplines are the strongest signal for the watch activity type —
        // a run records `.running`, a mixed routine `.mixedCardio` — falling back to sport/category for an
        // all-strength / pre-E4 routine (see `WorkoutActivityMapping.activityType(disciplines:…)`).
        let disciplines = routine.exercises.map(\.discipline)
        app.liveWorkout.start(for: session, disciplines: disciplines,
                              sport: routine.sport, category: category,
                              maxHR: app.userProfile.profile.resolvedMaxHR,
                              restHR: app.userProfile.profile.restingBound)
        startLiveActivity(for: session)
    }

    /// Begin the Live Activity (overall timer + live HR + current exercise on the Lock Screen /
    /// Dynamic Island) anchored on `session.startedAt`. The overall timer ticks off that date
    /// with no background CPU; the player pushes HR/exercise updates as it advances. No-op where
    /// Live Activities are unavailable/unauthorized (live-workout-studio A2).
    private func startLiveActivity(for session: WorkoutSession) {
        let first = session.exercises.first { !$0.skipped }
        let name = first.map { resolver.name(for: $0.exerciseId, override: $0.displayName) } ?? "Workout"
        // Seed a real first-set label so the Lock Screen isn't blank if the app is backgrounded
        // before the player view appears (e.g. started via a shortcut). Read the unified plan count
        // (`plannedSets` ?? routine `targetSets`) rather than `sets.count` — sessions now start with no
        // pre-seeded sets, so a routine shows "Set 1 of 4" from its prescription while a plan-less
        // freeform exercise stays blank until a set is actually logged (never "Set 1 of 0").
        let progress = first.flatMap { ex -> String? in
            guard let planned = QuickSessionPager.plannedCount(for: ex), planned > 0 else { return nil }
            return "Set 1 of \(planned)"
        } ?? ""
        app.liveActivity.start(routineName: session.routineName, startedAt: session.startedAt,
                               exerciseName: name, setProgress: progress,
                               maxHR: app.userProfile.profile.resolvedMaxHR)
    }

    private func makeSession(from routine: Routine) -> WorkoutSession {
        WorkoutSession(routineID: routine.id, routineName: routine.name,
                       exercises: RoutineSessionBuilder.exercises(from: routine, defaultUnit: unit))
    }

    /// Minimize the player without ending the workout: just drop the full-screen cover. The
    /// session stays `isActive`, the watch keeps recording, and the Live Activity + the in-app
    /// banner keep showing live metrics. Re-opened by tapping the banner. (Background-workout ask.)
    private func minimizeWorkout() {
        withAnimation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion)) { playing = nil }
    }

    /// Called when the player closes. `saved == false` means "discard": delete the session.
    private func finishWorkout(_ session: WorkoutSession, saved: Bool) {
        // On a saved finish, flush the live HR buffer into the session BEFORE `stop()` (which
        // stops both sources) so the enriched summary (B2) can chart it. `samples` are engine
        // `HRSample`s already rebased onto the session timeline; empty with no live source, so
        // the summary's chart/stats simply hide. Discards keep no series (the session is deleted).
        if saved {
            session.hrSeries = WorkoutHRStats.points(from: app.liveWorkout.samples)
            // Stamp the HR-profile-derived bounds + source label from the actually-captured data, so
            // the summary's zones/%HRR/effort personalize and a calorie estimate fills the band's
            // `energy = 0` (Phase 2). All `nil`/absent with no HR or no profile → unchanged behavior.
            if !session.hrSeries.isEmpty {
                let profile = app.userProfile.profile
                session.metricsSourceRaw = app.liveWorkout.activeKind.rawValue
                session.maxHR = profile.resolvedMaxHR
                session.restHR = profile.restingBound
                // Calories are BLE-only: the Apple-Watch path measures real active energy on the
                // wrist, so never override it with a Keytel estimate.
                if app.liveWorkout.activeKind == .ble {
                    session.kcalEstimate = profile.estimatedKcal(forSeries: session.hrSeries,
                                                                 durationSec: session.duration)
                }
            }
        }
        // End the watch session regardless of save/discard so the watch isn't left recording.
        app.liveWorkout.stop()
        // End the Live Activity alongside the watch session.
        app.liveActivity.end()
        if saved {
            session.completedAt = .now
            // Recap feed (F0b): append-only, idempotent workout activity.
            FeedActivityWriter.recordWorkoutFinish(session, in: context)
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
