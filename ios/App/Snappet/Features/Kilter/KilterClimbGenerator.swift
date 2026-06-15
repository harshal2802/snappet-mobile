import Foundation

/// Supplies model logits for the decode loop. The ONNX session conforms to this (`KilterORTSession`); the
/// tests supply a deterministic stub — so the whole sampling algorithm is unit-tested with **no** ONNX
/// Runtime, no model file, and no device. Keeps the heavy binary dependency at a thin edge.
protocol KilterLogitsProviding {
    /// Vocabulary-length logits for the **last** token of `tokens` (a window of ≤ `block` tokens), as the
    /// transformer would output at that position.
    func logits(forTokens tokens: [Int]) throws -> [Float]
}

/// What to generate: the board size / angle / target grade / matching rule the climb is conditioned on,
/// plus the sampling knobs (mirrors the web tool's defaults). `candidates` runs best-of-N toward the
/// target grade.
struct KilterGenerateRequest: Sendable, Equatable {
    var sizeId: Int
    var angle: Int
    var grade: Int
    var nomatch: Bool
    var temperature: Double = 0.9
    var maxHolds: Int = 20
    var minHolds: Int = 4
    var candidates: Int = 1
}

/// A generated climb: its `frames` (standard `p<placement>r<role>`), the raw hold token indices, and the
/// model's predicted grade (a continuous estimate, not a human consensus).
struct KilterGeneratedClimb: Sendable, Equatable {
    let frames: String
    let holdTokens: [Int]
    let predictedGrade: Double
}

enum KilterGeneratorError: LocalizedError {
    case unknownToken(String)
    case noMaskForSize(Int)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unknownToken(let t): return "The model doesn't know token “\(t)” — pick a supported size/angle/grade."
        case .noMaskForSize(let s): return "The model has no hold set for board size \(s)."
        case .emptyResult: return "The generator produced no climb. Try again."
        }
    }
}

/// Autoregressive climb sampler — a faithful Swift port of the board-explorer's decode (`at`/`rt`/`st`/
/// `nt`). Conditions on `[BOS, SIZE, ANGLE, GRADE, MATCH|NOMATCH]`, samples hold tokens restricted to the
/// board-size mask (and never re-using a placement), gates the stop token on a minimum length + a start +
/// a finish, then repairs any missing start/finish so the result is **valid by construction**. Pure
/// (logits come from the injected session); deterministic given a fixed RNG.
struct KilterClimbGenerator {
    let model: KilterGeneratorModel
    let session: any KilterLogitsProviding

    /// Generate the best-of-N climb whose predicted grade is closest to the target. `rng` yields a value
    /// in `[0, 1)`; inject a seeded one for tests, the system RNG in production.
    func generate(_ request: KilterGenerateRequest, rng: () -> Double) throws -> KilterGeneratedClimb {
        var best: KilterGeneratedClimb?
        for _ in 0..<max(1, request.candidates) {
            let holds = try sampleHolds(request, rng: rng)
            let grade = Self.predictGrade(model: model, holds: holds,
                                          angle: request.angle, nomatch: request.nomatch)
            let frames = holds.map { "p\(model.placementOf[$0] ?? 0)r\(model.roleOf[$0] ?? 0)" }.joined()
            let candidate = KilterGeneratedClimb(frames: frames, holdTokens: holds, predictedGrade: grade)
            if best == nil
                || abs(grade - Double(request.grade)) < abs(best!.predictedGrade - Double(request.grade)) {
                best = candidate
            }
        }
        guard let best else { throw KilterGeneratorError.emptyResult }
        return best
    }

