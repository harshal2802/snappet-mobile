import SwiftUI
import UIKit

/// The user-pickable accent (design-system reset, prompt 211). Snappet uses ONE accent per screen — the primary
/// action, progress, the highlighted data — and neutrals for everything else. Settings → Appearance picks it;
/// Periwinkle is the default (user's pick, 2026-10-29, after a review against a reference app).
///
/// Each accent has a light-mode and a dark-mode value: the dark value is lighter (it sits on near-black), the
/// light value darker (it sits on white), so text on the accent (`onBrand`) stays readable in both.
enum SnappetAccent: String, CaseIterable, Identifiable, Sendable {
    case periwinkle, glacier, teal, coral

    static let defaultsKey = "appearance.accent"
    static let `default`: SnappetAccent = .periwinkle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .periwinkle: return "Periwinkle"
        case .glacier: return "Glacier"
        case .teal: return "Teal"
        case .coral: return "Coral"
        }
    }

    /// 0xRRGGBB on a light background.
    var light: UInt32 {
        switch self {
        case .periwinkle: return 0x4F5FD9
        case .glacier: return 0x1A73B8
        case .teal: return 0x0F7F76
        case .coral: return 0xD13F33   // darkened from 0xE5483D: white text needs ≥ 4.5:1 (was 3.9)
        }
    }

    /// 0xRRGGBB on a dark background.
    var dark: UInt32 {
        switch self {
        case .periwinkle: return 0x8EA2FF
        case .glacier: return 0x7CC8F5
        case .teal: return 0x4FD1C5
        case .coral: return 0xFF7A6B
        }
    }

    /// Text / icons on a filled accent: white on the (darker) light-mode accent, near-black ink on the (lighter)
    /// dark-mode accent.
    static let onLight: UInt32 = 0xFFFFFF
    static let onDark: UInt32 = 0x0B1030

    /// The stored accent, falling back to the default for a missing / unknown value.
    static func resolve(_ raw: String?) -> SnappetAccent { raw.flatMap(SnappetAccent.init(rawValue:)) ?? .default }
}

/// System / Dark / Light (Settings → Appearance).
enum SnappetAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, dark, light
    static let defaultsKey = "appearance.mode"
    var id: String { rawValue }
    var label: String { self == .system ? "System" : self == .dark ? "Dark" : "Light" }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .dark ? .dark : .light) }
    var interfaceStyle: UIUserInterfaceStyle { self == .system ? .unspecified : (self == .dark ? .dark : .light) }
}

// MARK: - Live, app-wide accent
//
// `SnappetColor.brand` is used in ~80 places and `.tint` in ~150, so the accent can't be threaded through call sites.
// Instead it's a UIKit trait bridged to a SwiftUI environment value: the root sets the environment, SwiftUI carries
// it into every hosted view's trait collection, and `brand`'s dynamic UIColor reads it at resolve time — so a change
// repaints every screen in place, without rebuilding views or losing navigation / sheet state.

struct SnappetAccentTrait: UITraitDefinition {
    static let defaultValue: String = SnappetAccent.default.rawValue
    static let affectsColorAppearance = true
    static let name = "SnappetAccent"
}

extension UITraitCollection {
    var snappetAccent: SnappetAccent { SnappetAccent.resolve(self[SnappetAccentTrait.self]) }
}

extension UIMutableTraits {
    var snappetAccent: SnappetAccent {
        get { SnappetAccent.resolve(self[SnappetAccentTrait.self]) }
        set { self[SnappetAccentTrait.self] = newValue.rawValue }
    }
}

struct SnappetAccentKey: EnvironmentKey {
    static let defaultValue: SnappetAccent = .default
}

extension SnappetAccentKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> SnappetAccent { traitCollection.snappetAccent }
    static func write(to mutableTraits: inout UIMutableTraits, value: SnappetAccent) { mutableTraits.snappetAccent = value }
}

extension EnvironmentValues {
    var snappetAccent: SnappetAccent {
        get { self[SnappetAccentKey.self] }
        set { self[SnappetAccentKey.self] = newValue }
    }
}

/// Applies the stored accent + appearance at the app root: the bridged environment (SwiftUI-hosted views), the
/// window scenes' trait overrides (UIKit-presented views, e.g. share sheets), the colour scheme and the tint.
struct SnappetThemeModifier: ViewModifier {
    @AppStorage(SnappetAccent.defaultsKey) private var accentRaw = SnappetAccent.default.rawValue
    @AppStorage(SnappetAppearance.defaultsKey) private var modeRaw = SnappetAppearance.system.rawValue

    func body(content: Content) -> some View {
        let accent = SnappetAccent.resolve(accentRaw)
        let mode = SnappetAppearance(rawValue: modeRaw) ?? .system
        content
            .environment(\.snappetAccent, accent)
            .tint(SnappetColor.brand)
            .preferredColorScheme(mode.colorScheme)
            .onAppear { Self.applyToWindows(accent: accent, mode: mode) }
            .onChange(of: accentRaw) { Self.applyToWindows(accent: accent, mode: mode) }
            .onChange(of: modeRaw) { Self.applyToWindows(accent: accent, mode: mode) }
    }

    @MainActor static func applyToWindows(accent: SnappetAccent, mode: SnappetAppearance) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.traitOverrides.snappetAccent = accent
            for window in scene.windows { window.overrideUserInterfaceStyle = mode.interfaceStyle }
        }
    }
}

extension View {
    /// The app root's theme (accent + appearance). Apply once, at the top.
    func snappetTheme() -> some View { modifier(SnappetThemeModifier()) }
}
