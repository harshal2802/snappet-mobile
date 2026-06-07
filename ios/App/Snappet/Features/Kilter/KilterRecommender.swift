import Foundation

/// Pure, device-free recommender that turns a climber's logged history + a pool of catalog candidates
/// into a **suggested climbing session** — a few warm-ups below the working grade, a block of sends at
/// it, and a project above. The climbing analogue of a "pick today's workout" feature, built on the
/// data the Kilter app already keeps (the grade pyramid in `KilterHistoryView` is the same `isSend`
/// signal this mines).
///
/// No SwiftData, no catalog DB, no UI — it consumes plain value types (`KilterClimbLog` history,
/// `KilterListItem` candidates) so it is unit-tested in `SnappetTests` with synthetic inputs, exactly
/// like `KilterSessionStats` and `KilterWorkoutBuilder`. The view (`KilterPlanView`) does the I/O:
/// reads `KilterLogEntry`s, queries the catalog for a difficulty window, and renders the result.
enum KilterRecommender {

    /// What a suggested climb is *for* in the session arc (declared easy → hard, the display order).
    enum Goal: String, Sendable, Equatable, CaseIterable {
        case warmup, send, project
        var label: String {
            switch self {
            case .warmup: return "Warm up"
            case .send: return "Send"
            case .project: return "Project"
            }
        }
    }

    /// One recommended climb: the catalog item to climb + the role it plays.
    struct Pick: Sendable, Equatable, Identifiable {
        var item: KilterListItem
        var goal: Goal
        var id: String { item.uuid }
    }

    /// A suggested session: picks ordered warm-ups → sends → project, plus the working grade it was
    /// built around (`nil` when there's no send history to anchor on — a cold start).
    struct Plan: Sendable, Equatable {
        var picks: [Pick]
        /// The detected working-grade float difficulty; `nil` when unknown (no sends yet).
        var workingDifficulty: Double?
        /// A human grade label for the working difficulty, when one is known.
        var workingGradeLabel: String?

        static let empty = Plan(picks: [], workingDifficulty: nil, workingGradeLabel: nil)
        var isEmpty: Bool { picks.isEmpty }
        func picks(for goal: Goal) -> [Pick] { picks.filter { $0.goal == goal } }
    }

    /// Tunables (sensible defaults; surfaced so tests pin behaviour and a future settings screen can tune).
    struct Options: Sendable, Equatable {
        /// Total climbs to suggest.
        var targetCount: Int = 6
        /// How many sends in a grade bucket qualify it as the working grade (vs a lucky one-off).
        var sendThreshold: Int = 2
        /// For send/project goals, prefer climbs the user hasn't already sent (chase the new).
        var preferUnsent: Bool = true
        init(targetCount: Int = 6, sendThreshold: Int = 2, preferUnsent: Bool = true) {
            self.targetCount = targetCount
            self.sendThreshold = sendThreshold
            self.preferUnsent = preferUnsent
        }
    }

    // MARK: - Public API

    /// The climber's **working grade**: the hardest difficulty bucket they've sent at least
    /// `sendThreshold` times. Falls back to the hardest single send, then `nil` (no sends yet).
    /// Buckets are rounded difficulty — the catalog's own grade granularity (`KilterCatalog.gradeLabel`).
    static func workingDifficulty(history: [KilterClimbLog], sendThreshold: Int = 2) -> Double? {
        let sends = history.filter(\.isSend)
        guard !sends.isEmpty else { return nil }
        var countByBucket: [Int: Int] = [:]
        for s in sends { countByBucket[bucket(s.difficulty), default: 0] += 1 }
        if let b = countByBucket.filter({ $0.value >= sendThreshold }).keys.max() { return Double(b) }
        // Nothing meets the threshold yet → anchor on the hardest single send.
        return Double(sends.map { bucket($0.difficulty) }.max()!)
    }