    /// One autoregressive sample → the ordered hold token indices (with start/finish repaired in).
    private func sampleHolds(_ req: KilterGenerateRequest, rng: () -> Double) throws -> [Int] {
        let meta = model.meta
        guard let mask = meta.sizeMasks[String(req.sizeId)] else {
            throw KilterGeneratorError.noMaskForSize(req.sizeId)
        }
        let eos = meta.specials.EOS

        func token(_ s: String) throws -> Int {
            guard let i = model.stoi[s] else { throw KilterGeneratorError.unknownToken(s) }
            return i
        }
        let matchToken = req.nomatch ? meta.specials.NOMATCH : meta.specials.MATCH
        var seq = [meta.specials.BOS, try token("SIZE_\(req.sizeId)"),
                   try token("ANGLE_\(req.angle)"), try token("GRADE_\(req.grade)"), matchToken]

        var usedPlacements = Set<Int>()
        var out: [Int] = []
        var hasStart = false, hasFinish = false

        for _ in 0..<req.maxHolds {
            let window = Array(seq.suffix(meta.block))
            let logits = try session.logits(forTokens: window)
            let canStop = hasStart && hasFinish && out.count >= req.minHolds

            var candidates: [Int] = []
            var weights: [Float] = []
            for d in mask where d < logits.count {
                if d == eos {
                    if canStop { candidates.append(d); weights.append(logits[d] / Float(req.temperature)) }
                } else if let pid = model.placementOf[d], !usedPlacements.contains(pid) {
                    candidates.append(d); weights.append(logits[d] / Float(req.temperature))
                }
            }
            if candidates.isEmpty { break }

            let picked = Self.sample(weights: weights, tokens: candidates, rng: rng)
            if picked == eos { break }
            seq.append(picked)
            out.append(picked)
            if let pid = model.placementOf[picked] { usedPlacements.insert(pid) }
            if let rid = model.roleOf[picked], let name = model.roleName[rid] {
                if name == "start" { hasStart = true }
                if name == "finish" { hasFinish = true }
            }
        }

        // Repair: a climb must have a start and a finish — force-add the lowest-id legal hold of any
        // missing role (the web tool's "valid by construction" guarantee).
        let sortedMask = mask.sorted()
        for (role, isMissing) in [("start", !hasStart), ("finish", !hasFinish)] where isMissing {
            for d in sortedMask where d != eos {
                if let pid = model.placementOf[d], !usedPlacements.contains(pid),
                   let rid = model.roleOf[d], model.roleName[rid] == role {
                    out.append(d); usedPlacements.insert(pid); break
                }
            }
        }
        return out
    }

    /// Temperature-softmax sample (the `weights` are already divided by temperature) — numerically stable
    /// (subtract the max before `exp`), cumulative draw against `rng`.
    static func sample(weights: [Float], tokens: [Int], rng: () -> Double) -> Int {
        guard let last = tokens.last else { return -1 }
        let maxW = weights.max() ?? 0
        var exps = [Double](); exps.reserveCapacity(weights.count)
        var sum = 0.0
        for w in weights { let e = exp(Double(w - maxW)); exps.append(e); sum += e }
        var r = rng() * sum
        for i in exps.indices { r -= exps[i]; if r <= 0 { return tokens[i] } }
        return last
    }

    /// The model's predicted grade for a hold set — the linear estimator from `meta.gradeModel`. Mirrors
    /// the web tool's `st()`; pure, so it's regression-tested against known weights.
    static func predictGrade(model: KilterGeneratorModel, holds: [Int], angle: Int, nomatch: Bool) -> Double {
        let gm = model.meta.gradeModel
        var v = gm.bias + (nomatch ? gm.w_nomatch : 0)
        if let idx = gm.angle_index[String(angle)], idx < gm.w_angle.count { v += gm.w_angle[idx] }
        for t in holds where t < gm.w_hold.count { v += gm.w_hold[t] }
        return v + gm.y_mean
    }

    /// Hold-token indices for a *manually* authored climb's `(placementId → role)` assignments, mapped
    /// through the model vocab (`HOLD_<placementId>_<roleId>`). A placement/role the model never saw for
    /// this board is out-of-vocab and dropped, so the estimate degrades gracefully instead of failing.
    /// Pure (#76).
    static func holdTokens(forAssignments assignments: [Int: KilterAuthorRole],
                           model: KilterGeneratorModel) -> [Int] {
        assignments.compactMap { placementId, role in
            model.stoi["HOLD_\(placementId)_\(role.roleId)"]
        }
    }

    /// A live grade estimate for the manual editor — the same linear model the Generate tab shows,
    /// run over the authored holds. `nil` when no hold resolves to the model vocab (nothing to
    /// estimate), so the caller can simply hide the chip. Pure → unit-tested (#76).
    static func estimateManualGrade(assignments: [Int: KilterAuthorRole], angle: Int, nomatch: Bool,
                                    model: KilterGeneratorModel) -> Double? {
        let tokens = holdTokens(forAssignments: assignments, model: model)
        guard !tokens.isEmpty else { return nil }
        return predictGrade(model: model, holds: tokens, angle: angle, nomatch: nomatch)
    }
}
