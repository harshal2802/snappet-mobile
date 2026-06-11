import SwiftUI
import SwiftData

/// Builds `SnappetCore` from the shared model context, then shows the suite shell.
struct RootShell: View {
    @Environment(\.modelContext) private var context
    @State private var core: SnappetCore?
    /// The suite router, hoisted to the shell (#71) so Home — and future deep-link entries that
    /// arrive from outside any tab (QR #75, App Intents #81) — can route into a module. The
    /// `apps` launch argument (`--start-tab apps` QA hook) seeds the initial tab.
    @State private var router = SuiteRouter(
        initialTab: CommandLine.arguments.contains("apps") ? .apps : .home)

    var body: some View {
        if let core {
            content
                .environment(core)
                .environment(router)
        } else {
            LoadingView()
                .task { core = SnappetCore(context: context) }
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
            AppLibraryView()
                .tag(SuiteTab.apps)
                .tabItem { Label("Apps", systemImage: "square.stack.3d.up.fill") }
        }
    }
}
