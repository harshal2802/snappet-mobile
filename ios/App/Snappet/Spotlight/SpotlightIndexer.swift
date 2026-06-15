import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import SwiftData

/// Indexes Snappet's content into Spotlight (#81 Phase 4): the exercise catalog + the user's created
/// climbs, each as a `CSSearchableItem` whose `uniqueIdentifier` is its `snappet://` deep-link URL (so
/// a tap routes through the same brain as `onOpenURL`). The spec building is the pure, tested
/// `SpotlightCatalog`; this is the thin CoreSpotlight edge. Run once per launch — `CSSearchableIndex`
/// dedupes by identifier — and skipped under UI-test launches (don't pollute the index / waste work).
@MainActor
enum SpotlightIndexer {
    static func reindex(context: ModelContext) {
        guard !isUITestLaunch else { return }

        var items = ExerciseCatalog.all.map { item(for: SpotlightCatalog.exerciseSpec($0)) }

        let createdClimbs = (try? context.fetch(FetchDescriptor<KilterCreatedClimb>())) ?? []
        items += createdClimbs.map {
            item(for: SpotlightCatalog.createdClimbSpec(
                uuid: $0.uuid, name: $0.name, setter: $0.setterUsername, angle: $0.angle))
        }

        CSSearchableIndex.default().indexSearchableItems(items)
    }

    /// Remove a created climb's Spotlight entry when it's deleted (#81 Phase 4 review fix). `reindex`
    /// is additive (it never evicts), so without this a deleted climb stays searchable forever (the
    /// fixed exercise catalog self-heals on re-index, but user climbs don't). `nonisolated` so the
    /// `@Model`'s static `delete` can call it; CoreSpotlight is thread-safe. Same identifier the index
    /// path uses, so it always matches.
    nonisolated static func deindexCreatedClimb(uuid: String, angle: Int) {
        guard !isUITestLaunch else { return }
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: [SpotlightCatalog.createdClimbIdentifier(uuid: uuid, angle: angle)])
    }

    private static func item(for spec: SpotlightItemSpec) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = spec.title
        attributes.contentDescription = spec.contentDescription
        attributes.keywords = spec.keywords
        return CSSearchableItem(uniqueIdentifier: spec.identifier,
                                domainIdentifier: spec.domain,
                                attributeSet: attributes)
    }

    nonisolated private static var isUITestLaunch: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-uiTestFreshStore")
            || args.contains("-uiTestCorruptStore")
            || args.contains("-uiTestSeedStudioDemo")
    }
}
