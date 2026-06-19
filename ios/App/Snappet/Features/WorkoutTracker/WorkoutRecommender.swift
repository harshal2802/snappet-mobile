import Foundation

/// Pure, device-free recommender that turns a lifter's recent history (mapped to value types) + a per-muscle
/// freshness/volume signal + an optional recovery read into a **suggested gym session** — a warm-up, a block
/// of main lifts on the freshest under-trained muscles, accessories, and a finisher. The Gym-Tracker
/// analogue of `KilterRecommender` (the climbing recommender it's modelled 1:1 on): the same
/// Strategy → Options → allocation → `recommend` shape, the same determinism + stable tie-breaks, the same
/// "the view does the I/O, this stays pure" contract (workout-redesign E7).
///
/// No SwiftData, no `Exercise` catalog DB, no UI: it consumes plain value-type **candidates**
/// (`WorkoutRecommender.Candidate` — an `Exercise` flattened to its id/name/muscles/equipment/compound flag)
/// + a value-type **signal** (`WorkoutHistoryStats`, already device-free) so it is unit-tested in
/// `SnappetTests` with synthetic inputs, exactly like `KilterRecommender`. `WorkoutPlanView` does the join:
/// it reads `WorkoutSession`s + resolves `Exercise.primaryMuscles` via the `@MainActor ExerciseResolver`,
/// flattens both to these value types, runs `recommend`, and renders / snapshots the result into a routine.
enum WorkoutRecommender {

    /// What a suggested exercise is *for* in the session arc (declared the display order, easy → hard → flush).
    enum Goal: String, Sendable, Equatable, CaseIterable {
        case warmUp, main, accessory, finisher
        var label: String {
            switch self {
            case .warmUp:    return "Warm-up"
            case .main:      return "Main"
            case .accessory: return "Accessory"
            case .finisher:  return "Finisher"
            }
        }
        /// Default per-block prescription (sets · reps · rest seconds) the goal seeds a `RoutineExercise` with;
        /// a `Strategy` can override the reps/rest scheme (strength → low reps/long rest, hypertrophy → mid).
        var defaultPrescription: (sets: Int, reps: String, rest: Int) {
            switch self {
            case .warmUp:    return (2, "12", 45)
            case .main:      return (4, "8", 120)
            case .accessory: return (3, "10", 75)
            case .finisher:  return (2, "15", 45)
            }
        }
    }

    /// One recommended exercise: the candidate to train + the role it plays + the (strategy-tuned) target
    /// prescription. `RoutineExercise`-shaped — `WorkoutPlanLogic.routineExercises(from:)` turns a `Plan`
    /// straight into a startable/saveable `[RoutineExercise]`.
    struct Pick: Sendable, Equatable, Identifiable {
        var candidate: Candidate
        var goal: Goal
        /// Target sets for this pick (from the goal + strategy scheme).
        var sets: Int
        /// Target reps (free text, like a `RoutineExercise`: "8", "8-12", "max").
        var reps: String
        /// Rest seconds between sets.
        var restSeconds: Int
        var id: String { candidate.id }
    }

    /// A pure value snapshot of an `Exercise` the recommender can pick — no SwiftData, no catalog dependency.
    /// `WorkoutPlanView` builds these from `ExerciseResolver.allMerged` at the I/O edge (the join that keeps
    /// this enum pure). `primaryMuscles` is what the per-muscle freshness signal scores against.
    struct Candidate: Sendable, Equatable, Identifiable, Hashable {
        var id: String
        var name: String
        var primaryMuscles: [Muscle]
        var equipment: Equipment?
        /// `true` for a compound (multi-joint) movement — preferred for `main` slots; `false`/`nil` ⇒ isolation.
        var isCompound: Bool
        /// `true` ⇒ a body-only / no-equipment movement (used by the "no equipment" constraint).
        var isBodyweight: Bool

        init(id: String, name: String, primaryMuscles: [Muscle],
             equipment: Equipment?, isCompound: Bool, isBodyweight: Bool) {
            self.id = id
            self.name = name
            self.primaryMuscles = primaryMuscles
            self.equipment = equipment
            self.isCompound = isCompound
            self.isBodyweight = isBodyweight
        }
    }

