import Foundation
import CoreGraphics

// MARK: - Clips grid zoom — Photos-style levels, pure geometry (2026-10-10)
//
// The grid has three zoom levels — All (3 across) → Months (5) → Year (9-across mosaic, wireframe option A in
// docs/ux-research/clips-grid/zoom-levels.png) — and a pinch moves between them the way Photos does: every
// cover slides + resizes in step with the fingers and the cover under them stays put. The SwiftUI LazyVGrid
// couldn't: switching its column count re-laid the whole grid on main in one go (370–620 ms freezes,
// measured on device). `ClipGridZoomLayout` (UIKit) draws from this geometry instead — a cover's frame at any
// level is arithmetic, so a zoom just interpolates two frames per visible cover. No UIKit here; unit-tested.

enum ClipGridLevel: Int, CaseIterable, Identifiable {
    case year = 9, months = 5, all = 3

    var id: Int { rawValue }
    var columns: Int { rawValue }
    /// Year's mosaic is tighter.
    var spacing: CGFloat { self == .year ? 1 : 2 }
    var title: String {
        switch self { case .year: "Year"; case .months: "Months"; case .all: "All" }
    }
    /// Pinch in → more per row.
    var denser: ClipGridLevel? { self == .all ? .months : self == .months ? .year : nil }
    /// Pinch out → bigger covers.
    var bigger: ClipGridLevel? { self == .year ? .months : self == .months ? .all : nil }
    /// Month headers pin while you scroll; the year mosaic's small labels don't.
    var pinsHeaders: Bool { self != .year }

    /// The remembered column count → level (anything unknown → All).
    init(columns: Int) { self = ClipGridLevel(rawValue: columns) ?? .all }
}

/// Where every header and cover sits at one level. Sections are months; each has a header then rows of covers.
struct ClipGridGeometry: Equatable {
    struct Section: Equatable {
        var count: Int
        var headerHeight: CGFloat
    }

    let columns: Int
    let spacing: CGFloat
    let width: CGFloat
    let sections: [Section]
    let side: CGFloat
    /// Each section's header top.
    let tops: [CGFloat]
    let contentHeight: CGFloat

    init(level: ClipGridLevel, width: CGFloat, sections: [Section]) {
        self.init(columns: level.columns, spacing: level.spacing, width: width, sections: sections)
    }

    init(columns: Int, spacing: CGFloat, width: CGFloat, sections: [Section]) {
        self.columns = max(1, columns)
        self.spacing = spacing
        self.width = width
        self.sections = sections
        let n = CGFloat(self.columns)
        side = max(1, (width - 2 * spacing - (n - 1) * spacing) / n)    // edge gutters = spacing
        var y: CGFloat = 0
        var tops: [CGFloat] = []
        for s in sections {
            tops.append(y)
            y += s.headerHeight + Self.rowsHeight(count: s.count, columns: self.columns, side: side, spacing: spacing)
        }
        self.tops = tops
        contentHeight = y
    }

    private static func rowsHeight(count: Int, columns: Int, side: CGFloat, spacing: CGFloat) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return rows == 0 ? 0 : CGFloat(rows) * side + CGFloat(rows) * spacing   // trailing gap separates months
    }

    func headerFrame(_ s: Int) -> CGRect {
        CGRect(x: 0, y: tops[s], width: width, height: sections[s].headerHeight)
    }

    func sectionBottom(_ s: Int) -> CGFloat {
        tops[s] + sections[s].headerHeight
            + Self.rowsHeight(count: sections[s].count, columns: columns, side: side, spacing: spacing)
    }

    /// A pinned header: stuck to the top edge (`offset`) while its month scrolls under it, pushed up by the next.
    func pinnedHeaderFrame(_ s: Int, offset: CGFloat) -> CGRect {
        var f = headerFrame(s)
        f.origin.y = max(tops[s], min(offset, sectionBottom(s) - f.height))
        return f
    }

    func itemFrame(_ s: Int, _ i: Int) -> CGRect {
        let row = i / columns, col = i % columns
        return CGRect(x: spacing + CGFloat(col) * (side + spacing),
                      y: tops[s] + sections[s].headerHeight + CGFloat(row) * (side + spacing),
                      width: side, height: side)
    }

    /// The sections overlapping `minY…maxY` (binary search on the header tops).
    func sections(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        guard !sections.isEmpty else { return 0..<0 }
        var lo = 0, hi = sections.count - 1
        while lo < hi {                       // last section whose top ≤ minY
            let mid = (lo + hi + 1) / 2
            if tops[mid] <= minY { lo = mid } else { hi = mid - 1 }
        }
        var end = lo
        while end < sections.count, tops[end] < maxY { end += 1 }
        return lo..<max(lo + 1, end)
    }

    /// The covers of section `s` whose rows overlap `minY…maxY`.
    func items(in s: Int, from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        let count = sections[s].count
        guard count > 0 else { return 0..<0 }
        let start = tops[s] + sections[s].headerHeight, pitch = side + spacing
        let firstRow = max(0, Int(((minY - start) / pitch).rounded(.down)))
        let lastRow = Int(((maxY - start) / pitch).rounded(.down))
        guard lastRow >= firstRow else { return 0..<0 }
        let lo = min(count, firstRow * columns), hi = min(count, (lastRow + 1) * columns)
        return lo..<hi
    }

    /// The cover at (or nearest) a content point — on a header, its month's first cover.
    func item(near p: CGPoint) -> (section: Int, item: Int)? {
        let r = sections(from: p.y, to: p.y + 1)
        guard let s = r.first, sections[s].count > 0 else { return nil }
        let start = tops[s] + sections[s].headerHeight
        guard p.y >= start else { return (s, 0) }
        let row = Int(((p.y - start) / (side + spacing)).rounded(.down))
        let col = min(columns - 1, max(0, Int(((p.x - spacing) / (side + spacing)).rounded(.down))))
        return (s, min(sections[s].count - 1, row * columns + col))
    }
}

enum ClipGridZoom {
    /// How far a pinch at `scale` has carried the grid from `from` toward `to` (0…, past 1 = beyond `to`).
    /// Log-scaled, so it tracks the covers' visual size: 3 → 5 completes at 0.6×, 5 → 3 at 1.67×.
    static func progress(scale: Double, from: ClipGridLevel, to: ClipGridLevel) -> Double {
        let ratio = Double(from.columns) / Double(to.columns)
        guard scale > 0, scale.isFinite, ratio != 1 else { return 0 }
        return max(0, log(scale) / log(ratio))
    }

    /// On release: finish if past halfway (unless flicked back), or if flicked toward the target.
    /// `towardVelocity` is the pinch velocity in the target's direction (scale / s, positive = toward).
    static func settles(progress: Double, towardVelocity: Double) -> Bool {
        progress >= 0.5 ? towardVelocity > -0.8 : (progress > 0.05 && towardVelocity > 0.5)
    }

    /// The scroll offset that keeps the anchored cover where it is on screen after the zoom, clamped to the
    /// content. `screenY` is the anchor's distance from the visible top; `fraction` is where in the cover it was.
    static func anchoredOffset(item: (section: Int, item: Int), fraction: CGFloat, screenY: CGFloat,
                               in g: ClipGridGeometry, viewport: CGFloat) -> CGFloat {
        let f = g.itemFrame(item.section, item.item)
        let y = f.minY + fraction * f.height - screenY
        return min(max(0, g.contentHeight - viewport), max(0, y))
    }

    /// The zoom's ease when it finishes on its own (button, segment, or the rest of a released pinch).
    static func ease(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return 1 - pow(1 - c, 3)                 // ease-out cubic
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
               width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }
}
