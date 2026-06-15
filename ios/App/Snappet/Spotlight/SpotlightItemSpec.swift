import Foundation

/// A platform-free description of one Spotlight entry (#81 Phase 4). The `identifier` is the
/// `snappet://` deep-link URL — it doubles as the `CSSearchableItem` uniqueIdentifier AND the routing
/// target, so a Spotlight tap reuses the same URL routing as the QR / widget / Siri paths (one brain).
/// Pure + unit-tested; `SpotlightIndexer` turns these into `CSSearchableItem`s (the CoreSpotlight edge).
struct SpotlightItemSpec: Equatable {
    /// A `snappet://` URL string (the deep-link target = the stable id).
    var identifier: String
    /// `CSSearchableItem.domainIdentifier` — groups a type so it can be bulk-reindexed/removed.
    var domain: String
    var title: String
    var contentDescription: String
    var keywords: [String]
}

/// Builds `SpotlightItemSpec`s for the indexable content (#81 Phase 4). Pure — no CoreSpotlight, no
/// SwiftData (callers pass primitives / value types) — so it's unit-tested with no device.
enum SpotlightCatalog {
    static let exerciseDomain = "com.snappet.exercise"
    static let createdClimbDomain = "com.snappet.kilter.createdClimb"

    /// `snappet://exercise/<id>` → the gym tracker's `ExerciseDetailView`.
    static func exerciseSpec(_ exercise: Exercise) -> SpotlightItemSpec {
        var components = URLComponents()
        components.scheme = "snappet"
        components.host = "exercise"
        components.path = "/\(exercise.id)"
        // Keywords: the name plus the words of its subtitle ("Barbell · Compound · Chest"), so a
        // search on equipment / muscle / mechanic also surfaces it — without depending on the
        // individual enum internals.
        let keywords = ([exercise.name]
            + exercise.subtitle.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) })
            .filter { !$0.isEmpty }
        return SpotlightItemSpec(
            identifier: components.url?.absoluteString ?? "",
            domain: exerciseDomain,
            title: exercise.name,
            contentDescription: exercise.subtitle,
            keywords: keywords)
    }

    /// The stable Spotlight identifier (= deep-link URL) for a created climb. One source of truth so
    /// the index path and the **de-index on delete** path (`SpotlightIndexer.deindexCreatedClimb`)
    /// can't drift.
    static func createdClimbIdentifier(uuid: String, angle: Int) -> String {
        KilterClimbLink(uuid: uuid, angle: angle).encoded
    }

    /// `snappet://kilter/climb/<uuid>?angle=<n>` → the climb (the existing `KilterClimbLink` route,
    /// which already resolves user-created climbs).
    static func createdClimbSpec(uuid: String, name: String, setter: String,
                                 angle: Int) -> SpotlightItemSpec {
        return SpotlightItemSpec(
            identifier: createdClimbIdentifier(uuid: uuid, angle: angle),
            domain: createdClimbDomain,
            title: name,
            contentDescription: "Created climb · \(angle)°",
            keywords: [name, setter, "kilter", "climb"].filter { !$0.isEmpty })
    }
}
