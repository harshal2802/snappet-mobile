import SwiftUI

/// Module descriptor for the Kilter Board mini-app. The App Library reads this to render the tile
/// and route into `KilterRootView`.
enum KilterModule {
    @MainActor static var module: AppModule {
        AppModule(id: "kilter", title: "Kilter Board", subtitle: "Browse & log board climbs",
                  systemImage: "figure.climbing", tint: .orange, category: .fitness) { KilterRootView() }
    }
}
