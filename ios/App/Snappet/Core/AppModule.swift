import SwiftUI

/// Category groupings for the App Library.
enum ModuleCategory: String, CaseIterable, Identifiable {
    case fitness, productivity, finance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fitness: return "Fitness"
        case .productivity: return "Productivity"
        case .finance: return "Finance"
        }
    }
}

/// A self-contained mini-app in the suite. Each module is a feature folder that
/// vends one of these descriptors; the App Library renders them and routes to
/// `destination`. Mini-apps log activity to `SnappetCore` so the Home dashboard can
/// aggregate historical usage across the whole suite.
struct AppModule: Identifiable {
    /// Stable id — also used as the `module` key in `UsageRecord`.
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let category: ModuleCategory
    /// The module's root screen. Wrapped in `AnyView` so heterogeneous modules live
    /// in one array.
    let destination: () -> AnyView

    init(id: String, title: String, subtitle: String, systemImage: String,
         tint: Color, category: ModuleCategory, @ViewBuilder destination: @escaping () -> some View) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.category = category
        self.destination = { AnyView(destination()) }
    }
}