    /// Relative emphasis across the four goals — how `targetCount` splits. `nil` (the default) keeps the
    /// balanced allocation; a strategy leans it (strength = main-heavy, recovery = warm-up-heavy). Weights
    /// are relative; a zero weight drops that goal. Mirrors `KilterRecommender.Mix`.
    struct Mix: Sendable, Equatable {
        var warmUp: Double
        var main: Double
        var accessory: Double
        var finisher: Double
        init(warmUp: Double, main: Double, accessory: Double, finisher: Double) {
            self.warmUp = warmUp; self.main = main; self.accessory = accessory; self.finisher = finisher
        }
    }

    /// The rep/rest scheme a strategy trains in — applied to a goal's default prescription.
    struct Scheme: Sendable, Equatable {
        /// Reps for the `main` slots ("5" / "8" / "12").
        var mainReps: String
        /// Rest seconds for the `main` slots (strength rests longest).
        var mainRest: Int
    }

    /// Tunables (sensible defaults; surfaced so tests pin behaviour and the plan-config sheet can tune).
    /// Mirrors `KilterRecommender.Options`.
    struct Options: Sendable, Equatable {
        /// Total exercises to suggest.
        var targetCount: Int = 6
        /// Days since a muscle was trained, at/under which it counts as "fresh enough to skip" — i.e. we bias
        /// AWAY from muscles trained within this window so the plan hits what's recovered (Fitbod-style).
        var freshnessWindowDays: Int = 2
        /// Goal emphasis; `nil` → the balanced default allocation.
        var mix: Mix? = nil
        /// The rep/rest scheme; `nil` → each goal's own default prescription.
        var scheme: Scheme? = nil
        /// Equipment the user has ruled out (the "no barbell" constraint chip / an AI-parsed tweak); a
        /// candidate using any excluded equipment is dropped. Empty ⇒ everything is allowed.
        var excludedEquipment: Set<Equipment> = []
        /// `true` ⇒ only body-only / no-equipment movements (the "no equipment" / travel constraint).
        var bodyweightOnly: Bool = false
        /// Shuffle/re-roll seed: `0` (default) keeps the deterministic best-ranked picks; a non-zero seed
        /// rotates each goal's ranked candidate pool so "Shuffle" surfaces different — still well-ranked —
        /// exercises, deterministically per seed (the `KilterRecommender` re-roll contract).
        var rerollSeed: Int = 0

        init(targetCount: Int = 6, freshnessWindowDays: Int = 2, mix: Mix? = nil, scheme: Scheme? = nil,
             excludedEquipment: Set<Equipment> = [], bodyweightOnly: Bool = false, rerollSeed: Int = 0) {
            self.targetCount = targetCount
            self.freshnessWindowDays = freshnessWindowDays
            self.mix = mix
            self.scheme = scheme
            self.excludedEquipment = excludedEquipment
            self.bodyweightOnly = bodyweightOnly
            self.rerollSeed = rerollSeed
        }
    }

    /// A lifter-language selection strategy the plan-config sheet leads with — each maps to `Options`
    /// (count / mix / scheme). Never exposed as a raw tuning console; the user picks intent and these encode
    /// it. Mirrors `KilterRecommender.Strategy`.
    enum Strategy: String, Sendable, Equatable, CaseIterable {
        case balanced, hypertrophy, strength, recovery, timeCapped
        var label: String {
            switch self {
            case .balanced:    return "Balanced"
            case .hypertrophy: return "Hypertrophy"
            case .strength:    return "Strength"
            case .recovery:    return "Recovery"
            case .timeCapped:  return "Time-capped"
            }
        }
        var subtitle: String {
            switch self {
            case .balanced:    return "A bit of everything"
            case .hypertrophy: return "Volume, moderate reps"
            case .strength:    return "Heavy compounds, low reps"
            case .recovery:    return "Light, mobility-leaning flush"
            case .timeCapped:  return "Short — the essentials only"
            }
        }
        var systemImage: String {
            switch self {
            case .balanced:    return "circle.grid.2x2"
            case .hypertrophy: return "chart.bar.fill"
            case .strength:    return "dumbbell.fill"
            case .recovery:    return "leaf.fill"
            case .timeCapped:  return "timer"
            }
        }
    }

