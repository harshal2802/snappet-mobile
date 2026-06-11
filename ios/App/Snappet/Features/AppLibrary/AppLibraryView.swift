import SwiftUI

/// The suite's app grid, grouped by category. Tapping a module logs an "open" event
/// to Snappet Core (so the dashboard tracks usage of every app for free) and routes
/// to the module's own screen.
struct AppLibraryView: View {
    @Environment(SnappetCore.self) private var core
    @Environment(AppModel.self) private var app
    // The router is hoisted to the shell (#71) — this stack binds its path; Home shares it.
    @Environment(SuiteRouter.self) private var router
    @Namespace private var zoom
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
                                            router.push(ModuleRoute(id: module.id))
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
            .navigationTitle("Apps")
            .navigationDestination(for: ModuleRoute.self) { route in
                moduleDestination(route)
                    .navigationTransition(.zoom(sourceID: route.id, in: zoom))
            }
        }
        // The "focus running" re-entry chip (#70), on the NavigationStack itself — an
        // overlay on the root page would slide away under every pushed module screen.
        // Visible anywhere in this stack while a phase runs, except on the Pomodoro
        // screen itself (the pomodoroScreenVisible flag).
        .overlay(alignment: .bottom) {
            if app.pomodoro.isRunning && !app.pomodoroScreenVisible {
                PomodoroLiveChip(timer: app.pomodoro) {
                    router.push(ModuleRoute(id: "pomodoro"))
                }
                .padding(.bottom, SnappetSpacing.lg)
                .transition(.liveBanner)
            }
        }
        .animation(.snappyNav, value: app.pomodoro.isRunning)
        .animation(.snappyNav, value: app.pomodoroScreenVisible)
    }

    /// The flagship gets a featured hero above the category grid (#71): a first-time user lands
    /// on Apps facing 9 equal cards with no signal which one is the pitch — this makes Workout
    /// Reels unmissable. It pushes the same `ModuleRoute` the grid card does (so opening it logs
    /// identically); the grid card stays, as the smoke test — and muscle memory — expect.
    @ViewBuilder private var flagshipCard: some View {
        if let flagship = ModuleRegistry.all.first(where: { $0.id == "workout" }) {
            Button {
                router.push(ModuleRoute(id: flagship.id))
            } label: {
                HStack(spacing: SnappetSpacing.md) {
                    Image(systemName: flagship.systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(flagship.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Featured")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(flagship.tint)
                        Text(flagship.title).font(.title3.bold())
                        Text(flagship.subtitle)
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
            // No `matchedTransitionSource` here: the grid card already registers the module's
            // zoom source id, and a second source for the same destination would conflict.
            .buttonStyle(PressableCardStyle())
            .accessibilityIdentifier("appLibrary.flagship")
        }
    }

    /// The mini-app for a pushed `ModuleRoute`, logging an "open" event (as the old NavigationLink did).
    @ViewBuilder private func moduleDestination(_ route: ModuleRoute) -> some View {
        if let module = ModuleRegistry.all.first(where: { $0.id == route.id }) {
            module.destination()
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
