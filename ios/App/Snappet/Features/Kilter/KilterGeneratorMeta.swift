import Foundation

/// The generator's sidecar metadata (`meta.json`) — the vocabulary, board-size hold masks, placement/role
/// tables and the linear grade model that drive the on-device transformer. Decoded straight from the file
/// the app lazy-downloads (`KilterGeneratorAssets`); identical to what the board-explorer web tool ships,
/// so on-device generation matches the web tool bit-for-bit. Pure value type (no ONNX, no SwiftUI) →
/// unit-tested from a small inline fixture.
struct KilterGeneratorMeta: Codable, Sendable {
    struct Specials: Codable, Sendable {
        let BOS: Int, EOS: Int, PAD: Int, MATCH: Int, NOMATCH: Int
    }
    struct Size: Codable, Sendable, Identifiable {
        let id: Int
        let name: String
        let box: [Int]   // [left, right, bottom, top]
    }
    struct Role: Codable, Sendable {
        let id: Int
        let name: String
        let color: String
    }
    /// The linear grade estimator: `bias + w_nomatch·nomatch + w_angle[angle] + Σ w_hold[token] + y_mean`.
    /// `w_hold` is indexed by **vocabulary token index** (a hold token), `angle_index` maps an angle to a
    /// `w_angle` slot. Mirrors the web tool's `st()`.
    struct GradeModel: Codable, Sendable {
        let w_hold: [Double]
        let w_angle: [Double]
        let w_nomatch: Double
        let bias: Double
        let angle_index: [String: Int]
        let y_mean: Double
        let first_hold_id: Int
    }

    /// Max sequence length the model was trained with (the input tensor is padded to this).
    let block: Int
    let pad: Int
    let specials: Specials
    let firstHoldId: Int
    /// Index → token string. Hold tokens are `HOLD_<placementId>_<roleId>`; others are
    /// `PAD/BOS/EOS/SIZE_*/ANGLE_*/GRADE_*/MATCH/NOMATCH`.
    let itos: [String]
    let sizes: [Size]
    let roles: [Role]
    /// `"<sizeId>" → [allowed token indices]` (includes EOS + that size's hold tokens). Restricting the
    /// candidate set to the mask is what makes every generated climb fit the chosen board.
    let sizeMasks: [String: [Int]]
    let gradeModel: GradeModel
    let grades: [Int]
    let gradeLabels: [String: String]
    let angles: [Int]
    let defaultSize: Int
}

/// A `KilterGeneratorMeta` plus the lookup maps the decode loop needs, precomputed once (the maps are read
/// in a hot per-token loop, so they're built up-front, not recomputed). The web tool's `tt()` prep step.
struct KilterGeneratorModel: Sendable {
    let meta: KilterGeneratorMeta
    /// token string → index.
    let stoi: [String: Int]
    /// hold-token index → placementId.
    let placementOf: [Int: Int]
    /// hold-token index → roleId.
    let roleOf: [Int: Int]
    /// roleId → role name (start/middle/finish/foot).
    let roleName: [Int: String]

    init(_ meta: KilterGeneratorMeta) {
        self.meta = meta
        var stoi = [String: Int](minimumCapacity: meta.itos.count)
        var placementOf = [Int: Int]()
        var roleOf = [Int: Int]()
        for (i, s) in meta.itos.enumerated() {
            stoi[s] = i
            if s.hasPrefix("HOLD_") {
                let parts = s.split(separator: "_")
                if parts.count == 3, let p = Int(parts[1]), let r = Int(parts[2]) {
                    placementOf[i] = p
                    roleOf[i] = r
                }
            }
        }
        self.stoi = stoi
        self.placementOf = placementOf
        self.roleOf = roleOf
        self.roleName = Dictionary(meta.roles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Decode a model from its on-disk `meta.json`.
    static func load(metaURL: URL) throws -> KilterGeneratorModel {
        let data = try Data(contentsOf: metaURL)
        return KilterGeneratorModel(try JSONDecoder().decode(KilterGeneratorMeta.self, from: data))
    }

    /// The board sizes this model supports, as the app's `KilterBoardSize` (for the Generate pickers).
    var boardSizes: [KilterBoardSize] {
        meta.sizes.map { KilterBoardSize(id: $0.id, name: $0.name, detail: "", box: nil) }
    }

    /// Grade label for a model grade index (e.g. 17 → "6a/V3"), falling back to the raw number.
    func gradeLabel(_ grade: Int) -> String { meta.gradeLabels[String(grade)] ?? String(grade) }
}
