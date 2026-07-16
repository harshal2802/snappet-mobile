import SwiftUI
import SwiftData
import CoreSpotlight

/// Builds `SnappetCore` from the shared model context, then shows the suite shell.
struct RootShell: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var app
    @State private var core: SnappetCore?
    /// The suite router, hoisted to the shell (#71) so Home — and deep-link entries that arrive
    /// from outside any tab (the `snappet://` QR scheme below, #75; App Intents #81 next) — can
    /// route into a module. The `apps` launch argument (`--start-tab apps` QA hook) seeds the
    /// initial tab.
    @State private var router = SuiteRouter(
        initialTab: CommandLine.arguments.contains("apps") ? .apps
            : CommandLine.arguments.contains("clips") ? .clips
            : (CommandLine.arguments.contains("feed") ? .feed : .home))

    var body: some View {
        Group {
            if let core {
                content
                    .environment(core)
                    .environment(router)
            } else {
                LoadingView()
                    .task {
                        core = SnappetCore(context: context)
                        // Publish the first Today snapshot for the home-screen widgets (#81 Phase 1)
                        // as soon as the store is up, so a widget added before the app is reopened
                        // has data. Subsequent refreshes ride scenePhase below.
                        WidgetSnapshotService.refresh(context: context)
                        drainAppActions()   // Siri/Shortcuts "open app and act" intents (#81 Phase 3)
                        SpotlightIndexer.reindex(context: context)   // #81 Phase 4
                        app.startWatchWorkoutObserver()   // HealthKit background delivery (watch-workouts-clips P2)
                        importWatchWorkouts()   // Apple Watch workouts → Clips (watch-workouts-clips P1)
                        // Re-weight the highlight fusion from the user's own feedback log — used to
                        // ride the retired Workout Reels module's bootstrap (highlights P3).
                        app.recomputeFeedbackTuning()
                    }
            }
        }
        // Keep the home-screen widgets' Today snapshot current (#81 Phase 1): rebuild + republish
        // whenever the app foregrounds (it may have changed elsewhere) or backgrounds (capture the
        // latest before we lose the foreground). Per-mutation refreshes (habit toggle, focus done)
        // land with the widget UI in Phase 2; scenePhase covers the read path now.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active || phase == .background {
                WidgetSnapshotService.refresh(context: context)
            }
            if phase == .active {
                drainAppActions()
                importWatchWorkouts()   // catch workouts finished while backgrounded (PR2 adds true background delivery)
            }
        }
        // `snappet://` entry (#75): the Camera's QR scan / Safari / another app, cold or warm.
        // Attached to the Group — not `content` — so a cold-start URL delivered while the
        // LoadingView is still up isn't dropped. Parsing is the pure `SnappetDeepLink`; the climb
        // intent rides the router one-shot (consumed by `KilterRootView`, which owns the
        // destination + catalog knowledge for the graceful missing-climb landing).
        .onOpenURL { url in handle(url) }
        // Spotlight tap (#81 Phase 4): the CSSearchableItem's uniqueIdentifier IS its snappet:// URL,
        // so route it through the same handler as onOpenURL — one routing brain.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let url = URL(string: id) { handle(url) }
        }
    }

    /// The one routing brain for an incoming `snappet://` URL — used by both `onOpenURL` (QR / Siri
    /// start-focus / another app) and a Spotlight result tap (#81 Phase 4). The pure `SnappetDeepLink`
    /// parses; the climb/focus intents ride `SuiteRouter` one-shots (the destinations own the catalog /
    /// timer); an exercise resolves from the catalog and pushes after opening the gym tracker.
    private func handle(_ url: URL) {
        // Recap feed (F1): `snappet://feed` selects the middle tab directly (no module push).
        if url.scheme == "snappet", url.host == "feed" { router.tab = .feed; return }
        // Clips feed (prompt 82): `snappet://clips` selects the Clips tab directly.
        if url.scheme == "snappet", url.host == "clips" { router.tab = .clips; return }
        switch SnappetDeepLink.route(for: url) {
        case .kilterClimb(let link):
            router.pendingKilterClimb = link
            router.open(module: "kilter")
        case .startFocus:
            router.pendingPomodoroStart = true
            router.open(module: "pomodoro")
        case .routine(let shared):
            // A shared routine (workout-redesign E6): open the gym tracker + a one-shot import intent.
            // The tracker root owns the model context (and the catalog knowledge for the "not in your
            // library" landing), so it shows the import-confirm preview and inserts a NEW Routine.
            router.pendingRoutineImport = shared
            router.open(module: "workout-log")
        case .exercise(let id):
            // Two-level deep link: open the gym tracker, then push the exercise's detail (the
            // navigationDestination(for: Exercise.self) the tracker root registers).
            guard let exercise = ExerciseCatalog.all.first(where: { $0.id == id }) else { return }
            router.open(module: "workout-log")
            router.push(exercise)
        case nil:
            break   // not ours — ignore
        }
    }

    @ViewBuilder private var content: some View {
        // QA/screenshot hook: `-screenshotModule <id>` opens one module full-screen.
        if let id = Self.screenshotModuleID,
           let module = ModuleRegistry.all.first(where: { $0.id == id }) {
            @Bindable var router = router
            NavigationStack(path: $router.path) { module.destination() }
        } else {
            ShellTabs()
        }
    }

    private static var screenshotModuleID: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-screenshotModule"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Drain the App-Group action inbox (Siri/Shortcuts "open app and act" intents, #81 Phase 3) and
    /// dispatch each through the existing `SuiteRouter` deep-link plumbing — the same routing the
    /// `snappet://` URLs use. Skipped under UI-test launches so a stale inbox file can't navigate a
    /// test run.
    private func drainAppActions() {
        guard !Self.isUITestLaunch else { return }
        for action in AppActionInbox.drain() { dispatch(action) }
    }

    /// Reconcile completed Apple Watch workouts into Clips (watch-workouts-clips PR1): mint media-bearing
    /// anchors + attach late-syncing clips. Fire-and-forget at low priority so it never blocks launch; the
    /// service is idempotent, so the launch call + foreground re-runs (scenePhase) can't double-import.
    /// Skipped under UI-test launches (the fresh in-memory store has no Health/Photos data anyway).
    private func importWatchWorkouts() {
        guard !Self.isUITestLaunch else { return }
        Task(priority: .utility) { await app.reconcileWatchWorkouts() }
    }

    private func dispatch(_ action: PendingAppAction) {
        // The action→navigation decision is the pure, unit-tested AppActionRouter; this is just glue.
        let route = AppActionRouter.route(for: action)
        if route.startPomodoro { router.pendingPomodoroStart = true }
        if let compose = route.journalCompose { router.pendingJournalCompose = compose }
        router.open(module: route.moduleID)
    }

    private static var isUITestLaunch: Bool {
        let args = CommandLine.arguments
        return args.contains("-uiTestFreshStore")
            || args.contains("-uiTestCorruptStore")
            || args.contains("-uiTestSeedStudioDemo")
    }
}

