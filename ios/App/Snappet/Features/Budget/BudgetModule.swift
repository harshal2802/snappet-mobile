import SwiftUI

/// The Budget mini-app: a monthly spending tracker. Vends its descriptor to the App
/// Library and routes to `BudgetRootView`. Logging a transaction records to
/// `SnappetCore` so the Home dashboard can aggregate spending alongside the suite.
enum BudgetModule {
    @MainActor
    static var module: AppModule {
        AppModule(
            id: "budget",
            title: "Budget",
            subtitle: "Track monthly spending",
            systemImage: "chart.pie",
            tint: .blue,
            category: .finance
        ) { BudgetRootView() }
    }
}
