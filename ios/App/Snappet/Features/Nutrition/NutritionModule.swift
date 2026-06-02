import SwiftUI

/// Module descriptor for the Nutrition mini-app.
enum NutritionModule {
    @MainActor static var module: AppModule {
        AppModule(
            id: "nutrition",
            title: "Nutrition",
            subtitle: "Calories & macros",
            systemImage: "fork.knife",
            tint: SnappetColor.moduleAccent("nutrition"),
            category: .fitness
        ) { NutritionRootView() }
    }
}
