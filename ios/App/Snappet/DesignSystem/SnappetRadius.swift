import CoreGraphics

/// "Snappet Pulse" corner-radius scale (issue #30 §4) — kills the 14-vs-16 drift across
/// cards and tiles.
enum SnappetRadius {
    /// 10 pt — small chips / inputs.
    static let sm: CGFloat = 10
    /// 16 pt — cards / tiles (the suite default).
    static let md: CGFloat = 16
    /// 24 pt — large hero surfaces.
    static let lg: CGFloat = 24
}
