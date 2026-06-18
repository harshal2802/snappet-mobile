import Foundation

/// The discipline of a logged climb (issue: Quick Session redesign). Drives the grade **scale**, the
/// outcome relabels, and the card icon — chosen FIRST in the "Add a climb" sheet because everything
/// downstream depends on it. Outcomes reuse `KilterAscentStatus` (no enum change, so the existing
/// send/pyramid/milestone logic is untouched); route types only **relabel** the four states for display
/// (flash→Onsight, sent→Redpoint). Pure (no SwiftUI/SwiftData) so the mapping is unit-tested without a
/// device — the repo's pure-logic-at-a-thin-edge rule.
enum ClimbType: String, Codable, CaseIterable, Sendable, Identifiable {
    case boulder, topRope, lead, sport
    var id: String { rawValue }

    var label: String {
        switch self {
        case .boulder: return "Boulder"
        case .topRope: return "Top-rope"
        case .lead:    return "Lead"
        case .sport:   return "Sport"
        }
    }

    /// SF Symbol for the climb card header / type chip.
    var symbol: String {
        switch self {
        case .boulder: return "figure.bouldering"
        case .topRope: return "figure.climbing"
        case .lead, .sport: return "figure.climbing"
        }
    }

    /// A roped route (top-rope / lead / sport) vs a boulder problem — gates the grade scale and relabels.
    var isRoute: Bool { self != .boulder }

    /// The grade scale this type defaults to (boulder → V-scale, routes → YDS). The user can toggle to
    /// the companion scale (V↔Font, YDS↔French) and that choice sticks per type (Phase 4).
    var defaultScale: GradeScale { isRoute ? .yds : .vScale }

    /// The two grade scales valid for this type, in toggle order (selected first).
    func scales(selected: GradeScale?) -> [GradeScale] {
        let primary = selected ?? defaultScale
        return [primary, primary.companion]
    }

    /// Display label for an outcome, type-aware: boulder uses the plain status label; a route relabels
    /// the same four states (flash→Onsight, sent→Redpoint, project→Project, attempt→Fell) so the picker
    /// reads naturally for ropes WITHOUT changing the persisted `KilterAscentStatus` vocabulary.
    func statusLabel(_ status: KilterAscentStatus) -> String {
        guard isRoute else { return status.label }
        switch status {
        case .flash:   return "Onsight"
        case .sent:    return "Redpoint"
        case .project: return "Project"
        case .attempt: return "Fell"
        }
    }
}

/// A climbing grade scale. Each carries its ordered **rungs** (easiest→hardest) so grade entry is a
/// constrained discrete picker (never free-text — the research's exact-pyramid-math requirement) and so
/// the live grade pyramid / hardest-send sort use an exact ordinal difficulty. Pure → unit-tested.
enum GradeScale: String, Codable, CaseIterable, Sendable, Identifiable {
    case vScale, font, yds, french
    var id: String { rawValue }

    var label: String {
        switch self {
        case .vScale: return "V-scale"
        case .font:   return "Font"
        case .yds:    return "YDS"
        case .french: return "French"
        }
    }

    /// Short label for the in-sheet scale-toggle pill (e.g. "V" · "Font").
    var shortLabel: String {
        switch self {
        case .vScale: return "V"
        case .font:   return "Font"
        case .yds:    return "YDS"
        case .french: return "Fr"
        }
    }

    /// `true` for the two boulder scales (V / Font); the other two are route scales (YDS / French).
    var isBoulderScale: Bool { self == .vScale || self == .font }

    /// The companion scale toggled to from this one (V↔Font, YDS↔French) — same discipline, other notation.
    var companion: GradeScale {
        switch self {
        case .vScale: return .font
        case .font:   return .vScale
        case .yds:    return .french
        case .french: return .yds
        }
    }

    /// Ordered grade rungs, easiest→hardest. The picker shows exactly these; the stored grade is always
    /// one of them.
    var rungs: [String] {
        switch self {
        case .vScale:
            return (0...17).map { "V\($0)" }
        case .font:
            return ["3", "4", "5", "5+", "6A", "6A+", "6B", "6B+", "6C", "6C+",
                    "7A", "7A+", "7B", "7B+", "7C", "7C+", "8A", "8A+", "8B", "8B+", "8C", "8C+"]
        case .yds:
            var out = ["5.6", "5.7", "5.8", "5.9"]
            for major in 10...15 {
                for minor in ["a", "b", "c", "d"] { out.append("5.\(major)\(minor)") }
            }
            return out
        case .french:
            var out = ["4", "5a", "5b", "5c"]
            for major in 6...9 {
                for minor in ["a", "a+", "b", "b+", "c", "c+"] { out.append("\(major)\(minor)") }
            }
            return out
        }
    }

    /// Ordinal difficulty for a grade label — its index in `rungs` (easiest = 0). Drives the pyramid
    /// ordering + the hardest-send pick. `nil` for an unknown label (e.g. legacy free-text grades), so
    /// callers fall back gracefully. Scale-relative: comparing across scales is approximate (a mixed
    /// boulder+route session orders within each discipline; documented in decisions.md).
    func difficulty(for label: String) -> Double? {
        rungs.firstIndex(of: label).map(Double.init)
    }

    /// A sensible default grade to pre-select when first opening the picker for this scale (a mid rung,
    /// the most common starting point — V4 / 6A+ / 5.10c / 6b).
    var defaultGrade: String {
        switch self {
        case .vScale: return "V4"
        case .font:   return "6A+"
        case .yds:    return "5.10c"
        case .french: return "6b"
        }
    }
}
