import Foundation
import SwiftData

/// A hold role the user can author. The four canonical Kilter roles, each carrying the **main-line**
/// role id used in `frames` (`p<placement>r<roleId>`) — the same ids the on-device generator emits and
/// the catalog's `KilterCatalog.roleName` decodes (12/13/14/15). Pure (no SwiftUI) so the cycle order and
/// frames mapping are unit-tested; the editor builds its tap targets and the renderer its shapes from this.
enum KilterAuthorRole: String, CaseIterable, Sendable {
    case start, middle, finish, foot

    /// The role id written into `frames`. Kilter main line: start 12, middle/hand 13, finish 14, foot 15.
    var roleId: Int {
        switch self {
        case .start: return 12
        case .middle: return 13
        case .finish: return 14
        case .foot: return 15
        }
    }

    /// Decode a frames role id back to an author role (nil for ids outside the four authorable roles).
    init?(roleId: Int) {
        switch roleId {
        case 12, 42: self = .start
        case 13, 43: self = .middle
        case 14, 44: self = .finish
        case 15, 45: self = .foot
        default: return nil
        }
    }

    /// Tap-to-cycle order on the editable board: unset → start → middle → finish → foot → unset.
    var next: KilterAuthorRole? {
        switch self {
        case .start: return .middle
        case .middle: return .finish
        case .finish: return .foot
        case .foot: return nil   // back to unset
        }
    }

    /// The `KilterCatalog.roleName` value (drives shape + color reuse in the renderer/legend).
    var roleName: String { rawValue }
}

/// Build a `frames` string from authored `(placementId → role)` assignments, in canonical (sorted) order
/// so the result is stable regardless of tap order — feeds both the deterministic uuid and dedup. Pure.
func kilterFrames(from assignments: [Int: KilterAuthorRole]) -> String {
    assignments
        .map { (placementId: $0.key, roleId: $0.value.roleId) }
        .sorted { $0.placementId != $1.placementId ? $0.placementId < $1.placementId : $0.roleId < $1.roleId }
        .map { "p\($0.placementId)r\($0.roleId)" }
        .joined()
}

/// Why a draft climb isn't yet valid to save (a climb needs a start, a finish, and at least a few holds —
/// the same "valid by construction" floor the generator guarantees). `nil`-returning `validate` ⇒ savable.
enum KilterClimbValidationError: Equatable {
    case tooFewHolds(have: Int, need: Int)
    case missingStart
    case missingFinish

    var message: String {
        switch self {
        case .tooFewHolds(_, let need): return "Add at least \(need) holds."
        case .missingStart: return "Mark at least one start hold."
        case .missingFinish: return "Mark at least one finish hold."
        }
    }
}

/// Validate an authored hold set. Mirrors the generator's floor: ≥`minHolds`, ≥1 start, ≥1 finish. Pure.
func kilterValidate(_ assignments: [Int: KilterAuthorRole], minHolds: Int = 4) -> KilterClimbValidationError? {
    let roles = assignments.values
    if assignments.count < minHolds { return .tooFewHolds(have: assignments.count, need: minHolds) }
    if !roles.contains(.start) { return .missingStart }
    if !roles.contains(.finish) { return .missingFinish }
    return nil
}

/// A climb the user authored on this device — manually (hold-by-hold) or via the on-device generator.
/// Persisted in the shared SnappetCore store (the catalog is read-only), and surfaced in the browse list's
/// **Mine** filter. Its `uuid` is the deterministic content id from `KilterClimbIdentity` (so the same
/// climb authored on two devices collapses to one id), and `asClimb` adapts it to the read-only
/// `KilterClimb` so the *entire* existing render / detail / BLE-illumination / logging pipeline applies
/// unchanged. The integrator appends `KilterCreatedClimb.self` to `SnappetSchema.models`.
@Model
final class KilterCreatedClimb {
    /// Deterministic content uuid (`KilterClimbIdentity.uuid(forLayout:frames:)`). Unique so re-saving the
    /// same climb (or syncing one in) can't duplicate the row.
    @Attribute(.unique) var uuid: String
    var name: String
    /// The author's display name (defaults to a local "You"); the `KilterClimb.setter` for this climb.
    var setterUsername: String
    var layoutId: Int
    /// The `product_size_id` the climb was authored against (the board it fits + its LED basis).
    var sizeId: Int
    /// The angle the user designed for (created climbs have no per-angle stats — this seeds the detail
    /// screen's grade + the synthesized single-angle stat).
    var angle: Int
    /// `p<placement>r<role>` hold encoding (canonical/sorted).
    var frames: String
    /// Hold bounding box in board units (for the size-fit rule), computed from the placements.
    var edgeLeft: Int
    var edgeRight: Int
    var edgeBottom: Int
    var edgeTop: Int
    /// The Kilter "No matching" rule (forbids matching hands), authored via a toggle.
    var isNoMatch: Bool
    /// The grade estimate: the generator's predicted grade, or the user's pick for a manual climb. `nil`
    /// when unknown. Drives the detail screen's single-angle stat.
    var predictedGrade: Double?
    /// `"manual"` or `"generated"`.
    var source: String
    /// The generator model id when `source == "generated"` (provenance), else `nil`.
    var modelId: String?
    var createdAt: Date

    init(uuid: String, name: String, setterUsername: String, layoutId: Int, sizeId: Int, angle: Int,
         frames: String, edgeLeft: Int, edgeRight: Int, edgeBottom: Int, edgeTop: Int,
         isNoMatch: Bool = false, predictedGrade: Double? = nil, source: String = "manual",
         modelId: String? = nil, createdAt: Date = .now) {
        self.uuid = uuid
        self.name = name
        self.setterUsername = setterUsername
        self.layoutId = layoutId
        self.sizeId = sizeId
        self.angle = angle
        self.frames = frames
        self.edgeLeft = edgeLeft
        self.edgeRight = edgeRight
        self.edgeBottom = edgeBottom
        self.edgeTop = edgeTop
        self.isNoMatch = isNoMatch
        self.predictedGrade = predictedGrade
        self.source = source
        self.modelId = modelId
        self.createdAt = createdAt
    }

    /// Adapt to the read-only catalog value type so created climbs flow through `KilterCatalog.holds`,
    /// `KilterBoardView`, `KilterClimbDetailView`, BLE illumination and logging with no special-casing.
    var asClimb: KilterClimb {
        KilterClimb(uuid: uuid, name: name, setter: setterUsername, layoutId: layoutId,
                    edgeLeft: edgeLeft, edgeRight: edgeRight, edgeBottom: edgeBottom, edgeTop: edgeTop,
                    frames: frames, description: "", isNoMatch: isNoMatch)
    }

    /// Delete an authored climb, **keeping** its logged ascents (a real send stays in History via the
    /// log's own name snapshot) and dropping a now-stale favorite. Shared by the detail screen and the
    /// Mine list so the policy can't drift (#76). Because the row leaves the store, the duplicate checker
    /// stops trapping users against a climb they removed.
    static func delete(_ climb: KilterCreatedClimb, in context: ModelContext) {
        let uuid = climb.uuid
        if let fav = try? context.fetch(FetchDescriptor<KilterFavorite>(
            predicate: #Predicate { $0.climbUUID == uuid })).first { context.delete(fav) }
        context.delete(climb)
        try? context.save()
    }
}
