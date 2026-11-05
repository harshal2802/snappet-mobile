import Foundation

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

// MARK: - The App-Group copy (prompt 243)

extension SnappetAccent {
    /// The widget extension can't read the app's own defaults, so the app mirrors the accent into the App Group.
    static let appGroupKey = "appearance.accent"

    static var appGroupDefaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshotStore.appGroupID) }

    /// The accent the app last published, or the default when nothing was written yet.
    static func stored(in defaults: UserDefaults? = appGroupDefaults) -> SnappetAccent {
        resolve(defaults?.string(forKey: appGroupKey))
    }

    /// Writes the accent for the widgets. Returns true when it changed, so the caller reloads widget timelines only
    /// then.
    @discardableResult
    static func publish(_ accent: SnappetAccent, to defaults: UserDefaults? = appGroupDefaults) -> Bool {
        guard let defaults, defaults.string(forKey: appGroupKey) != accent.rawValue else { return false }
        defaults.set(accent.rawValue, forKey: appGroupKey)
        return true
    }
}
