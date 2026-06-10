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
            // When a Pomodoro session is running, show a re-entry chip above the tab-bar inset
            // so the user can return to the timer without hunting for the Pomodoro card.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if app.pomodoroTimer.isRunning {
                        PomodoroFocusBanner(timer: app.pomodoroTimer) {
                            router.push(ModuleRoute(id: "pomodoro"))
                        }
                    }
                    Color.clear.frame(height: SnappetSpacing.xxl)
                }
            }
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

/// A persistent "focus session running" chip shown at the bottom of the Apps grid while a Pomodoro
/// timer is active, so the user can tap to return without having to scroll back to the tile.
/// Pure presentation: handed already-resolved timer state and a `resume` action.
private struct PomodoroFocusBanner: View {
    let timer: PomodoroTimer
    let resume: () -> Void

    private var tint: Color { timer.phase == .focus ? SnappetColor.pomodoro : SnappetColor.habits }

    var body: some View {
        Button(action: resume) {
            HStack(spacing: 12) {
                Image(systemName: timer.phase == .focus ? "timer" : "cup.and.saucer.fill")
                    .font(.title2)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: timer.isRunning)

                VStack(alignment: .leading, spacing: 1) {
                    Text(timer.phase.title)
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        Text(timer.timeText)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text("· Tap to return")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(tint.opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pomodoro.focusBanner")
        .accessibilityLabel("Pomodoro \(timer.phase.title) session in progress")
        .accessibilityHint("Double-tap to return to the timer")
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
