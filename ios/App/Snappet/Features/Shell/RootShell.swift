import SwiftUI
import SwiftData

/// Builds `SnappetCore` from the shared model context, then shows the suite shell.
/// When the SwiftData store failed to open (`AppModel.storeFailedToOpen`), a persistent
/// `CorruptStoreBanner` is pinned above the tab bar so the user can act before losing data.
struct RootShell: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @State private var core: SnappetCore?

    var body: some View {
        if let core {
            ZStack(alignment: .top) {
                content.environment(core)
                if app.storeFailedToOpen {
                    CorruptStoreBanner()
                        .zIndex(999)
                }
            }
        } else {
            LoadingView()
                .task { core = SnappetCore(context: context) }
        }
    }

    @ViewBuilder private var content: some View {
        // QA/screenshot hook: `-screenshotModule <id>` opens one module full-screen.
        if let id = Self.screenshotModuleID,
           let module = ModuleRegistry.all.first(where: { $0.id == id }) {
            NavigationStack { module.destination() }.environment(SuiteRouter())
        } else {
            ShellTabs()
        }
    }

    private static var screenshotModuleID: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-screenshotModule"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// A calm, branded cold-start view (issue #30 §5.10) — a brand-tinted pulse glyph over a
/// quiet ProgressView on the `paper` background, instead of a bare spinner. The glyph
/// gently pulses while loading (no-op under Reduce Motion).
private struct LoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SnappetColor.paper.ignoresSafeArea()
            VStack(spacing: SnappetSpacing.lg) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(SnappetColor.brand)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                ProgressView()
            }
        }
    }
}

/// The suite's top-level navigation: Home dashboard + the App Library.
struct ShellTabs: View {
    enum Tab { case home, apps }
    @State private var selection: Tab

    init() {
        // QA hook: launch with `--start-tab apps` to open straight to the App Library.
        _selection = State(initialValue: CommandLine.arguments.contains("apps") ? .apps : .home)
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeDashboardView()
                .tag(Tab.home)
                .tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }
            AppLibraryView()
                .tag(Tab.apps)
                .tabItem { Label("Apps", systemImage: "square.stack.3d.up.fill") }
        }
    }
}
