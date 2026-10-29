import SwiftUI

/// The type scale (design-system reset, prompt 211). Five styles, regular weights, no tracked ALL-CAPS — the
/// review against a reference app found Snappet cards mixing 4–5 heavy, letter-spaced styles each. New screens use
/// these; existing screens move over one at a time.
enum SnappetType {
    /// Screen title ("Today").
    static let screenTitle = Font.system(size: 30, weight: .semibold)
    /// A card's headline ("Chiro Thoracic Rehab").
    static let title = Font.system(size: 17, weight: .semibold)
    /// Body copy.
    static let body = Font.system(size: 15)
    /// The grey line under a title ("About 56 min · +135 XP").
    static let detail = Font.system(size: 13)
    /// The small label above a value ("This week") — sentence case, not tracked caps.
    static let label = Font.system(size: 11.5)
    /// A big number ("382") — light weight; pair with `metricUnit`.
    static let metric = Font.system(size: 30, weight: .light)
    /// The unit after a big number ("XP", "weeks").
    static let metricUnit = Font.system(size: 14)
}

extension View {
    /// A card headline in primary text.
    func snappetTitle() -> some View { font(SnappetType.title).foregroundStyle(SnappetColor.ink) }
    /// The grey line under a title.
    func snappetDetail() -> some View { font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary) }
    /// The small label above a value.
    func snappetLabel() -> some View { font(SnappetType.label).foregroundStyle(SnappetColor.textSecondary) }
}
