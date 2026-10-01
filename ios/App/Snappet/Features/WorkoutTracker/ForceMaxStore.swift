import Foundation
import Observation

/// Your max pull per hand (prompt 145, wireframe frame 13): measured with the Max pull test or typed in,
/// the basis for "% of max" targets. One value for both hands is also accepted (a two-hand max).
/// Device-local like the rest of the force settings (UserDefaults).
@MainActor
@Observable
final class ForceMaxStore {
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        left = Self.read(defaults, "snappet.force.maxLeft")
        right = Self.read(defaults, "snappet.force.maxRight")
        both = Self.read(defaults, "snappet.force.maxBoth")
    }

    var left: Double? { didSet { write("snappet.force.maxLeft", left) } }
    var right: Double? { didSet { write("snappet.force.maxRight", right) } }
    /// A two-hand max (what most protocols use).
    var both: Double? { didSet { write("snappet.force.maxBoth", both) } }

    /// The max to scale a target from: that hand's max, else the two-hand max.
    func max(for hand: Hand?) -> Double? {
        switch hand {
        case .left?: return left ?? both
        case .right?: return right ?? both
        case nil: return both ?? [left, right].compactMap { $0 }.max()
        }
    }

    private static func read(_ d: UserDefaults, _ key: String) -> Double? {
        let v = d.double(forKey: key)
        return v > 0 ? v : nil
    }

    private func write(_ key: String, _ v: Double?) {
        if let v, v > 0 { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
