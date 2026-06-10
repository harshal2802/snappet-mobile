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
                    // Persistent re-entry chip: visible while a Pomodoro focus session is
                    // running in the background (the timer survives navigation via AppModel).
                    if app.pomodoroTimer.isRunning {
                        PomodoroFocusBanner(timer: app.pomodoroTimer) {
                            router.push(ModuleRoute(id: "pomodoro"))
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
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
                .animation(.snappy, value: app.pomodoroTimer.isRunning)
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

/// In-app re-entry chip shown in the App Library while a Pomodoro focus session is
/// running in the background (the timer survives navigation via AppModel). Tapping it
/// navigates back into the Pomodoro module.
private struct PomodoroFocusBanner: View {
    let timer: PomodoroTimer
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(Color.red)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Focus session running")
                        .font(.subheadline.weight(.semibold))
                    Text("\(timer.timeText) remaining · Tap to return")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pomodoroFocusBanner")
        .accessibilityLabel("Pomodoro focus session running: \(timer.timeText) remaining")
        .accessibilityHint("Double-tap to return to the Pomodoro timer")
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