    /// The default count / mix / scheme a strategy seeds the config sheet with. Mirrors
    /// `KilterRecommender.config(for:)` — the view applies them into `Options`.
    struct StrategyConfig: Sendable, Equatable {
        var targetCount: Int
        var mix: Mix?
        var scheme: Scheme?
    }

    static func config(for strategy: Strategy) -> StrategyConfig {
        switch strategy {
        case .balanced:
            return .init(targetCount: 6, mix: nil, scheme: nil)
        case .hypertrophy:
            return .init(targetCount: 7, mix: Mix(warmUp: 1, main: 3, accessory: 3, finisher: 1),
                         scheme: Scheme(mainReps: "10-12", mainRest: 90))
        case .strength:
            return .init(targetCount: 5, mix: Mix(warmUp: 1, main: 3, accessory: 1, finisher: 0),
                         scheme: Scheme(mainReps: "5", mainRest: 180))
        case .recovery:
            return .init(targetCount: 4, mix: Mix(warmUp: 2, main: 1, accessory: 1, finisher: 0),
                         scheme: Scheme(mainReps: "12-15", mainRest: 60))
        case .timeCapped:
            return .init(targetCount: 3, mix: Mix(warmUp: 0, main: 2, accessory: 1, finisher: 0),
                         scheme: Scheme(mainReps: "8", mainRest: 90))
        }
    }

    /// A suggested session: picks ordered warm-up → main → accessory → finisher, plus the muscle focus it was
    /// built around (the freshest under-trained muscles it targeted) for the plain-language *why*.
    struct Plan: Sendable, Equatable {
        var picks: [Pick]
        /// The muscles the plan biased toward (freshest / least-recently-trained), most-fresh first — drives
        /// the "Today" card's *why* ("Legs + back are freshest").
        var focusMuscles: [Muscle]

        static let empty = Plan(picks: [], focusMuscles: [])
        var isEmpty: Bool { picks.isEmpty }
        func picks(for goal: Goal) -> [Pick] { picks.filter { $0.goal == goal } }
    }

    // MARK: - Public API

    /// Freshness (days-since equivalent) assigned to a muscle the user has **never** trained. Deliberately
    /// moderate — *below* a genuinely well-rested trained muscle (so a muscle the user trains and has rested
    /// 7+ days leads the focus), but *above* a recently-trained one (so an untrained muscle still beats a
    /// just-hammered one, and a beginner with no history gets sensible variety). Tuned so the planner biases
    /// toward what the user actually trains, not toward obscure never-touched muscles.
    static let untrainedFreshnessDays = 6

    /// The muscles to bias toward today: those **least recently trained** (most days since), tie-broken by
    /// **lowest recent volume**, then a fixed muscle order (stable). A never-trained muscle is treated as
    /// moderately fresh (`untrainedFreshnessDays`) so it doesn't crowd out a genuinely-rested trained muscle.
    /// `signal` is the device-free per-muscle history; `count` caps the focus list. Deterministic.
    static func focusMuscles(signal: WorkoutHistoryStats, count: Int = 3) -> [Muscle] {
        let universe = Muscle.allCases
        let order = Dictionary(uniqueKeysWithValues: universe.enumerated().map { ($1, $0) })
        let ranked = universe.sorted { a, b in
            let da = signal.daysSinceByMuscle[a] ?? untrainedFreshnessDays
            let db = signal.daysSinceByMuscle[b] ?? untrainedFreshnessDays
            if da != db { return da > db }                                   // most days since first
            let va = signal.weeklyVolumeByMuscle[a] ?? 0
            let vb = signal.weeklyVolumeByMuscle[b] ?? 0
            if va != vb { return va < vb }                                   // then lowest recent volume
            return order[a]! < order[b]!                                     // then stable muscle order
        }
        return Array(ranked.prefix(max(0, count)))
    }

