import SwiftUI

/// The suite's app grid, grouped by category. Tapping a module logs an "open" event
/// to Snappet Core (so the dashboard tracks usage of every app for free) and routes
/// to the module's own screen.
struct AppLibraryView: View {
    @Environment(SnappetCore.self) private var core
    @State private var router = SuiteRouter()
    /// Drives the zoom transition from a tapped module card into the module's screen (iOS 18).
    @Namespace private var moduleZoom
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
                                        .buttonStyle(.plain)
                                        .matchedTransitionSource(id: module.id, in: moduleZoom)
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
            .navigationTitle("Apps")
            .navigationDestination(for: ModuleRoute.self) { route in
                moduleDestination(route)
            }
        }
        .environment(router)
    }

    /// The mini-app for a pushed `ModuleRoute`, logging an "open" event (as the old NavigationLink did).
    @ViewBuilder private func moduleDestination(_ route: ModuleRoute) -> some View {
        if let module = ModuleRegistry.all.first(where: { $0.id == route.id }) {
            module.destination()
                .navigationTransition(.zoom(sourceID: module.id, in: moduleZoom))
                .onAppear {
                    core.log(module: module.id, action: "open", summary: "Opened \(module.title)")
                }
        }
    }
}

private struct ModuleCard: View {
    let module: AppModule
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: module.systemImage)
                .font(.title)
                .foregroundStyle(module.tint)
            Text(module.title).font(.headline).lineLimit(1)
            Text(module.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding()
        .background(module.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}
