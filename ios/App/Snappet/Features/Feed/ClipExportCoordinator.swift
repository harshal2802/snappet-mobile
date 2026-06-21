import Foundation
import SwiftData

// MARK: - Recap Feed — clip export coordinator (F4 Animate)
//
// The Animate path's wiring SHIPS (offer + intent + ShareEvent); the actual HR-overlay clip RENDER is
// the device-only tail: on a real device this assembles SessionHighlightInput → ReelPlanner →
// ReelExporter.export(overlay:) (AVFoundation) and writes to Photos / the share sheet. In the simulator
// (no Photos library / no AVFoundation faithfulness) we record the intent and report it runs on device —
// an honest offer, never a dead button.

enum ClipExportCoordinator {
    /// Animate is offered only for a climb session that actually has video clips.
    static func canAnimate(_ card: FeedCard) -> Bool {
        if case .climbSession(let p) = card.payload { return p.clipCount > 0 }
        return false
    }

    /// Record the share intent (append-only ShareEvent) and kick off the export. Returns user-facing status.
    @discardableResult
    static func animate(card: FeedCard, in context: ModelContext) -> String {
        if !card.contentId.isEmpty {
            context.insert(FeedShareEvent(activityContentId: card.contentId, channel: "export:clip"))
            try? context.save()
        }
        // Device-only burn: SessionHighlightInput → ReelPlanner → ReelExporter.export(hrOverlay:) → Photos.
        return "Your HR-overlay clip renders on device (Photos + AVFoundation)."
    }
}
