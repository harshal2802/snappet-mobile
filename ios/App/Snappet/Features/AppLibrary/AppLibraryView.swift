import SwiftUI

/// The suite's app grid, grouped by category. Tapping a module logs an "open" event
/// to Snappet Core (so the dashboard tracks usage of every app for free) and routes
/// to the module's own screen.
struct AppLibraryView: View {
    @Environment(SnappetCore.self) private var core
    @Environment(AppModel.self) private var app
    @Namespace private var zoom
    @State private var router = SuiteRouter()
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack(path: $router.path) {
            ScrollView {
                // Plain VStack layout — `Section` only renders inside List/Form/Table,
                // not a ScrollView (that showed a blank Apps tab).
                VStack(alignment: .leading, spacing: 28) {
                    // Persistent chip when a Pomodoro session is running in the background —
                    // lets the user re-enter without scrolling through the grid.
                    if app.pomodoroTimer.isRunning {
                        FocusRunningChip()
                    }
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
        .environment(router)
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

/// A tappable banner shown at the top of the App Library when a Pomodoro session is running in
/// the background — lets the user re-enter the timer without scrolling through the module grid.
/// Extracted into its own view so only this chip re-renders on every timer tick, not the full grid.
private struct FocusRunningChip: View {
    @Environment(AppModel.self) private var app
    @Environment(SuiteRouter.self) private var router

    var body: some View {
        Button {
            router.push(ModuleRoute(id: "pomodoro"))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: app.pomodoroTimer.phase == .focus ? "brain.head.profile" : "cup.and.saucer.fill")
                    .font(.title3)
                    .foregroundStyle(app.pomodoroTimer.phase == .focus ? SnappetColor.pomodoro : SnappetColor.habits)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.pomodoroTimer.phase == .focus ? "Focus running" : "Break running")
                        .font(.subheadline.weight(.semibold))
                    Text(app.pomodoroTimer.timeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(SnappetColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SnappetColor.textSecondary)
            }
            .padding()
            .snappetTile()
        }
        .buttonStyle(.plain)
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
