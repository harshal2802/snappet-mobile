import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The **optional on-device Apple-Intelligence sharpener** for poster scanning (festival prompt 06,
/// the E7 contract — the same seam as `FestivalPlanIntelligence` / `WorkoutPlanIntelligence`). The pure
/// `FestivalPosterParser` is the heuristic FLOOR: it always turns the OCR text into an editable
/// `FestivalDraft`. WHEN Apple's on-device **Foundation Models** are available, this restructures the
/// SAME noisy text into a better-organized draft (days → stages → sets with cleaner artist names and
/// start/end times) that the user still reviews and edits before anything installs.
///
/// **Silent degradation:** no Apple Intelligence entitlement, an older OS, an unsupported device, model
/// assets not downloaded, a model error, a timeout, or an empty/degenerate result ⇒ the caller gets the
/// heuristic floor draft. The floor is the always-on path; the AI pass can never break it, and it can
/// never install anything — it only pre-fills the review form.
///
/// **On-device only** — `LanguageModelSession` runs the system model locally; no network, no server LLM
/// (the hard constraint). This is one of only two festival files that import `FoundationModels`
/// (platform-I/O-at-the-edge); the parser, draft, validator, and installer stay pure/deterministic.
///
/// ⚠ Build/SDK gating identical to `FestivalPlanIntelligence`: `#if canImport(FoundationModels)` +
/// `@available(iOS 26.0, *)`, so it compiles against the app's iOS 18 target and activates only on
/// capable iOS 26 devices; every other build/runtime returns the floor draft.
enum FestivalPosterIntelligence {

    /// `true` when the on-device model is usable right now — drives whether the review form badges
    /// "structured on device". Cheap + synchronous.
    static var isIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// The one entry point the capture flow calls: hand it the OCR text and the offset, get back the
    /// draft to review. **Always** returns a usable draft — the FM-structured one when the model is
    /// available AND produced something at least as complete as the floor, otherwise the pure floor.
    /// So the caller can `await` this unconditionally and never branches on capability.
    static func draft(fromOCR ocrText: String, defaultOffsetSeconds: Int) async -> FestivalDraft {
        let floor = FestivalPosterParser.parse(ocrText: ocrText,
                                               defaultOffsetSeconds: defaultOffsetSeconds)

        // UI-test seam: the on-device model is real, slow, and nondeterministic on a capable host, so
        // XCUITests that walk the capture flow force the deterministic pure floor (they exercise the
        // parse → review → validate-before-install chrome, not the model — that's a device leg).
        if ProcessInfo.processInfo.arguments.contains("-uiTestPosterFloorOnly") { return floor }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            if var refined = await structure(ocrText: ocrText, defaultOffsetSeconds: defaultOffsetSeconds),
               refined.allSetCount >= floor.allSetCount, refined.allSetCount > 0 {
                refined.source = .appleIntelligence
                refined.ocrText = ocrText
                return refined
            }
        }
        #endif
        return floor
    }

    #if canImport(FoundationModels)
    /// The real on-device call: ask the model to organize the noisy poster OCR into a structured
    /// lineup. Returns nil on any failure (so the caller keeps the floor) or an empty result. Bounded
    /// by a short timeout so a stalled model never wedges the capture flow.
    @available(iOS 26.0, *)
    private static func structure(ocrText: String, defaultOffsetSeconds: Int) async -> FestivalDraft? {
        let instructions = """
        You organize the raw OCR text of a printed music-festival lineup poster into structured data. \
        Group the acts by day, then by stage, and list each set's artist with its start and (if the \
        poster shows one) end time in 24-hour HH:mm. Use ONLY names and times that appear in the text — \
        never invent an artist, a stage, or a time. If a field isn't in the text, leave it empty. \
        Dates are yyyy-MM-dd. Return the festival name, location, and days.
        """
        do {
            let generated = try await withTimeout(seconds: 12) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: ocrText, generating: PosterSchema.self)
                return response.content
            }
            return mapToDraft(generated, defaultOffsetSeconds: defaultOffsetSeconds)
        } catch {
            return nil
        }
    }

    /// Map the `@Generable` output to our editable draft, normalizing times through the same pure
    /// helpers the floor uses (so an FM-emitted `"9:30"` becomes `"09:30"` exactly as a scanned one
    /// would). Nothing here trusts the model's structure blindly — it's a draft the user still reviews.
    @available(iOS 26.0, *)
    private static func mapToDraft(_ poster: PosterSchema, defaultOffsetSeconds: Int) -> FestivalDraft {
        let days: [FestivalDraft.DraftDay] = poster.days.map { day in
            FestivalDraft.DraftDay(date: day.date.trimmingCharacters(in: .whitespaces),
                                   stages: day.stages.map { stage in
                FestivalDraft.DraftStage(name: stage.name.trimmingCharacters(in: .whitespaces),
                                         sets: stage.sets.map { set in
                    let start = FestivalPosterParser.normalizedTime(set.start) ?? set.start
                    let end = FestivalPosterParser.normalizedTime(set.end)
                        ?? FestivalPosterParser.addMinutes(start, FestivalPosterParser.defaultSetMinutes)
                    return FestivalDraft.DraftSet(artist: set.artist.trimmingCharacters(in: .whitespaces),
                                                  start: start, end: end)
                })
            })
        }
        return FestivalDraft(name: poster.name.trimmingCharacters(in: .whitespaces),
                             location: poster.location.trimmingCharacters(in: .whitespaces),
                             startDate: days.first?.date ?? "", endDate: days.last?.date ?? "",
                             utcOffsetSeconds: defaultOffsetSeconds, days: days,
                             source: .appleIntelligence)
    }

    // MARK: - `@Generable` schema (nested lineup structure)

    @available(iOS 26.0, *)
    @Generable
    fileprivate struct PosterSchema {
        @Guide(description: "The festival's name, exactly as printed") var name: String
        @Guide(description: "The venue/location if the poster shows one, else empty") var location: String
        @Guide(description: "The festival's days, each with its stages and sets") var days: [DaySchema]
    }

    @available(iOS 26.0, *)
    @Generable
    fileprivate struct DaySchema {
        @Guide(description: "The day's date as yyyy-MM-dd if known, else empty") var date: String
        @Guide(description: "The stages performing that day") var stages: [StageSchema]
    }

    @available(iOS 26.0, *)
    @Generable
    fileprivate struct StageSchema {
        @Guide(description: "The stage's name") var name: String
        @Guide(description: "The sets on that stage, in time order") var sets: [SetSchema]
    }

    @available(iOS 26.0, *)
    @Generable
    fileprivate struct SetSchema {
        @Guide(description: "The performing artist, exactly as printed") var artist: String
        @Guide(description: "Start time as 24-hour HH:mm") var start: String
        @Guide(description: "End time as 24-hour HH:mm, or empty if the poster doesn't show one") var end: String
    }

    /// Race the generation against a timeout so a stalled model never wedges the capture flow.
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
