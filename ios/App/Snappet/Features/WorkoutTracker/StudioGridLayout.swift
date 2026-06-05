import Foundation
import CoreGraphics

/// **Pure** layout maths for arranging picture-in-picture (`.video`) overlays into collage **grids**
/// and for **snapping** a dragged/resized PiP to alignment lines (rule-of-thirds, centre, canvas
/// edges). Normalized throughout (0…1, top-left origin) so it's resolution-independent and unit-tested
/// without a device — the view model maps the results onto `OverlayItem` frames and the canvas draws
/// the returned guide lines.
enum StudioGridLayout {

    /// One placed cell: a normalized centre + size (fractions of the canvas).
    struct Cell: Equatable {
        var center: CGPoint
        var size: CGSize
    }

    /// A one-tap collage layout. Each case lays its clips edge-to-edge filling the whole canvas.
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case sideBySide      // 1×2 — two columns
        case stacked         // 2×1 — two rows
        case quad            // 2×2 — four cells
        case thirdsRow       // 1×3 — three columns
        case thirdsColumn    // 3×1 — three rows

        var id: String { rawValue }
        var label: String {
            switch self {
            case .sideBySide: return "1×2"
            case .stacked: return "2×1"
            case .quad: return "2×2"
            case .thirdsRow: return "1×3"
            case .thirdsColumn: return "3×1"
            }
        }

        /// The preset's full cell list (in fill order), filling the unit canvas.
        var cells: [Cell] {
            switch self {
            case .sideBySide:
                return columns(2)
            case .stacked:
                return rows(2)
            case .quad:
                return [Cell(center: CGPoint(x: 0.25, y: 0.25), size: CGSize(width: 0.5, height: 0.5)),
                        Cell(center: CGPoint(x: 0.75, y: 0.25), size: CGSize(width: 0.5, height: 0.5)),
                        Cell(center: CGPoint(x: 0.25, y: 0.75), size: CGSize(width: 0.5, height: 0.5)),
                        Cell(center: CGPoint(x: 0.75, y: 0.75), size: CGSize(width: 0.5, height: 0.5))]
            case .thirdsRow:
                return columns(3)
            case .thirdsColumn:
                return rows(3)
            }
        }

        private func columns(_ n: Int) -> [Cell] {
            let w = 1.0 / Double(n)
            return (0..<n).map { i in
                Cell(center: CGPoint(x: (Double(i) + 0.5) * w, y: 0.5), size: CGSize(width: w, height: 1))
            }
        }
        private func rows(_ n: Int) -> [Cell] {
            let h = 1.0 / Double(n)
            return (0..<n).map { i in
                Cell(center: CGPoint(x: 0.5, y: (Double(i) + 0.5) * h), size: CGSize(width: 1, height: h))
            }
        }
    }

    /// The first `count` cells of a preset — the frames to assign to the first `count` PiP overlays
    /// (extra overlays beyond the preset's capacity keep their current frame).
    static func frames(preset: Preset, count: Int) -> [Cell] {
        Array(preset.cells.prefix(max(0, count)))
    }

    // MARK: - Snapping

    /// An alignment guide to draw while a PiP is dragged/resized.
    struct Guide: Equatable {
        enum Axis { case vertical, horizontal }
        var axis: Axis
        /// Normalized 0…1 position of the line (x for vertical, y for horizontal).
        var position: Double
    }

    /// The lines a PiP snaps to: canvas edges, centre, and the rule-of-thirds.
    static let snapLines: [Double] = [0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1]

    /// Snap a PiP's `center` (for the given `size`) to the nearest alignment line within `threshold`
    /// (normalized). Each axis independently snaps whichever of the centre / leading-edge / trailing-edge
    /// is closest to a line. Returns the (possibly unchanged) centre plus the guide lines that caught.
    static func snap(center: CGPoint, size: CGSize, threshold: Double = 0.02)
        -> (center: CGPoint, guides: [Guide]) {
        var guides: [Guide] = []
        let x = snapAxis(value: center.x, half: size.width / 2, threshold: threshold)
        if let line = x.line { guides.append(Guide(axis: .vertical, position: line)) }
        let y = snapAxis(value: center.y, half: size.height / 2, threshold: threshold)
        if let line = y.line { guides.append(Guide(axis: .horizontal, position: line)) }
        return (CGPoint(x: x.value, y: y.value), guides)
    }

    /// Snap one axis: pick the smallest-delta match among {centre, leading edge, trailing edge} → a
    /// snap line, and shift the centre so that feature lands on the line. No match → unchanged.
    private static func snapAxis(value: Double, half: Double, threshold: Double)
        -> (value: Double, line: Double?) {
        var bestDelta = threshold
        var bestShift = 0.0
        var bestLine: Double?
        for feature in [value, value - half, value + half] {
            for line in snapLines {
                let delta = abs(feature - line)
                if delta < bestDelta {
                    bestDelta = delta
                    bestShift = line - feature
                    bestLine = line
                }
            }
        }
        return (value + bestShift, bestLine)
    }
}
