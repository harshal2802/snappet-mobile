import SwiftUI
import UIKit

/// "Snappet Pulse" colour tokens (issue #30 §1–§2).
///
/// A calm, warm-neutral system anchored by one energetic brand accent ("Pulse Coral"),
/// plus a curated, chroma-equalized set of per-module accents used for wayfinding.
/// Every token is a *dynamic* colour that resolves per `UITraitCollection`, so light
/// and dark are both first-class with no asset-catalog entries (keeps `project.yml`
/// untouched — the `Snappet/` source glob already covers this file).
enum SnappetColor {

    // MARK: - Brand & neutrals

    /// Primary CTAs, selected nav, brand moments. Light `#FF5A4D` / dark `#FF7A6B`.
    static let brand = dynamic(light: 0xFF5A4D, dark: 0xFF7A6B)

    /// Primary text — warm near-black / warm near-white (not pure #000/#FFF).
    static let ink = dynamic(light: 0x1A1A1E, dark: 0xF4F3F1)

    /// App background — warm off-white / true-dark.
    static let paper = dynamic(light: 0xFBFAF8, dark: 0x121214)

    /// Cards / sheets.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1E1E22)

    /// Tile fills — replaces ad-hoc `tint.opacity(0.12)`.
    static let surfaceMuted = dynamic(light: 0xF2F1EE, dark: 0x26262B)

    /// Dividers / borders.
    static let hairline = dynamic(light: 0xE7E5E1, dark: 0x34343A)

    /// Captions / secondary text.
    static let textSecondary = dynamic(light: 0x6B6A66, dark: 0xA6A5A1)

    // MARK: - Curated module accents
    //
    // One accent per module for wayfinding, pulled onto a single tuned ramp so none
    // screams. The brand coral sits intentionally between Reels and Workout so the
    // fitness flagship reads as the heart of the suite.

    /// Reels — coral (matches the brand pulse).
    static let reels = dynamic(light: 0xFF5A4D, dark: 0xFF7A6B)
    /// Workout — ember-orange.
    static let workout = dynamic(light: 0xF2761E, dark: 0xFF9645)
    /// Pomodoro — tomato.
    static let pomodoro = dynamic(light: 0xE5483D, dark: 0xFF6A5C)
    /// Habits — leaf-green.
    static let habits = dynamic(light: 0x3F9D55, dark: 0x5BC074)
    /// Journal — violet.
    static let journal = dynamic(light: 0x7C5CD6, dark: 0x9D82F0)
    /// Tip — mint.
    static let tip = dynamic(light: 0x1FAE8E, dark: 0x44CBA9)
    /// Expenses — teal.
    static let expenses = dynamic(light: 0x1592A6, dark: 0x3CB5C9)
    /// Budget — azure.
    static let budget = dynamic(light: 0x2A7DE1, dark: 0x589BF2)
    /// Kilter Board — amber/sandstone (warm, earthy; distinct from reels-coral and workout-ember).
    static let kilter = dynamic(light: 0xB45309, dark: 0xF59E0B)

    // MARK: - Performance ramp (the SECOND color axis — Pulse Pro, workout-redesign E0)
    //
    // **The two-axis color contract.** Snappet now uses colour on two orthogonal axes that must NOT
    // bleed into each other:
    //   1. **Discipline accent = WAYFINDING / IDENTITY** — the curated module accents above
    //      (workout ember, kilter amber, …). Answers *who / where am I*.
    //   2. **Performance ramp = EFFORT / ZONE / STATE** — the three stops below. Answers *how hard /
    //      how recovered / is this a PR*. green → amber → red, low-saturation so it reads as data.
    // And `brand` (coral) is reserved for the **single primary CTA / brand moment** per surface.
    // Never use a discipline accent to mean effort, and never use the perf ramp for wayfinding.

    /// Performance state — low / fresh / recovered / easy.
    static let perfFresh = dynamic(light: 0x3F9D55, dark: 0x5BC074)
    /// Performance state — moderate / working.
    static let perfModerate = dynamic(light: 0xB45309, dark: 0xF59E0B)
    /// Performance state — high / hard / redline / fatigued.
    static let perfHard = dynamic(light: 0xE5483D, dark: 0xFF6A5C)

    /// Map a 0…1 intensity fraction onto the performance ramp (fresh → moderate → hard). Values
    /// outside [0,1] clamp. The single source of truth for "how hard / how recovered" colour, used by
    /// readiness verbs, effort gauges, and zone tints (kept distinct from `HeartRateZone.color`, which
    /// is the live HR pill's cool→hot ramp).
    static func performance(for fraction: Double) -> Color {
        switch max(0, min(1, fraction)) {
        case ..<0.34: return perfFresh
        case ..<0.67: return perfModerate
        default:      return perfHard
        }
    }

    /// Map a heart-rate zone onto the performance ramp (recovery/easy → fresh, aerobic → moderate,
    /// threshold/max → hard). `.none` falls back to `textSecondary` so a no-data state reads inert.
    static func performance(forZone zone: HeartRateZone) -> Color {
        switch zone {
        case .none:                 return textSecondary
        case .recovery, .easy:      return perfFresh
        case .aerobic:              return perfModerate
        case .threshold, .max:      return perfHard
        }
    }

    /// Resolve a module accent from its registry `id`. Falls back to `brand` for
    /// unknown ids. Note the two fitness apps: id `workout` is "Workout Reels" (coral),
    /// id `workout-log` is the strength tracker (ember-orange).
    static func moduleAccent(_ id: String) -> Color {
        switch id {
        case "workout":     return reels
        case "workout-log": return workout
        case "pomodoro":    return pomodoro
        case "habit":       return habits
        case "journal":     return journal
        case "tip":         return tip
        case "expense":     return expenses
        case "budget":      return budget
        case "kilter":      return kilter
        default:            return brand
        }
    }

    // MARK: - Builders

    /// Build a dynamic `Color` from a light/dark hex pair (0xRRGGBB).
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

extension Color {
    /// Hex initializer, `0xRRGGBB` style (e.g. `Color(hex: 0xFF5A4D)`), opaque.
    init(hex: UInt32) {
        self.init(uiColor: UIColor(rgb: hex))
    }
}

private extension UIColor {
    /// Opaque colour from a 0xRRGGBB integer.
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
