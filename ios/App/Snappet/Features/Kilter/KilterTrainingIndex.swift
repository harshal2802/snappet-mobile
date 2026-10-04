import Foundation

/// The generator model's **training data**, one row per climb (prompt 155). Published next to the model on
/// the Snappet Pages site (`climb-generator/training-index.json.gz`, built by the web repo's
/// `build-climb-dataset.py --training-index` — it re-derives the exact v1 split: 52,878 training climbs,
/// 6,600 validation, 6,860 test). Lets the Generate panel say whether a generated climb was in the
/// training data, matches a climb held out of training, or how close it is to the nearest training climb.
/// Pure (Foundation only) → unit-tested with hand-built rows.
struct KilterTrainingIndex: Sendable {
    enum Split: String, Sendable { case train, val, test }

    struct Climb: Sendable, Equatable {
        let uuid: String
        let name: String
        let setter: String
        let split: Split
        let frames: String
        /// Ascents at its most-climbed angle, that angle, and the grade there.
        let ascents: Int
        let angle: Int
        let grade: String
        /// Its placements, sorted and unique (compact: 66k climbs are kept in memory).
        let placements: [Int]
        /// Canonical `(placement, role)` key for exact matches (computed once while decoding).
        let exactKey: String
    }

    let climbs: [Climb]
    let snapshot: String?
    /// placement -> indices of climbs that use it (for fast overlap counting).
    private let byPlacement: [Int: [Int]]
    /// canonical `(placement, role)` key -> index (exact matches).
    private let byExact: [String: Int]

    init(climbs: [Climb], snapshot: String? = nil) {
        self.climbs = climbs
        self.snapshot = snapshot
        var byPlacement: [Int: [Int]] = [:]
        var byExact: [String: Int] = [:]
        for (i, c) in climbs.enumerated() {
            for p in c.placements { byPlacement[p, default: []].append(i) }
            if byExact[c.exactKey] == nil { byExact[c.exactKey] = i }
        }
        self.byPlacement = byPlacement
        self.byExact = byExact
    }

    /// Decode the published JSON (`fields` + `climbs` rows). Throws on an unreadable file.
    static func decode(_ data: Data) throws -> KilterTrainingIndex {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["climbs"] as? [[Any]] else { throw CocoaError(.fileReadCorruptFile) }
        let fields = (root["fields"] as? [String]) ?? ["uuid", "name", "setter", "split", "frames", "ascents", "angle", "grade"]
        func col(_ name: String) -> Int? { fields.firstIndex(of: name) }
        guard let iU = col("uuid"), let iN = col("name"), let iS = col("setter"), let iSp = col("split"),
              let iF = col("frames"), let iA = col("ascents"), let iAn = col("angle"), let iG = col("grade")
        else { throw CocoaError(.fileReadCorruptFile) }
        var climbs: [Climb] = []
        climbs.reserveCapacity(rows.count)
        for r in rows where r.count == fields.count {
            guard let frames = r[iF] as? String, let split = Split(rawValue: r[iSp] as? String ?? "") else { continue }
            let pairs = KilterCatalog.parseFrames(frames)
            let placements = Array(Set(pairs.map(\.0))).sorted()
            climbs.append(Climb(uuid: r[iU] as? String ?? "", name: r[iN] as? String ?? "",
                                setter: r[iS] as? String ?? "", split: split, frames: frames,
                                ascents: (r[iA] as? NSNumber)?.intValue ?? 0, angle: (r[iAn] as? NSNumber)?.intValue ?? 0,
                                grade: r[iG] as? String ?? "", placements: placements,
                                exactKey: Self.key(pairs.map { KilterHoldKey(placement: $0.0, role: $0.1) })))
        }
        return KilterTrainingIndex(climbs: climbs, snapshot: root["snapshotGeneratedAt"] as? String)
    }

    static func holds(_ frames: String) -> Set<KilterHoldKey> {
        Set(KilterCatalog.parseFrames(frames).map { KilterHoldKey(placement: $0.0, role: $0.1) })
    }

    private static func key<S: Sequence<KilterHoldKey>>(_ holds: S) -> String {
        Set(holds).sorted { ($0.placement, $0.role) < ($1.placement, $1.role) }
            .map { "\($0.placement):\($0.role)" }.joined(separator: ",")
    }

    // MARK: - The check

    /// What a generated climb is, relative to the training data.
    struct Match: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// This exact climb (same holds, same roles) was a training example.
            case inTraining
            /// This exact climb exists but was held out of training (validation / test) — the model never saw it.
            case heldOut(Split)
            /// Shares at least `KilterTrainingIndex.closeThreshold` of its holds with a training climb.
            case veryClose
            /// Not in the training data; `climb` is the nearest training climb (if any share a hold).
            case new
        }
        let kind: Kind
        let climb: Climb?
        /// Holds the two climbs share (by placement) and the larger of the two hold counts.
        let shared: Int
        let outOf: Int
        /// Same placements as `climb` but different roles (a start used as a hand, etc.).
        let sameHoldsDifferentRoles: Bool
    }

    /// "Very close" = this share of holds in common (by placement, over the larger climb). Q2: 80%.
    static let closeThreshold = 0.8

    func check(frames: String) -> Match {
        let gen = Self.holds(frames)
        let genPlacements = Set(gen.map(\.placement))
        guard !gen.isEmpty else { return Match(kind: .new, climb: nil, shared: 0, outOf: 0, sameHoldsDifferentRoles: false) }

        if let i = byExact[Self.key(gen)] {
            let c = climbs[i]
            let kind: Match.Kind = c.split == .train ? .inTraining : .heldOut(c.split)
            return Match(kind: kind, climb: c, shared: gen.count, outOf: gen.count, sameHoldsDifferentRoles: false)
        }

        // The nearest TRAINING climb by shared placements over the larger climb (extra holds count against).
        var counts: [Int: Int] = [:]
        for p in genPlacements { for i in byPlacement[p] ?? [] { counts[i, default: 0] += 1 } }
        var best: (i: Int, shared: Int, outOf: Int, score: Double)?
        for (i, shared) in counts where climbs[i].split == .train {
            let outOf = max(genPlacements.count, climbs[i].placements.count)
            let score = Double(shared) / Double(outOf)
            if let b = best {
                if score < b.score || (score == b.score && climbs[i].ascents <= climbs[b.i].ascents) { continue }
            }
            best = (i, shared, outOf, score)
        }
        guard let best else { return Match(kind: .new, climb: nil, shared: 0, outOf: genPlacements.count, sameHoldsDifferentRoles: false) }
        let c = climbs[best.i]
        let sameHolds = c.placements == genPlacements.sorted()
        return Match(kind: best.score >= Self.closeThreshold ? .veryClose : .new, climb: c,
                     shared: best.shared, outOf: best.outOf, sameHoldsDifferentRoles: sameHolds)
    }
}

/// One hold: a placement and the role it plays.
struct KilterHoldKey: Hashable, Sendable {
    let placement: Int
    let role: Int
}

/// Downloads + caches the training index once (like the model), and keeps the decoded index in memory.
actor KilterTrainingIndexStore {
    static let shared = KilterTrainingIndexStore()

    private var cached: KilterTrainingIndex?
    private let assets = KilterGeneratorAssets.shared

    /// The decoded index, downloading it on first use (~4.6 MB). Throws when the host has none.
    func index() async throws -> KilterTrainingIndex {
        if let cached { return cached }
        let url = try await assets.ensureTrainingIndex()
        let data = try Data(contentsOf: url)
        let index = try KilterTrainingIndex.decode(data)
        cached = index
        return index
    }
}
