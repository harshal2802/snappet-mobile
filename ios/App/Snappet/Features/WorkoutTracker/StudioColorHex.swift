import SwiftUI

extension Color {
    /// Parse a `#RRGGBB` hex string (matches `StudioOverlays.uiColor`); falls back to white.
    /// Shared by the studio's overlay chips, HR chart, and colour pickers.
    init(studioHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .white; return }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
