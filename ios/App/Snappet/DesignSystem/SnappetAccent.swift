import SwiftUI
import UIKit
import WidgetKit

// `SnappetAccent` (the palette itself) lives in Shared/SnappetAccentPalette.swift so the widget extension can
// read it too (prompt 243).

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
            .onAppear {
                Self.applyToWindows(accent: accent, mode: mode)
                Self.publishToWidgets(accent)
            }
            .onChange(of: accentRaw) {
                Self.applyToWindows(accent: accent, mode: mode)
                Self.publishToWidgets(accent)
            }
            .onChange(of: modeRaw) { Self.applyToWindows(accent: accent, mode: mode) }
    }

    /// The widget extension reads the accent from the App Group (prompt 243); reload its timelines when it changes.
    static func publishToWidgets(_ accent: SnappetAccent) {
        if SnappetAccent.publish(accent) { WidgetCenter.shared.reloadAllTimelines() }
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
