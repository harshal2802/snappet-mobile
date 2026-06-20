import SwiftUI

/// The shared **ascent-style vocabulary** (flash / send / project / attempt) — one place that maps a
/// `KilterAscentStatus` to its SF Symbol glyph, word label, and a style `Color`, so P3's dashboard, P4's
/// history roll-ups, and P5's cards all read the same. Always glyph **and** label (design rule: never
/// colour-only), and **no new `SnappetColor` brand token** — the colours derive from the existing perf
/// ramp plus a local Okabe-Ito (Wong) colourblind-safe accent for flash, via `Color(hex:)`.
///
/// Kept in a SwiftUI file (separate from the pure `KilterAllTimeStats`) so the aggregator stays
/// Foundation-only.
enum KilterAscentStyle {

    // Okabe-Ito ("Wong") colourblind-safe palette — used locally for the nominal flash accent only,
    // so flash reads distinct from the perf-ramp green of a worked send without inventing a brand token.
    private static let wongBluishGreen: UInt32 = 0x009E73   // flash — vivid, distinct from perf green

    /// SF Symbol glyph for the status (matches the timeline's existing glyph vocabulary).
    static func glyph(_ status: KilterAscentStatus) -> String {
        switch status {
        case .flash:   return "bolt.fill"
        case .sent:    return "checkmark.seal.fill"
        case .project: return "hourglass"
        case .attempt: return "circle"
        }
    }

    /// The word label (reuses `KilterAscentStatus.label`: Flash / Sent / Project / Attempt).
    static func label(_ status: KilterAscentStatus) -> String { status.label }

    /// The style colour:
    /// - **flash** → Wong bluish-green (a distinct "best" accent, colourblind-safe).
    /// - **sent**  → perf-ramp fresh green (a clean, recovered "done").
    /// - **project** → perf-ramp moderate / amber (in-progress, working).
    /// - **attempt** → secondary text (inert, not-yet).
    static func color(_ status: KilterAscentStatus) -> Color {
        switch status {
        case .flash:   return Color(hex: wongBluishGreen)
        case .sent:    return SnappetColor.perfFresh
        case .project: return SnappetColor.perfModerate
        case .attempt: return SnappetColor.textSecondary
        }
    }

    /// Glyph + colour + label bundled — the unit P3/P4/P5 views consume.
    struct Decoration: Equatable {
        var glyph: String
        var label: String
        var color: Color
    }

    static func decoration(_ status: KilterAscentStatus) -> Decoration {
        Decoration(glyph: glyph(status), label: label(status), color: color(status))
    }
}
