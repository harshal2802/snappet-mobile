import SwiftUI

/// Renders a climb on the Kilter board: the **full hold grid** as faint markers with the climb's lit
/// holds drawn on top, **shape-coded by role** (start = triangle, hand = circle, finish = square,
/// foot = diamond — see `KilterHoldShape`). Shape is a redundant channel alongside the role color, so a
/// color-blind climber can read the route without separating the hues. The official wood/hold photo
/// isn't bundled (#42 — copyrighted Aurora assets), so the backdrop is schematic — but it's drawn at the
/// user's selected board size and shows every hole, so a climb reads in real board context.
///
/// `geometry` (the grid + aspect ratio) and `holds` both arrive normalized to the *same* board extent
/// **at the selected size** from `KilterCatalog`, so the lit holds line up exactly with the grid. Drawn
/// with a single `Canvas` (cheap for the ~700-hole grid).
struct KilterBoardView: View {
    let geometry: KilterBoardGeometry
    let holds: [KilterHold]
    /// When true (illumination preview), holds glow filled on a dark board.
    var lit: Bool = false
    /// Your own straightened photo of this board (prompt 215), drawn behind the holds.
    var photo: UIImage? = nil
    /// The photo's line-up check: draw every hole as a small accent dot over the photo.
    var showsGridOverPhoto = false

    var body: some View {
        Canvas { ctx, size in
            let unit = min(size.width, size.height)
            let holdD = max(12, unit * 0.052)            // lit-hold ring diameter
            let r = holdD / 2
            // Map a normalized point into the view, inset by the ring radius so edge holds aren't clipped.
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: r + x * (size.width - holdD), y: r + y * (size.height - holdD))
            }

            // 0) Your photo: the straightened image maps the hole area to pt(0,0)…pt(1,1), plus its margin.
            if let photo {
                let area = CGRect(origin: pt(0, 0), size: CGSize(width: size.width - holdD, height: size.height - holdD))
                ctx.draw(Image(uiImage: photo), in: KilterBoardPhotoMath.photoRect(holeArea: area))
            }

            // 1) The faint full hold grid — board context (the photo shows the real holes instead).
            let gridColor: Color = photo != nil ? SnappetColor.brand.opacity(0.9)
                : lit ? .white.opacity(0.10) : .gray.opacity(0.28)
            let gd = holdD * (photo != nil ? 0.22 : 0.32)
            for p in (photo == nil || showsGridOverPhoto) ? geometry.grid : [] {
                let c = pt(p.x, p.y)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - gd / 2, y: c.y - gd / 2, width: gd, height: gd)),
                         with: .color(gridColor))
            }

            // 2) The climb's lit holds, role-colored AND role-shaped (color-blind redundant channel).
            for hold in holds {
                let color = Color(hex: hold.colorHex)
                let d = holdD * scale(for: hold.role)
                let c = pt(hold.x, hold.y)
                let rect = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
                let shape = KilterHoldShape.forRole(hold.role)
                if lit {
                    // soft glow + solid core, in the role's shape
                    var glow = ctx
                    glow.addFilter(.blur(radius: d * 0.35))
                    glow.fill(Self.holdPath(shape, in: rect.insetBy(dx: -d * 0.15, dy: -d * 0.15)),
                              with: .color(color.opacity(0.8)))
                    ctx.fill(Self.holdPath(shape, in: rect), with: .color(color))
                } else {
                    if photo != nil {
                        // A dark halo so the role colour reads on a busy wall.
                        ctx.stroke(Self.holdPath(shape, in: rect), with: .color(.black.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: max(2.5, d * 0.17) + 2.5, lineJoin: .round))
                    }
                    ctx.stroke(Self.holdPath(shape, in: rect), with: .color(color),
                               style: StrokeStyle(lineWidth: max(2.5, d * 0.17), lineJoin: .round))
                }
            }
        }
        .background(boardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(lit ? 0.18 : 0.08), lineWidth: 1)
        )
        .aspectRatio(geometry.aspect > 0 ? geometry.aspect : 1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Board diagram showing \(holds.count) holds for this climb")
    }

    /// Foot holds read smaller; start/finish a touch larger so the route's anchors pop.
    private func scale(for role: String) -> Double {
        switch role {
        case "foot": return 0.74
        case "start", "finish": return 1.14
        default: return 1.0
        }
    }

    /// The role's marker path inscribed in `rect` (circle/triangle/square/diamond). Shared with the
    /// detail screen's legend so the on-board shapes and the legend can't drift. `lineJoin: .round` is
    /// applied by the caller when stroking so the polygon corners read cleanly at small sizes.
    static func holdPath(_ shape: KilterHoldShape, in rect: CGRect) -> Path {
        switch shape {
        case .circle:
            return Path(ellipseIn: rect)
        case .square:
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.16, style: .continuous)
        case .triangle:
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        case .diamond:
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
            return p
        }
    }

    @ViewBuilder private var boardBackground: some View {
        if photo != nil {
            Color.black
        } else if lit {
            LinearGradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.08), .black],
                           startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(colors: [Color(.secondarySystemBackground), Color(.tertiarySystemBackground)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// A `Shape` wrapper around `KilterBoardView.holdPath` so SwiftUI views (the detail screen's role
/// legend) can stroke/fill a role's marker with the exact geometry the board draws — one source of
/// truth for the shape code.
struct KilterHoldMark: Shape {
    let shape: KilterHoldShape
    func path(in rect: CGRect) -> Path { KilterBoardView.holdPath(shape, in: rect) }
}

extension Color {
    /// Build a Color from a 6-digit hex string (no `#`), defaulting to gray on bad input.
    init(hex: String) {
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value), hex.count == 6 else {
            self = .gray
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
