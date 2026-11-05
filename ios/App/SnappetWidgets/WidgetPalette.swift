import SwiftUI
import UIKit

/// Colours for the widgets and Live Activities (design-system restyle, prompt 243). The app's `SnappetColor` isn't
/// compiled into this extension, so this mirrors the few tokens they need. The accent is the one the user picked,
/// published by the app into the App Group.
enum WidgetPalette {
    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// The accent for a system background (light or dark), e.g. the Today widget.
    static var accent: Color {
        let a = SnappetAccent.stored()
        return dynamic(light: a.light, dark: a.dark)
    }

    /// The accent on the always-dark surfaces: Live Activities and the Buddy / Household widgets.
    static var accentOnDark: Color { rgb(SnappetAccent.stored().dark) }

    // Meaning colours (dark values; these surfaces are dark): fresh / recovered, paused / low, overdue.
    static let fresh = rgb(0x5BC074)
    static let warn = rgb(0xF59E0B)
    static let hard = rgb(0xFF6A5C)
}
