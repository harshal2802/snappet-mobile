import SwiftUI

/// Module descriptor for the Festival mini-app — "lineups, sets & your night" (festival prompt 02).
/// Second resident of the Lifestyle category; UV-orchid accent (`SnappetColor.festival`). The module
/// owns the lineup *domain* (festivals → days → stages → sets, installed as hosted `.fpack` packs);
/// being at a set rides a dance-discipline `WorkoutSession` — the Kilter shape, not the Wardrobe one.
enum FestivalModule {
    /// Stable persisted id (`UsageRecord.module`, accent mapping, future deep links) — never follows
    /// a display rename (the #74 id-vs-display rule).
    static let id = "festival"

    @MainActor static var module: AppModule {
        AppModule(id: id, title: "Festival", subtitle: "Lineups, sets & your night",
                  systemImage: "music.mic", tint: SnappetColor.moduleAccent(id),
                  category: .lifestyle) { FestivalRootView() }
    }
}
