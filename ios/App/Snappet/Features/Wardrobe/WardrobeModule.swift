import SwiftUI

/// Module descriptor for the Wardrobe mini-app — "your private AI stylist". First
/// resident of the Lifestyle category; rose accent (`SnappetColor.wardrobe`).
enum WardrobeModule {
    @MainActor static var module: AppModule {
        AppModule(id: "wardrobe", title: "Wardrobe", subtitle: "Your private AI stylist",
                  systemImage: "hanger", tint: SnappetColor.moduleAccent("wardrobe"),
                  category: .lifestyle) { WardrobeRootView() }
    }
}