    /// Build a session plan. `candidates` is the resolvable exercise pool (value snapshots of the merged
    /// catalog); `signal` is the device-free per-muscle history that biases muscle selection. Deterministic
    /// for a given input (stable tie-breaks), so it's reproducible and testable — the `KilterRecommender`
    /// contract.
    static func recommend(candidates: [Candidate],
                          signal: WorkoutHistoryStats,
                          options: Options = Options()) -> Plan {
        // Apply the equipment constraints up front (a "no barbell" / "no equipment" plan never offers them).
        let pool = candidates.filter { c in
            if options.bodyweightOnly && !c.isBodyweight { return false }
            if let eq = c.equipment, options.excludedEquipment.contains(eq) { return false }
            return true
        }
        guard !pool.isEmpty else { return .empty }

        let alloc = options.mix.map { allocation(target: options.targetCount, mix: $0) }
            ?? allocation(target: options.targetCount)
        let focus = focusMuscles(signal: signal, count: 4)
        let focusRank = Dictionary(uniqueKeysWithValues: focus.enumerated().map { ($1, $0) })

        var chosen = Set<String>()
        var picks: [Pick] = []

        /// Rank a candidate pool for a goal: a candidate hitting a fresher focus muscle ranks first; then
        /// compound-vs-isolation by the goal's preference; then name (stable). Deterministic.
        func rank(_ items: [Candidate], preferCompound: Bool) -> [Candidate] {
            items.sorted { a, b in
                let fa = focusScore(a, focusRank: focusRank)
                let fb = focusScore(b, focusRank: focusRank)
                if fa != fb { return fa < fb }                               // lower = fresher muscle hit
                if a.isCompound != b.isCompound { return preferCompound ? a.isCompound : !a.isCompound }
                return a.name < b.name
            }
        }

        /// Fill up to `count` picks for `goal`, drawing from the ranked pool, never repeating a chosen id.
        func take(count: Int, goal: Goal, preferCompound: Bool) {
            guard count > 0 else { return }
            var ranked = rank(pool.filter { !chosen.contains($0.id) }, preferCompound: preferCompound)
            // Shuffle: rotate the ranked pool by the seed so a re-roll picks different, still well-ranked
            // exercises (deterministic per seed). seed 0 → no rotation (best picks). Mirrors KilterRecommender.
            if options.rerollSeed != 0, !ranked.isEmpty {
                let k = ((options.rerollSeed % ranked.count) + ranked.count) % ranked.count
                ranked = Array(ranked[k...] + ranked[..<k])
            }
            var remaining = count
            for c in ranked where remaining > 0 {
                let (sets, reps, rest) = prescription(for: goal, scheme: options.scheme)
                picks.append(Pick(candidate: c, goal: goal, sets: sets, reps: reps, restSeconds: rest))
                chosen.insert(c.id)
                remaining -= 1
            }
        }

        // Fill the **main** block FIRST — it's the session anchor (the compounds on the freshest muscles),
        // so it gets first pick of the prime movements before warm-up/accessory/finisher draw from what's
        // left (otherwise warm-up, which also ranks by muscle freshness, would steal the prime compound).
        // The display order (warm-up → main → accessory → finisher) is enforced by the sort below regardless.
        // Main: compounds on the freshest muscles. Warm-ups: simple isolation-friendly movement. Accessories:
        // isolation to round it out. Finisher: a metcon/pump movement.
        take(count: alloc.main,      goal: .main,      preferCompound: true)
        take(count: alloc.warmUp,    goal: .warmUp,    preferCompound: false)
        take(count: alloc.accessory, goal: .accessory, preferCompound: false)
        take(count: alloc.finisher,  goal: .finisher,  preferCompound: false)

        // Order: warm-up → main → accessory → finisher, each by focus-muscle freshness then name (stable).
        let goalOrder: [Goal] = [.warmUp, .main, .accessory, .finisher]
        picks.sort { a, b in
            let ga = goalOrder.firstIndex(of: a.goal)!, gb = goalOrder.firstIndex(of: b.goal)!
            if ga != gb { return ga < gb }
            let fa = focusScore(a.candidate, focusRank: focusRank)
            let fb = focusScore(b.candidate, focusRank: focusRank)
            if fa != fb { return fa < fb }
            return a.candidate.name < b.candidate.name
        }

        return Plan(picks: picks, focusMuscles: focus)
    }

