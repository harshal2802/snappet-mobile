import SwiftUI

/// Renders a climb on the Kilter board: the **full hold grid** as faint markers with the climb's lit
/// holds drawn as role-colored rings on top (matching the on-wall LED-ring look). The official
/// wood/hold photo isn't bundled, so the backdrop is schematic — but every hole is shown, so a climb
/// reads in real board context instead of as a few dots floating in space.
///
/// `geometry` (the grid + aspect ratio) and `holds` both arrive normalized to the *same* board extent
/// from `KilterCatalog`, so the lit holds line up exactly with the grid. Drawn with a single `Canvas`
/// (cheap for the ~700-hole grid).
struct KilterBoardView: View {
    let geometry: KilterBoardGeometry
    let holds: [KilterHold]
    /// When true (illumination preview), holds glow filled on a dark board.
    var lit: Bool = false

    var body: some View {
        Canvas { ctx, size in
            let unit = min(size.width, size.height)
            let holdD = max(12, unit * 0.052)            // lit-hold ring diameter
            let r = holdD / 2
            // Map a normalized point into the view, inset by the ring radius so edge holds aren't clipped.
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: r + x * (size.width - holdD), y: r + y * (size.height - holdD))
            }

            // 1) The faint full hold grid — board context.
            let gridColor: Color = lit ? .white.opacity(0.10) : .gray.opacity(0.28)
            let gd = holdD * 0.32
            for p in geometry.grid {
                let c = pt(p.x, p.y)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - gd / 2, y: c.y - gd / 2, width: gd, height: gd)),
                         with: .color(gridColor))
            }

            // 2) The climb's lit holds, role-colored, drawn on top.
            for hold in holds {
                let color = Color(hex: hold.colorHex)
                let d = holdD * scale(for: hold.role)
                let c = pt(hold.x, hold.y)
                let rect = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
                if lit {
                    // soft glow + solid core
                    var glow = ctx
                    glow.addFilter(.blur(radius: d * 0.35))
                    glow.fill(Path(ellipseIn: rect.insetBy(dx: -d * 0.15, dy: -d * 0.15)), with: .color(color.opacity(0.8)))
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                } else {
                    ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: max(2.5, d * 0.17))
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

    @ViewBuilder private var boardBackground: some View {
        if lit {
            LinearGradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.08), .black],
                           startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(colors: [Color(.secondarySystemBackground), Color(.tertiarySystemBackground)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
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