    /// Build a session plan. `history` is the user's logged climbs (across all sessions); `candidates`
    /// is a catalog pool already scoped to the user's layout/angle and spanning roughly the
    /// warm-up…project difficulty window. Deterministic for a given input (stable tie-breaks), so it's
    /// reproducible and testable.
    static func recommend(history: [KilterClimbLog],
                          candidates: [KilterListItem],
                          anchor: Double? = nil,
                          options: Options = Options()) -> Plan {
        let working = workingDifficulty(history: history, sendThreshold: options.sendThreshold)

        // Band centre. Prefer an explicit `anchor` from the caller — so the catalog-query window it
        // fetched `candidates` over and these bands derive from the **same** value; otherwise the
        // window and the bands can disagree and a goal gets silently dropped (the view sizes its
        // query from the grade-scale median, which need not match a candidate-density median). Falls
        // back to the detected working grade, then — on a cold start with no anchor — the median
        // candidate difficulty, so a brand-new climber still gets a sensible spread.
        let resolvedAnchor: Double
        if let anchor {
            resolvedAnchor = anchor
        } else if let working {
            resolvedAnchor = working
        } else if !candidates.isEmpty {
            let sorted = candidates.map(\.difficulty).sorted()
            resolvedAnchor = sorted[sorted.count / 2]
        } else {
            return Plan(picks: [], workingDifficulty: working, workingGradeLabel: nil)
        }

        let w = bucket(resolvedAnchor)
        let alloc = allocation(target: options.targetCount)
        let sentUUIDs = Set(history.filter(\.isSend).map(\.climbUUID))

        var chosen = Set<String>()
        var picks: [Pick] = []

        /// Fill up to `count` picks for `goal`, trying each band of difficulty buckets in turn (primary
        /// first, then fallbacks for a sparse catalog), never repeating a climb already chosen.
        func take(bands: [Set<Int>], count: Int, goal: Goal, allowSent: Bool) {
            var remaining = count
            for band in bands where remaining > 0 {
                let pool = rank(candidates.filter {
                    !chosen.contains($0.uuid)
                        && band.contains(bucket($0.difficulty))
                        && (allowSent || !sentUUIDs.contains($0.uuid))
                })
                for item in pool where remaining > 0 {
                    picks.append(Pick(item: item, goal: goal))
                    chosen.insert(item.uuid)
                    remaining -= 1
                }
            }
        }

        // Warm-ups stay below the working grade (revisiting sent classics is fine → allowSent).
        take(bands: [[w - 2, w - 1], [w - 3], [w - 4]], count: alloc.warmup, goal: .warmup, allowSent: true)
        // Sends sit at the working grade; chase un-sent ones when asked.
        take(bands: [[w], [w - 1]], count: alloc.send, goal: .send, allowSent: !options.preferUnsent)
        // A project a touch above.
        take(bands: [[w + 1], [w + 2]], count: alloc.project, goal: .project, allowSent: !options.preferUnsent)

        // Order: warm-up → send → project, each easiest→hardest, stable by uuid.
        let order: [Goal] = [.warmup, .send, .project]
        picks.sort { a, b in
            let ga = order.firstIndex(of: a.goal)!, gb = order.firstIndex(of: b.goal)!
            if ga != gb { return ga < gb }
            if a.item.difficulty != b.item.difficulty { return a.item.difficulty < b.item.difficulty }
            return a.item.uuid < b.item.uuid
        }

        let label = working == nil ? nil : gradeLabel(forBucket: w, history: history, candidates: candidates)
        return Plan(picks: picks, workingDifficulty: working, workingGradeLabel: label)
    }

    /// How a target count splits across the three goals — roughly ⅓ warm-up, the bulk sends, one
    /// project. Always sums to `target` (for `target ≥ 3`). Internal so tests can pin it.
    static func allocation(target: Int) -> (warmup: Int, send: Int, project: Int) {
        let t = max(1, target)
        if t == 1 { return (0, 1, 0) }
        if t == 2 { return (1, 1, 0) }
        let project = max(1, Int((Double(t) / 6.0).rounded()))
        let warmup = max(1, Int((Double(t) / 3.0).rounded()))
        let send = max(1, t - warmup - project)
        return (warmup, send, project)
    }

    /// The catalog difficulty window a caller should fetch candidates over so **every** band
    /// `recommend(anchor:)` may draw on is actually populated. The bands span buckets `[w-4 … w+2]`
    /// (warm-up fallbacks down to `w-4`, project up to `w+2`) where `w = round(anchor)`; a bucket `b`
    /// covers difficulties `[b-0.5, b+0.5)`, so the window must reach `w-4.5 … w+2.5`. Pass the *same*
    /// `anchor` to `recommend` so the window and the bands share one centre — otherwise the deepest
    /// warm-up bands point at climbs the query never fetched (KilterPlanView relies on this).
    static func candidateWindow(anchor: Double) -> (min: Double, max: Double) {
        let w = Double(bucket(anchor))
        return (w - 4.5, w + 2.5)
    }

    // MARK: - Private helpers

    /// Difficulty → grade bucket (rounded), matching `KilterCatalog.gradeLabel`'s rounding.
    private static func bucket(_ difficulty: Double) -> Int { Int(difficulty.rounded()) }

    /// Rank a candidate pool: best quality first, then most-climbed, then easiest, then uuid (stable).
    private static func rank(_ items: [KilterListItem]) -> [KilterListItem] {
        items.sorted { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            if a.ascents != b.ascents { return a.ascents > b.ascents }
            if a.difficulty != b.difficulty { return a.difficulty < b.difficulty }
            return a.uuid < b.uuid
        }
    }

    /// A grade label for the working bucket — preferring the user's own history label, then a candidate.
    private static func gradeLabel(forBucket w: Int,
                                   history: [KilterClimbLog],
                                   candidates: [KilterListItem]) -> String? {
        if let s = history.first(where: { bucket($0.difficulty) == w && !$0.gradeLabel.isEmpty }) {
            return s.gradeLabel
        }
        if let c = candidates.first(where: { bucket($0.difficulty) == w && !$0.gradeLabel.isEmpty }) {
            return c.gradeLabel
        }
        return nil
    }
}
