import SwiftUI

/// Module descriptor for the Split Expenses mini-app. The App Library reads this to
/// render the tile and route into `ExpenseRootView`.
enum ExpenseModule {
    @MainActor static var module: AppModule {
        AppModule(id: "expense", title: "Split Expenses", subtitle: "Settle up with friends",
                  systemImage: "person.2", tint: SnappetColor.moduleAccent("expense"), category: .finance) { ExpenseRootView() }
    }
}
