import SwiftUI

/// Module descriptor for the Quick Journal mini-app. The App Library reads this to
/// render the tile and route into `JournalRootView`.
enum JournalModule {
    @MainActor static var module: AppModule {
        AppModule(id: "journal", title: "Journal", subtitle: "Quick notes & entries",
                  systemImage: "book.closed", tint: .indigo, category: .productivity) { JournalRootView() }
    }
}
