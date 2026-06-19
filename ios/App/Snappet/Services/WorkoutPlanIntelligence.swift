import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The **optional on-device Apple-Intelligence sharpener** for the smart planner (workout-redesign E7, the
/// locked decision). The user types a natural-language tweak ("15 min, no barbell"); when Apple's on-device
/// **Foundation Models** are available, this asks the model to structure that phrase into the *same*
/// deterministic `WorkoutPlanTweak` the heuristic parser produces — so the **pure `WorkoutRecommender` still
/// builds the plan** from those constraints. The AI only *fills in the inputs*; the plan stays explainable,
/// auditable, and deterministic.
///
/// **The seam degrades silently to the heuristic** (`WorkoutPlanTweakParser`) whenever Foundation Models
/// aren't usable — an older OS, an unsupported device, model assets not downloaded, Apple Intelligence
/// disabled, a model error, or a timeout. The heuristic is the **always-on path**; the AI pass is a pure
/// sharpener that can never break it.
///
/// **On-device only** — `LanguageModelSession` runs the system model locally; there is no network call and no
/// server LLM (the hard constraint). This service is the *only* place `FoundationModels` is imported (the
/// platform-I/O-at-the-edge rule); the recommender, the tweak model, and the plan logic stay pure.
///
/// ⚠ Build/SDK gating: `FoundationModels` ships in the iOS 26 SDK and is guarded with `#if
/// canImport(FoundationModels)` + `@available(iOS 26.0, *)`, so this compiles against the app's iOS 18
/// deployment target and the framework weak-links + activates only on capable iOS 26 devices. On every
/// other build/runtime the `#else` / availability paths return the heuristic result — the build never breaks.
enum WorkoutPlanIntelligence {

    /// How the tweak was resolved — surfaced so the UI can show a small "sharpened on device" badge vs the
    /// plain heuristic, and so tests can assert the degrade path.
    enum Source: String, Sendable, Equatable {
        /// Parsed by the always-on keyword heuristic (`WorkoutPlanTweakParser`).
        case heuristic
        /// Sharpened by the on-device Foundation Models pass.
        case appleIntelligence
    }

    struct Result: Sendable, Equatable {
        var tweak: WorkoutPlanTweak
        var source: Source
    }

    /// `true` when the on-device model is usable right now — drives whether the UI offers the "AI tweak"
    /// affordance at all (vs the plain text field that still works via the heuristic). Cheap + synchronous.
    static var isIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Resolve a natural-language tweak into a deterministic `WorkoutPlanTweak`. Tries the on-device model
    /// when available; **always** falls back to the heuristic parser on unavailability/error/timeout — so the
    /// caller can `await` this unconditionally and never has to branch on capability.
    ///
    /// The heuristic result is computed first and used as the guaranteed floor; the AI pass only *replaces*
    /// it when it succeeds. (We don't merge — a clean "AI won / heuristic won" keeps the source honest.)
    static func resolve(phrase: String) async -> Result {
        let heuristic = WorkoutPlanTweakParser.parse(phrase)
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(tweak: .none, source: .heuristic) }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            if let aiTweak = await sharpen(phrase: trimmed) {
                return Result(tweak: aiTweak, source: .appleIntelligence)
            }
        }
        #endif
        return Result(tweak: heuristic, source: .heuristic)
    }

    #if canImport(FoundationModels)
    /// The real on-device call: ask the system model to emit a structured `PlanTweakSchema`, then map it to a
    /// `WorkoutPlanTweak`. Returns `nil` on any failure so `resolve` degrades to the heuristic. Bounded by a
    /// short timeout so a slow/wedged model never hangs the draft UI.
    @available(iOS 26.0, *)
    private static func sharpen(phrase: String) async -> WorkoutPlanTweak? {
        let instructions = """
        You convert a gym-goer's short request into structured workout constraints. \
        Only fill fields the request clearly implies; leave the rest null. \
        strategy is one of: balanced, hypertrophy, strength, recovery, timeCapped. \
        For a time limit, set targetCount to roughly one exercise per five minutes (2 to 6). \
        equipmentToAvoid uses lowercase names like barbell, dumbbell, machine, cable, kettlebells, bands. \
        Set bodyweightOnly true only when no equipment is available (home, hotel, travel, bodyweight).
        """
        do {
            // A short, bounded generation. `withTimeout` guards against a model that stalls.
            return try await withTimeout(seconds: 8) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: phrase, generating: PlanTweakSchema.self)
                return response.content.toTweak()
            }
        } catch {
            // Any failure (model busy, guardrail, decode, timeout) → degrade to the heuristic.
            return nil
        }
    }

    /// The `@Generable` structured output the model fills — kept as plain Optionals so a partial answer maps
    /// cleanly. Mirrors `WorkoutPlanTweak`'s knobs.
    @available(iOS 26.0, *)
    @Generable
    fileprivate struct PlanTweakSchema {
        @Guide(description: "balanced, hypertrophy, strength, recovery, or timeCapped; null if unspecified")
        var strategy: String?
        @Guide(description: "Total number of exercises to suggest (2 to 10); null if unspecified")
        var targetCount: Int?
        @Guide(description: "Lowercase equipment names to avoid, e.g. barbell, dumbbell, machine, cable, kettlebells, bands")
        var equipmentToAvoid: [String]
        @Guide(description: "true only when no equipment is available (home/hotel/travel/bodyweight)")
        var bodyweightOnly: Bool

        func toTweak() -> WorkoutPlanTweak {
            var t = WorkoutPlanTweak.none
            t.strategy = strategy.flatMap { WorkoutRecommender.Strategy(rawValue: $0) }
            t.targetCount = targetCount.map { min(10, max(1, $0)) }
            t.bodyweightOnly = bodyweightOnly
            for name in equipmentToAvoid {
                if let eq = Self.equipmentByName[name.lowercased()] { t.excludedEquipment.insert(eq) }
            }
            return t
        }

        static let equipmentByName: [String: Equipment] = [
            "barbell": .barbell, "dumbbell": .dumbbell, "dumbell": .dumbbell,
            "machine": .machine, "cable": .cable, "kettlebells": .kettlebells,
            "kettlebell": .kettlebells, "bands": .bands, "band": .bands,
        ]
    }

    /// Race a child task against a timeout so a stalled model never wedges the UI; throws on timeout.
    @available(iOS 26.0, *)
    private static func withTimeout<T: Sendable>(seconds: Double,
                                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }
    #endif
}
