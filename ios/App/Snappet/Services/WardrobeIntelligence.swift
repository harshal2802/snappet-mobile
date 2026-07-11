import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The Wardrobe's **optional on-device Apple-Intelligence layer** — same contract as
/// `WorkoutPlanIntelligence` (the locked E7 pattern): a heuristic floor that always
/// works, an AI pass that can only *refine*, and silent degradation on an older OS,
/// missing model assets, disabled Apple Intelligence, errors, or timeout. On-device
/// only (`LanguageModelSession`); no network, ever.
///
/// Two jobs:
/// 1. `sharpenTags` — refine the Vision draft (nicer name, pattern, material guess).
/// 2. `coach` — answer a styling question about an item, citing OWNED closet pieces.
///    The heuristic floor answers from `OutfitComposer.alternatives` + formality rules,
///    so the coach is useful on every device.
enum WardrobeIntelligence {

    static var isIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    // MARK: - Tag sharpening

    /// Refine a Vision draft. Returns the (possibly) improved draft; `sharpenedByAI`
    /// flips only when the model actually contributed.
    static func sharpenTags(_ draft: WardrobeVision.DraftTags, labels: [String]) async -> WardrobeVision.DraftTags {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let instructions = """
            You tag a single clothing item for a private wardrobe app. \
            Given classifier labels and a detected color, produce a short natural item name \
            (like "Navy flannel shirt"), a pattern (one of: solid, plaid, striped, floral, \
            graphic, dotted, textured), a likely material (like "Cotton", "Denim", "Wool", \
            "Leather"), and a style (one of: lounge, athletic, casual, smartCasual, business, formal). \
            Be conservative: prefer solid and casual when unsure.
            """
            let prompt = "Labels: \(labels.prefix(6).joined(separator: ", ")). Detected color: \(draft.color.title). Category: \(draft.category.title)."
            do {
                let refined: TagSchema = try await withTimeout(seconds: 8) {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: prompt, generating: TagSchema.self)
                    return response.content
                }
                var out = draft
                if let name = refined.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.suggestedName = name
                }
                if let p = refined.pattern.flatMap(GarmentPattern.init(rawValue:)) { out.pattern = p }
                if let s = refined.style.flatMap(GarmentStyle.init(rawValue:)) { out.style = s }
                if let m = refined.material, !m.isEmpty { out.material = m }
                out.sharpenedByAI = true
                return out
            } catch {
                return draft
            }
        }
        #endif
        return draft
    }

    // MARK: - Style coach

    /// A coach answer: prose + the closet items it cites (rendered as tappable mini-cards).
    struct CoachAnswer: Sendable, Equatable {
        var text: String
        var suggestedItemIDs: [UUID]
        var fromAI: Bool
    }

    /// Answer a styling question about `item`, using only `closet` (owned pieces).
    /// The heuristic floor is computed first and returned whenever the AI pass is
    /// unavailable or fails — the coach never comes back empty.
    static func coach(question: String, item: GarmentProfile, closet: [GarmentProfile],
                      season: GarmentSeason, tempBand: TempBand) async -> CoachAnswer {
        let floor = heuristicAnswer(question: question, item: item, closet: closet,
                                    season: season, tempBand: tempBand)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let inventory = closet.prefix(40)
                .map { "\($0.name) (\($0.category.title.lowercased()), \($0.color.rawValue), \($0.style.title.lowercased()))" }
                .joined(separator: "; ")
            let instructions = """
            You are a personal stylist. Answer briefly (2-3 sentences) about the user's item, \
            recommending ONLY pieces from their closet inventory. Refer to pieces by their exact names.
            """
            let prompt = """
            Item: \(item.name) (\(item.category.title.lowercased()), \(item.color.rawValue), \
            \(item.style.title.lowercased())). Closet: \(inventory). Question: \(question)
            """
            do {
                let reply: CoachSchema = try await withTimeout(seconds: 10) {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: prompt, generating: CoachSchema.self)
                    return response.content
                }
                // Map cited names back to owned items; anything unmatched is dropped.
                let cited = reply.recommendedItemNames.compactMap { name in
                    closet.first { $0.name.lowercased() == name.lowercased() }?.id
                }
                if !reply.answer.isEmpty {
                    return CoachAnswer(text: reply.answer,
                                       suggestedItemIDs: cited.isEmpty ? floor.suggestedItemIDs : cited,
                                       fromAI: true)
                }
            } catch {
                // fall through to the floor
            }
        }
        #endif
        return floor
    }

    /// The always-on coach: composer-ranked partners + formality arithmetic, templated.
    static func heuristicAnswer(question: String, item: GarmentProfile, closet: [GarmentProfile],
                                season: GarmentSeason, tempBand: TempBand) -> CoachAnswer {
        let q = question.lowercased()
        let request = OutfitRequest(occasion: .casualWeekend, season: season,
                                    tempBand: tempBand, buildAround: item.id)
        let outfit = OutfitComposer.compose(items: closet, request: request)
        let partners = (outfit?.slots ?? [])
            .filter { $0.itemID != item.id }
            .compactMap { slot in closet.first { $0.id == slot.itemID } }
        let partnerIDs = partners.map(\.id)
        let names = partners.prefix(3).map(\.name)

        if q.contains("business casual") || q.contains("is this business") {
            let f = item.style.formality
            let verdict: String
            switch f {
            case 4...: verdict = "Yes — \(item.name.lowercased()) reads \(item.style.title.lowercased()), which clears business casual."
            case 3: verdict = "Yes, \(item.name.lowercased()) sits right in the business-casual window."
            default: verdict = "Borderline — \(item.name.lowercased()) reads \(item.style.title.lowercased()). It passes when you pair it with sharper pieces\(names.isEmpty ? "." : ", like your \(names.joined(separator: " and ")).")"
            }
            return CoachAnswer(text: verdict, suggestedItemIDs: partnerIDs, fromAI: false)
        }
        if q.contains("color") {
            let friendly = closet
                .filter { $0.id != item.id && GarmentColorFamily.harmony(item.color, $0.color) >= 0.8 }
                .prefix(3).map(\.name)
            let families = GarmentColorFamily.allCases
                .filter { GarmentColorFamily.harmony(item.color, $0) >= 0.8 && $0 != item.color }
                .prefix(4).map { $0.title.lowercased() }
            var text = "\(item.color.title) works with \(families.joined(separator: ", "))."
            if !friendly.isEmpty { text += " From your closet: \(friendly.joined(separator: ", "))." }
            return CoachAnswer(text: text, suggestedItemIDs: partnerIDs, fromAI: false)
        }
        // Default: "what goes with this" / "how should I wear this"
        guard !names.isEmpty else {
            return CoachAnswer(text: "Add a few more pieces (a bottom and shoes) and I can build around \(item.name.lowercased()).",
                               suggestedItemIDs: [], fromAI: false)
        }
        var text = "From your closet, \(names.joined(separator: ", ")) pair\(names.count == 1 ? "s" : "") well with \(item.name.lowercased())."
        if tempBand.needsOuterLayer, let layer = partners.first(where: { $0.category == .outerwear }) {
            text += " Layer the \(layer.name.lowercased()) when it's \(tempBand.title.lowercased())."
        }
        return CoachAnswer(text: text, suggestedItemIDs: partnerIDs, fromAI: false)
    }

    // MARK: - FM plumbing

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    fileprivate struct TagSchema {
        @Guide(description: "Short natural item name like 'Navy flannel shirt'")
        var name: String?
        @Guide(description: "One of: solid, plaid, striped, floral, graphic, dotted, textured")
        var pattern: String?
        @Guide(description: "One of: lounge, athletic, casual, smartCasual, business, formal")
        var style: String?
        @Guide(description: "Likely material, like Cotton, Denim, Wool, Leather; null if unclear")
        var material: String?
    }

    @available(iOS 26.0, *)
    @Generable
    fileprivate struct CoachSchema {
        @Guide(description: "The stylist's answer, 2-3 sentences, citing closet pieces by exact name")
        var answer: String
        @Guide(description: "Exact names of the closet pieces recommended, up to 3")
        var recommendedItemNames: [String]
    }

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
