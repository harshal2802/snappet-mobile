import SwiftUI

/// The suite's app grid, grouped by category. Tapping a module logs an "open" event
/// to Snappet Core (so the dashboard tracks usage of every app for free) and routes
/// to the module's own screen.
struct AppLibraryView: View {
    @Environment(SnappetCore.self) private var core
    @Environment(AppModel.self) private var app
    // The router is hoisted to the shell (#71) — this stack binds its path; Home shares it.
    @Environment(SuiteRouter.self) private var router
    /// Whether the live container is the in-memory fallback — this entry point must tell
    /// `BackupView` too (not only the banner's), or its exports would snapshot the EMPTY
    /// fallback store as a "backup". `.resetDone` still runs on the fallback until relaunch.
    @Environment(StoreHealth.self) private var storeHealth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoom
    @State private var showingBackup = false
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            ScrollView {
                // Plain VStack layout — `Section` only renders inside List/Form/Table,
                // not a ScrollView (that showed a blank Apps tab).
                VStack(alignment: .leading, spacing: 28) {
                    flagshipCard
                    ForEach(ModuleCategory.allCases) { category in
                        let modules = ModuleRegistry.modules(in: category)
                        if !modules.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(category.title)
                                    .font(.title3.bold())
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(modules) { module in
                                        // A Button (not a NavigationLink) so the card is a real,
                                        // UI-test-hittable control; it pushes onto the shared path.
                                        Button {
                                            // Carry this card's zoom source on the route so the
                                            // destination zooms from the tile actually tapped.
                                            router.push(ModuleRoute(id: module.id,
                                                                    zoomSourceID: module.id))
                                        } label: {
                                            ModuleCard(module: module)
                                        }
                                        .buttonStyle(PressableCardStyle())
                                        .matchedTransitionSource(id: module.id, in: zoom)
                                        .accessibilityIdentifier("moduleCard.\(module.id)")
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            // Clear the suite's floating tab bar so the last Finance card isn't covered.
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: SnappetSpacing.xxl) }
            // The warm "paper" canvas on the shell screen, not just at cold start (#77).
            .background(SnappetColor.paper.ignoresSafeArea())
            .navigationTitle("Apps")
            // Suite-level backup/export/restore (issue #68) — the one suite surface, so it
            // lives on the library's top bar (mirrors the Android BackupScreen entry).
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingBackup = true
                    } label: {
                        Label("Back up & restore", systemImage: "externaldrive")
                    }
                    .accessibilityIdentifier("suite.backup.open")
                }
            }
            .sheet(isPresented: $showingBackup) {
                BackupView(storeIsFallback: storeHealth.mode != .ok)
            }
            // The Weekly Highlight Reel builder (highlights P4) — pushed by the flagship hero.
            .navigationDestination(for: WeeklyReelRoute.self) { _ in WeeklyReelHostView() }
            .navigationDestination(for: ModuleRoute.self) { route in
                // Zoom from the source the route names — the grid card or the hero (#71 review
                // fix). Routes without one (programmatic `open(module:)` deep links, the Pomodoro
                // chip) get a plain push: zooming from a card the user never tapped reads wrong.
                // The branch is stable for a pushed route's lifetime (the value never mutates).
                if let sourceID = route.zoomSourceID {
                    moduleDestination(route)
                        .navigationTransition(.zoom(sourceID: sourceID, in: zoom))
                } else {
                    moduleDestination(route)
                }
            }
        }
        // The "focus running" re-entry chip (#70), on the NavigationStack itself — an
        // overlay on the root page would slide away under every pushed module screen.
        // Visible anywhere in this stack while a phase runs, except on the Pomodoro
        // screen itself (the pomodoroScreenVisible flag).
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                // The Kilter "session running" re-entry chip — only for a plan-backed session, and
                // only while the user is outside Kilter; taps back to the frozen plan-home. Same
                // open-module-then-push pattern Home's "Plan a session" card uses.
                if app.kilterSessions.isActive, let progress = app.kilterSessions.planProgress,
                   !app.kilterScreenVisible {
                    KilterLiveChip(startedAt: app.kilterSessions.current?.startedAt ?? .now,
                                   progress: progress) {
                        router.open(module: "kilter")
                        router.push(KilterPlanRoute())
                    }
                    .transition(.liveBanner(reduceMotion: reduceMotion))
                }
                if app.pomodoro.isRunning && !app.pomodoroScreenVisible {
                    PomodoroLiveChip(timer: app.pomodoro) {
                        router.push(ModuleRoute(id: "pomodoro"))
                    }
                    .transition(.liveBanner(reduceMotion: reduceMotion))
                }
            }
            .padding(.bottom, SnappetSpacing.lg)
        }
        .snappetAnimation(SnappetMotion.standard, value: app.pomodoro.isRunning)
        .snappetAnimation(SnappetMotion.standard, value: app.pomodoroScreenVisible)
        .snappetAnimation(SnappetMotion.standard, value: app.kilterSessions.isActive)
        .snappetAnimation(SnappetMotion.standard, value: app.kilterScreenVisible)
        // The chip's third visibility gate — drive the liveBanner transition when a plan attaches /
        // detaches from outside Kilter (planProgress is a non-Equatable tuple, so key the Bool).
        .snappetAnimation(SnappetMotion.standard, value: app.kilterSessions.planProgress != nil)
        // Hydrate the session manager from the store when the Apps tab (the chip's container) appears,
        // so after a cold relaunch the Kilter live chip shows a recoverable session WITHOUT the user
        // having to open Kilter once first (the Home resume card is store-derived and already does).
        .task { app.kilterSessions.recover(in: core.context) }
    }

    /// The featured hero above the category grid (#71, re-pointed by highlights P3): with the
    /// Workout Reels tile retired, the flagship pitch is the **Weekly Highlight Reel** — it pushes
    /// the shared weekly builder (`WeeklyReelRoute`, same destination the Clips hero card opens).
    /// Keeps the `appLibrary.flagship` identifier the UI tests anchor grid scrolling on.
    private var flagshipCard: some View {
        Button {
            router.push(WeeklyReelRoute())
        } label: {
            HStack(spacing: SnappetSpacing.md) {
                Image(systemName: "sparkles.tv")
                    .font(.largeTitle)
                    .foregroundStyle(SnappetColor.reels)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Featured")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(SnappetColor.reels)
                    Text("Weekly Highlights").font(.title3.bold())
                    Text("Your best moments, auto-cut from this week's sessions")
                        .font(.caption)
                        .foregroundStyle(SnappetColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .snappetCard()
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityIdentifier("appLibrary.flagship")
    }

    /// The mini-app for a pushed `ModuleRoute`, logging an "open" event (as the old NavigationLink did).
    @ViewBuilder private func moduleDestination(_ route: ModuleRoute) -> some View {
        if let module = ModuleRegistry.all.first(where: { $0.id == route.id }) {
            module.destination()
                // The module's accent carries one tap deep (#77): controls inside the module pick up
                // its wayfinding colour instead of the global brand tint, so it reads as one product.
                .tint(module.tint)
                .onAppear {
                    core.log(module: module.id, action: "open", summary: "Opened \(module.title)")
                }
        }
    }
}

private struct ModuleCard: View {
    let module: AppModule
    var body: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.md) {
            Image(systemName: module.systemImage)
                .font(.title)
                .foregroundStyle(module.tint)
            Text(module.title).font(.headline).lineLimit(1)
            Text(module.subtitle).font(.caption).foregroundStyle(SnappetColor.textSecondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .snappetTile()
    }
}

/// Card button style: a quick spring scale-down on press (issue #30 §5.1), degrading to
/// no motion under Reduce Motion. Keeps the plain look (no default button chrome).
private struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(Snappet.snappetAnimation(SnappetMotion.quick, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}
