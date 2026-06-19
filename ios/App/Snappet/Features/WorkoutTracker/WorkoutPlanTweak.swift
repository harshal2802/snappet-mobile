import Foundation

/// A parsed natural-language tweak to a plan ("15 min, no barbell", "go easy, dumbbells only") expressed as
/// **deterministic adjustments to `WorkoutRecommender.Options` + the strategy** — never a whole plan. This is
/// the explainable seam: whether the tweak is parsed by the always-on heuristic (`WorkoutPlanTweakParser`)
/// or sharpened by the optional on-device Apple-Intelligence pass (`WorkoutPlanIntelligence`), the *plan
/// itself* is always built by the pure `WorkoutRecommender` from these constraints. So the planner stays
/// deterministic + auditable; the AI only fills in the inputs (the locked decision — AI is a *sharpener*,
/// the heuristic is the always-available path).
///
/// Pure value type → unit-tested in `SnappetTests` with no device.
struct WorkoutPlanTweak: Sendable, Equatable {
    /// Override the strategy ("go heavy" → .strength, "easy day" → .recovery); `nil` ⇒ keep the current one.
    var strategy: WorkoutRecommender.Strategy?
    /// Cap the exercise count ("just 3 moves", "15 minutes" → ~3-4); `nil` ⇒ keep the current count.
    var targetCount: Int?
    /// Equipment to exclude ("no barbell").
    var excludedEquipment: Set<Equipment>
    /// `true` ⇒ body-only ("no equipment", "bodyweight only", "travel/hotel").
    var bodyweightOnly: Bool

    static let none = WorkoutPlanTweak(strategy: nil, targetCount: nil, excludedEquipment: [], bodyweightOnly: false)

    var isEmpty: Bool {
        strategy == nil && targetCount == nil && excludedEquipment.isEmpty && !bodyweightOnly
    }

    /// Fold this tweak onto a base `Options` (constraints union, count/strategy override) — the single place a
    /// tweak becomes recommender inputs, shared by the heuristic and the AI path so they can't diverge.
    func apply(to options: WorkoutRecommender.Options) -> WorkoutRecommender.Options {
        var o = options
        if let c = targetCount { o.targetCount = max(1, c) }
        o.excludedEquipment.formUnion(excludedEquipment)
        if bodyweightOnly { o.bodyweightOnly = true }
        return o
    }
}

/// The **always-on heuristic** tweak parser — a small keyword/number matcher over the lowercased phrase. This
/// is the path that runs when Apple Intelligence is unavailable (most devices today) and the proven floor the
/// AI sharpener must beat or fall back to. Pure → unit-tested; deterministic.
enum WorkoutPlanTweakParser {
    static func parse(_ phrase: String) -> WorkoutPlanTweak {
        let text = phrase.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        var tweak = WorkoutPlanTweak.none

        // Strategy intent.
        if text.contains("easy") || text.contains("light") || text.contains("recover") || text.contains("mobility") {
            tweak.strategy = .recovery
        } else if text.contains("heavy") || text.contains("strong") || text.contains("strength") || text.contains("hard") {
            tweak.strategy = .strength
        } else if text.contains("hypertrophy") || text.contains("pump") || text.contains("volume") || text.contains("build") {
            tweak.strategy = .hypertrophy
        } else if text.contains("quick") || text.contains("short") || text.contains("busy") {
            tweak.strategy = .timeCapped
        }

        // Time / count caps. "15 min" / "20 minutes" → a count cap (~1 move per 5 min, clamped 2…6); an
        // explicit "N moves/exercises/lifts" wins outright.
        if let count = firstNumber(in: text, near: ["move", "moves", "exercise", "exercises", "lift", "lifts"]) {
            tweak.targetCount = min(10, max(1, count))
        } else if let minutes = firstNumber(in: text, near: ["min", "minute", "minutes"]) {
            tweak.targetCount = min(6, max(2, minutes / 5))
            if tweak.strategy == nil { tweak.strategy = .timeCapped }
        }

        // Equipment exclusions.
        if text.contains("no equipment") || text.contains("bodyweight") || text.contains("body weight")
            || text.contains("no gear") || text.contains("hotel") || text.contains("travel")
            || text.contains("at home") || text.contains("home workout") {
            tweak.bodyweightOnly = true
        }
        for (keywords, eq) in equipmentKeywords {
            if keywords.contains(where: { text.contains("no \($0)") || text.contains("without \($0)") }) {
                tweak.excludedEquipment.insert(eq)
            }
        }
        return tweak
    }

    /// Map of phrase → the equipment it names (for "no <equipment>").
    private static let equipmentKeywords: [(keywords: [String], equipment: Equipment)] = [
        (["barbell"], .barbell),
        (["dumbbell", "dumbell"], .dumbbell),
        (["machine"], .machine),
        (["cable"], .cable),
        (["kettlebell"], .kettlebells),
        (["band", "bands"], .bands),
    ]

    /// The first integer appearing within a small window of any keyword — so "15 min" / "min 15" both read 15
    /// while ignoring a stray number elsewhere. Falls back to the first integer anywhere if a keyword is
    /// present but no adjacent number is found.
    private static func firstNumber(in text: String, near keywords: [String]) -> Int? {
        guard keywords.contains(where: { text.contains($0) }) else { return nil }
        // Scan tokens; return the first integer token (the phrasing is short, so the first number is the one).
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for tok in tokens { if let n = Int(tok) { return n } }
        // Also handle "15min" glued together.
        var digits = ""
        for ch in text { if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break } }
        return Int(digits)
    }
}
