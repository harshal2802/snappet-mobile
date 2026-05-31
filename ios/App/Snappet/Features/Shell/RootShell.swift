import SwiftUI
import SwiftData

/// Builds `SnappetCore` from the shared model context, then shows the suite shell.
struct RootShell: View {
    @Environment(\.modelContext) private var context
    @State private var core: SnappetCore?

    var body: some View {
        if let core {
            content.environment(core)
        } else {
            ProgressView()
                .task { core = SnappetCore(context: context) }
        }
    }

    @ViewBuilder private var content: some View {
        // QA/screenshot hook: `-screenshotModule <id>` opens one module full-screen.
        if let id = Self.screenshotModuleID,
           let module = ModuleRegistry.all.first(where: { $0.id == id }) {
            NavigationStack { module.destination() }
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
