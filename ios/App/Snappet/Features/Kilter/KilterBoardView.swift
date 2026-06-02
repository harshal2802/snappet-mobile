import SwiftUI

/// Renders a climb's holds on a neutral board.
///
/// Holds come pre-normalized (`x`,`y` in 0…1, y from the top) from `KilterCatalog`, colored by their
/// role. We draw an outlined ring per hold (matching the on-wall look where the LED rings the hold)
/// rather than a filled dot. The official wood/hold background image isn't bundled (it lives in the
/// Kilter app's image assets, not the DB), so we render on a plain board — coordinates are exact, the
/// backdrop is schematic.
struct KilterBoardView: View {
    let holds: [KilterHold]
    /// When true (illumination preview), holds are filled and glow on a dark board.
    var lit: Bool = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(lit ? Color.black : Color(.secondarySystemBackground))
                ForEach(holds) { hold in
                    let p = CGPoint(x: hold.x * size.width, y: hold.y * size.height)
                    let color = Color(hex: hold.colorHex)
                    let d = max(10.0, min(size.width, size.height) * 0.05)
                    if lit {
                        Circle().fill(color)
                            .frame(width: d, height: d)
                            .shadow(color: color, radius: d * 0.5)
                            .position(p)
                    } else {
                        Circle().stroke(color, lineWidth: 3)
                            .frame(width: d, height: d)
                            .position(p)
                    }
                }
            }
        }
        .aspectRatio(0.95, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Board with \(holds.count) holds")
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
