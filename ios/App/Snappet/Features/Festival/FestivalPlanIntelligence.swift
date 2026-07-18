import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The **optional on-device Apple-Intelligence sharpener** for the For-You sheet (festival prompt 04,
/// the E7 contract — the same seam as `WorkoutPlanIntelligence`). The pure `SetRecommender` is the
/// heuristic FLOOR: it ranks the cards and computes each one's `templateReason`. WHEN Apple's
/// on-device **Foundation Models** are available, this rewrites ONLY the one-line *why* into warmer
/// prose from the exact same facts. It never changes the order, never invents a number, never adds a
/// claim — it rephrases the sentence the recommender already produced.
///
/// **Silent degradation:** no Apple Intelligence entitlement, an older OS, an unsupported device,
/// model assets not downloaded, a model error, or a timeout ⇒ the caller gets the identical cards
/// with the template reasons. The heuristic is the always-on path; the AI pass can never break it.
///
/// **On-device only** — `LanguageModelSession` runs the system model locally; no network, no server
/// LLM (the hard constraint). This is the ONLY festival file that imports `FoundationModels`
/// (platform-I/O-at-the-edge); the recommender and the reason facts stay pure.
///
/// ⚠ Build/SDK gating identical to `WorkoutPlanIntelligence`: `#if canImport(FoundationModels)` +
/// `@available(iOS 26.0, *)`, so it compiles against the app's iOS 18 target and weak-links +
/// activates only on capable iOS 26 devices; every other build/runtime returns the template lines.
enum FestivalPlanIntelligence {

    /// How a reason line was produced — surfaced so the UI can badge "written on device" and tests
    /// can assert the degrade path.
    enum Source: String, Sendable, Equatable {
        /// The recommender's deterministic template (the always-on floor).
        case template
        /// Rephrased by the on-device Foundation Models pass.
        case appleIntelligence
    }

    struct Line: Sendable, Equatable {
        var text: String
        var source: Source
    }

    /// `true` when the on-device model is usable right now — drives whether the sheet shows the
    /// "reasons written on device" note. Cheap + synchronous.
    static var isIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// One reason `Line` per suggestion, index-for-index. Tries the on-device model per card when
    /// available; **always** falls back to the recommender's `templateReason` on
    /// unavailability/error/timeout — so the caller can `await` this unconditionally and never
    /// branches on capability. Order and count exactly mirror `suggestions` (the ranking is the
    /// recommender's, untouched here).
    static func reasonLines(for suggestions: [SetRecommender.Suggestion]) async -> [Line] {
        let floor = suggestions.map { Line(text: $0.templateReason, source: .template) }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            var out = floor
            for (i, s) in suggestions.enumerated() {
                if let nicer = await rewrite(suggestion: s) {
                    out[i] = Line(text: nicer, source: .appleIntelligence)
                }
            }
            return out
        }
        #endif
        return floor
    }

    #if canImport(FoundationModels)
    /// The real on-device call: hand the model the recommender's FACTS + its template line and ask
    /// for a warmer one-liner that adds nothing. Returns nil on any failure (so the card keeps its
    /// template) and rejects an over-long / empty rewrite. Bounded by a short timeout.
    @available(iOS 26.0, *)
    private static func rewrite(suggestion s: SetRecommender.Suggestion) async -> String? {
        let facts = factSheet(for: s)
        let instructions = """
        You rewrite ONE short reason a festival-goer is being shown for why to add an artist's set to \
        their plan. Rephrase it into a single warm, natural sentence of at most 20 words. \
        Use ONLY the facts given — never invent a number, a venue, a time, or a claim that isn't there, \
        and keep every number exactly as written. Return just the sentence, no quotes.
        """
        do {
            return try await withTimeout(seconds: 6) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: facts, generating: ReasonSchema.self)
                let line = response.content.line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Guard: an empty or runaway rewrite falls back to the template.
                guard !line.isEmpty, line.count <= 200 else { return nil }
                return line
            }
        } catch {
            return nil
        }
    }

    /// The facts the model may use — the recommender's reason as plain prose plus the set label, so
    /// the model has nothing to hallucinate from.
    private static func factSheet(for s: SetRecommender.Suggestion) -> String {
        "Set: \(s.set.artist) on \(s.set.stage). Reason to show: \(s.templateReason)"
    }

    /// The `@Generable` single-field output — one rephrased line.
    @available(iOS 26.0, *)
    @Generable
    fileprivate struct ReasonSchema {
        @Guide(description: "The rephrased one-sentence reason, using only the given facts")
        var line: String
    }

    /// Race the generation against a timeout so a stalled model never wedges the sheet.
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
