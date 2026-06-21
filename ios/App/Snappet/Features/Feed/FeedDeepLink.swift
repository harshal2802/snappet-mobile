import Foundation

// MARK: - Recap Feed — pure deep-link target mapping (F2)
//
// Maps a card's source activity (objectKind + objectRef) to the module session-detail it opens.
// Pure + testable; the actual router push lives in the view.

enum FeedDeepLink {
    enum Target: Equatable {
        case kilterSession(UUID)
        case workoutSession(UUID)
        case none
    }

    static func target(objectKind: String, objectRef: String) -> Target {
        guard let id = UUID(uuidString: objectRef) else { return .none }
        switch objectKind {
        case "kilterSession": return .kilterSession(id)
        case "workoutSession": return .workoutSession(id)
        default: return .none
        }
    }

    static func target(for card: FeedCard) -> Target {
        guard let ref = card.sourceRefs.first else { return .none }
        return target(objectKind: ref.objectKind, objectRef: ref.ref)
    }
}