/// A calm, branded cold-start view (issue #30 §5.10) — a brand-tinted pulse glyph over a
/// quiet ProgressView on the `paper` background, instead of a bare spinner. The glyph
/// gently pulses while loading (no-op under Reduce Motion).
private struct LoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The brand mark scales with Dynamic Type rather than a fixed 44pt (#79).
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 44

    var body: some View {
        ZStack {
            SnappetColor.paper.ignoresSafeArea()
            VStack(spacing: SnappetSpacing.lg) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: markSize, weight: .semibold))
                    .foregroundStyle(SnappetColor.brand)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                ProgressView()
            }
        }
    }
}

/// The suite's top-level navigation: Home dashboard + the App Library. Selection is owned by the
/// shell-hoisted `SuiteRouter` so Home cards / deep links can switch tabs programmatically (#71).
struct ShellTabs: View {
    @Environment(SuiteRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            // `house.fill`, not the old `square.grid.2x2.fill` — the grid glyph reads as
            // "app grid" and invited the wrong first tap (#71); the grid is the Apps tab.
            HomeDashboardView()
                .tag(SuiteTab.home)
                .tabItem { Label("Home", systemImage: "house.fill") }
            // The video/photo-first feed (prompt 82) — distinct from Recap (session cards). Case is
            // `.clips` so it never collides with `.feed` (which backs the "Recap" tab below).
            ClipsFeedView()
                .tag(SuiteTab.clips)
                .tabItem { Label("Clips", systemImage: "play.square.stack") }
            FeedView()
                .tag(SuiteTab.feed)
                .tabItem { Label("Recap", systemImage: "sparkles.rectangle.stack") }
            AppLibraryView()
                .tag(SuiteTab.apps)
                .tabItem { Label("Apps", systemImage: "square.stack.3d.up.fill") }
        }
    }
}
