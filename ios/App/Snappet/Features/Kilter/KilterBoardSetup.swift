import Foundation

/// Pure decisions behind the "Set up this board" verifier (prompt 120). Split out from the catalog SQL and
/// the SwiftUI sheet so the two load-bearing rules — *what to light for a given picker state* and *which
/// holes form the calibration pattern* — unit-test with **no device, no catalog, no BLE**.
///
/// The design turns on one fact: a catalog climb's layout is intrinsic (`KilterCatalog.holds(for:)` resolves
/// LEDs from `climb.layoutId`). You can re-light the same climb across **sizes** (same layout), but a
/// layout-A climb has no placements in layout B — so cycling **layouts** can't light the climb, only a
/// layout-agnostic reference pattern. `KilterBoardSetup.target` encodes exactly that branch.
enum KilterBoardSetup {
    /// What the board should light for the current picker state.
    enum LightTarget: Equatable {
        /// The chosen layout matches the open climb's own layout → light the real climb at this size (the
        /// strongest "is this right?" signal, because the user recognizes the climb).
        case climb(sizeId: Int)
        /// No climb, or the chosen layout differs from the climb's → light the corner+center calibration
        /// pattern for this `(layout, size)` so the user can still check the LEDs land on the board's edges.
        case calibration(layoutId: Int, sizeId: Int)
    }

    /// Decide what to light. `.climb` only when there is a climb AND the chosen layout is its own layout;
    /// otherwise `.calibration`. Pure — the catalog resolves the actual `[KilterHold]` from this.
    static func target(climbLayoutId: Int?, chosenLayoutId: Int, chosenSizeId: Int) -> LightTarget {
        if let climbLayoutId, climbLayoutId == chosenLayoutId {
            return .climb(sizeId: chosenSizeId)
        }
        return .calibration(layoutId: chosenLayoutId, sizeId: chosenSizeId)
    }
}

/// Picks the calibration holds — the recognizable reference pattern lit while cycling layouts. The pattern
/// is the **four corners + the center** of the board's climbable extent: the fewest holes that still pin the
/// board's orientation + size unambiguously ("do these land on my board's edges?"). Pure geometry over the
/// board-coordinate holes, so it tests without the SQLite catalog.
enum KilterCalibration {
    /// One wired hole: its id, board coordinate, and LED index. `x`/`y` are raw board units (bottom-up, the
    /// catalog's `holes.x/holes.y`); the caller normalizes for rendering.
    struct Hole: Equatable, Sendable {
        let holeId: Int
        let x: Int
        let y: Int
        let led: Int
    }

    /// The five target points in the extent, as fractions of `(width, height)`: the four corners then the
    /// center. Fixed order so the result is deterministic and the tests can assert against it.
    static let targets: [(fx: Double, fy: Double)] = [
        (0, 0), (1, 0), (0, 1), (1, 1), (0.5, 0.5),
    ]

    /// The holes nearest each target point, deduped by `holeId` (a small board can collapse two targets onto
    /// one hole) while preserving corner-first order. Empty in → empty out. Distances use squared Euclidean
    /// in board units — monotonic, so no `sqrt` needed and no floating error near ties.
    static func pick(from holes: [Hole]) -> [Hole] {
        guard let first = holes.first else { return [] }
        let minX = holes.map(\.x).min() ?? first.x
        let maxX = holes.map(\.x).max() ?? first.x
        let minY = holes.map(\.y).min() ?? first.y
        let maxY = holes.map(\.y).max() ?? first.y
        let w = Double(maxX - minX)
        let h = Double(maxY - minY)

        var picked: [Hole] = []
        var seen = Set<Int>()
        for t in targets {
            // A degenerate axis (all holes share an x or y) pins that target coordinate to the min — the
            // nearest-hole search still returns a sensible hole, just without spread on that axis.
            let tx = Double(minX) + t.fx * w
            let ty = Double(minY) + t.fy * h
            guard let nearest = holes.min(by: {
                Self.dist2($0, tx, ty) < Self.dist2($1, tx, ty)
            }) else { continue }
            if seen.insert(nearest.holeId).inserted { picked.append(nearest) }
        }
        return picked
    }

    /// Squared distance from a hole to a target point (board units).
    private static func dist2(_ hole: Hole, _ tx: Double, _ ty: Double) -> Double {
        let dx = Double(hole.x) - tx
        let dy = Double(hole.y) - ty
        return dx * dx + dy * dy
    }
}