    /// How a target count splits across the four goals — roughly: one warm-up, the bulk as main+accessory,
    /// an optional finisher. Always sums to `target` (for `target ≥ 1`). Internal so tests can pin it.
    static func allocation(target: Int) -> (warmUp: Int, main: Int, accessory: Int, finisher: Int) {
        let t = max(1, target)
        switch t {
        case 1: return (0, 1, 0, 0)
        case 2: return (0, 1, 1, 0)
        case 3: return (1, 1, 1, 0)
        default:
            let warmUp = 1
            let finisher = t >= 6 ? 1 : 0
            let body = t - warmUp - finisher
            let main = max(1, Int((Double(body) * 0.55).rounded()))
            let accessory = max(1, body - main)
            // Re-balance if rounding overshot.
            let sum = warmUp + main + accessory + finisher
            if sum != t {
                let adjAccessory = max(1, accessory + (t - sum))
                return (warmUp, main, adjAccessory, finisher)
            }
            return (warmUp, main, accessory, finisher)
        }
    }

    /// Weighted split for a non-default `Mix`: largest-remainder apportionment of `target` across the four
    /// goals by relative weight, guaranteeing ≥1 for any positive-weight goal (when the count allows) and a
    /// sum of exactly `target`. A zero weight drops that goal. Falls back to the balanced allocation when all
    /// weights are ≤ 0. Mirrors `KilterRecommender.allocation(target:mix:)`.
    static func allocation(target: Int, mix: Mix) -> (warmUp: Int, main: Int, accessory: Int, finisher: Int) {
        let t = max(1, target)
        let weights = [max(0, mix.warmUp), max(0, mix.main), max(0, mix.accessory), max(0, mix.finisher)]
        let total = weights.reduce(0, +)
        guard total > 0 else { return allocation(target: target) }
        let raw = weights.map { Double(t) * $0 / total }
        var counts = raw.map { Int($0) }                                     // floor
        var remainder = t - counts.reduce(0, +)
        let byFrac = raw.indices.sorted { (raw[$0] - Double(Int(raw[$0]))) > (raw[$1] - Double(Int(raw[$1]))) }
        var k = 0
        while remainder > 0 { counts[byFrac[k % 4]] += 1; remainder -= 1; k += 1 }
        // Guarantee ≥1 for any goal that has weight, stealing from the largest bucket with room.
        for i in 0..<4 where weights[i] > 0 && counts[i] == 0 {
            if let donor = (0..<4).filter({ counts[$0] > 1 }).max(by: { counts[$0] < counts[$1] }) {
                counts[donor] -= 1; counts[i] += 1
            }
        }
        return (counts[0], counts[1], counts[2], counts[3])
    }

    // MARK: - Private helpers

    /// A candidate's focus score: the best (lowest) rank of any of its primary muscles in `focusRank` — so a
    /// candidate hitting the freshest focus muscle scores lowest (ranks first). Misses sort last.
    private static func focusScore(_ c: Candidate, focusRank: [Muscle: Int]) -> Int {
        let scores = c.primaryMuscles.compactMap { focusRank[$0] }
        return scores.min() ?? Int.max
    }

    /// The (sets, reps, rest) a goal seeds, with the `main` slot overridden by the strategy `scheme` when one
    /// is set (strength → 5 reps / 180s, hypertrophy → 10-12 / 90s, …).
    private static func prescription(for goal: Goal, scheme: Scheme?) -> (Int, String, Int) {
        let base = goal.defaultPrescription
        guard goal == .main, let scheme else { return (base.sets, base.reps, base.rest) }
        return (base.sets, scheme.mainReps, scheme.mainRest)
    }
}
