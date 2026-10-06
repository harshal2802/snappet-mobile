import SwiftUI

/// The Household mini-app: a shared chore board the household works through together (household
/// prompt 01; wireframes `docs/ux-research/household-chores/`). P1 is one phone; the log it keeps is
/// what P2 syncs between phones.
enum HouseholdModule {
    @MainActor
    static var module: AppModule {
        AppModule(
            id: "household",
            title: "Household",
            subtitle: "Shared chores",
            systemImage: "house",
            tint: SnappetColor.moduleAccent("household"),
            category: .lifestyle
        ) { HouseholdRootView() }
    }
}
