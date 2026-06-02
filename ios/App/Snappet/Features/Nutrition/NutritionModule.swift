import SwiftUI

/// The Calorie & Nutrition mini-app: log foods, track calories + macros against a daily
/// budget, and review history. Vends its descriptor to the App Library and routes to
/// `NutritionRootView`. Logging a food records to `SnappetCore` so the Home dashboard can
/// aggregate nutrition activity alongside the rest of the suite, and writes the meal to
/// HealthKit / Health Connect.
enum NutritionModule {
    @MainActor
    static var module: AppModule {
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
</content>
