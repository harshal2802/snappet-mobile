import SwiftUI

/// Module descriptor for the Tip Calculator mini-app. The App Library reads this to
/// render the tile and route into `TipRootView`.
enum TipModule {
    @MainActor static var module: AppModule {
        AppModule(id: "tip", title: "Tip Calculator", subtitle: "Split the bill",
                  systemImage: "dollarsign.circle", tint: SnappetColor.moduleAccent("tip"), category: .finance) { TipRootView() }
    }
}
