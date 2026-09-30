import Foundation

/// Load on a hang (prompt 142, wireframe frame 2 / L1): weight **added** on top of bodyweight (a belt /
/// vest), or weight **taken off** with a pulley. Bodyweight-only is simply no load (`nil` on the spec).
/// Stored exactly as typed with its unit, so 71.3 lb stays 71.3 lb. Lives in `Shared/` beside
/// `TimedExerciseSpec`, which carries it. Pure value → unit-tested.
struct HangLoad: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Extra weight on top of bodyweight.
        case added
        /// Weight taken off with a pulley / counterweight.
        case assisted
    }

    var kind: Kind
    /// Amount in `unitRaw` (always ≥ 0; `kind` says which direction).
    var amount: Double
    /// "kg" or "lb" — the unit the amount was entered in.
    var unitRaw: String

    init(kind: Kind, amount: Double, unitRaw: String = "kg") {
        self.kind = kind
        self.amount = max(0, amount)
        self.unitRaw = unitRaw == "lb" ? "lb" : "kg"
    }

    static let kgPerLb = 0.45359237

    /// Signed change to bodyweight in kg: + added, − assisted.
    var signedKg: Double {
        let kg = unitRaw == "lb" ? amount * Self.kgPerLb : amount
        return kind == .added ? kg : -kg
    }

    /// Total load on the fingers for a bodyweight in kg (never below 0). One-hand hangs put all of it on
    /// that one hand, so the same total applies per hand.
    func totalKg(bodyweightKg: Double) -> Double { max(0, bodyweightKg + signedKg) }
}

/// Which hand(s) a hang uses (prompt 142, wireframe frames 2C / 5B). `nil` on the spec = both hands.
enum HandMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case alternate
    case leftThenRight
    case leftOnly
    case rightOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alternate: return "Alternate L / R"
        case .leftThenRight: return "Left first, then right"
        case .leftOnly: return "Left only"
        case .rightOnly: return "Right only"
        }
    }

    /// Reps are per hand: the two-sided modes do every rep on each hand.
    var repMultiplier: Int { (self == .alternate || self == .leftThenRight) ? 2 : 1 }

    /// The hand order for `reps` per-hand reps in one set.
    func sequence(reps: Int) -> [(hand: Hand, rep: Int)] {
        let n = max(1, reps)
        switch self {
        case .alternate: return (1...n).flatMap { [(Hand.left, $0), (Hand.right, $0)] }
        case .leftThenRight: return (1...n).map { (Hand.left, $0) } + (1...n).map { (Hand.right, $0) }
        case .leftOnly: return (1...n).map { (Hand.left, $0) }
        case .rightOnly: return (1...n).map { (Hand.right, $0) }
        }
    }
}

enum Hand: String, Codable, Sendable {
    case left, right
    var label: String { self == .left ? "LEFT" : "RIGHT" }
}
