import CoreGraphics

/// "Snappet Pulse" spacing scale (issue #30 §4) — a 4-pt base, used everywhere instead
/// of ad-hoc padding literals.
enum SnappetSpacing {
    /// 4 pt.
    static let xs: CGFloat = 4
    /// 8 pt.
    static let sm: CGFloat = 8
    /// 12 pt.
    static let md: CGFloat = 12
    /// 16 pt.
    static let lg: CGFloat = 16
    /// 24 pt.
    static let xl: CGFloat = 24
    /// 32 pt.
    static let xxl: CGFloat = 32
}
