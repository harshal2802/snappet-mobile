import Foundation

// MARK: - Clips feed — "Share with heart rate" (prompt 160, pure)
//
// The ⋯ menu's share used to hand over the RAW clip (prompt 87): the HR scorebug — the thing that makes a
// Clips post a Clips post — only shipped via ⋯ → Edit this clip → Studio → Export. This is the pure half
// of the one-tap burned share: WHICH share actions a clip offers, and WHAT the render burns. The render
// itself (AVFoundation + the Studio's Core-Animation overlay tool) lives in `ClipShareService`.
//
// WYSIWYG by construction: the burned tile is resolved from the SAME `ClipHROverlay.Payload` the poster,
// the inline player and the fullscreen viewer draw (feed scorebug, or the session's saved Studio tile),
// over the SAME kept (trimmed) range the feed plays. No second window/tile derivation to drift.

enum ClipSharePlan {

    /// What the ⋯ menu offers for the centred clip.
    enum Offer: Equatable {
        /// A photo — nothing to share from this menu (the Studio is video-only too).
        case none
        /// Raw share only: a posted reel / baked clip already carries its HR in the pixels, and a clip
        /// with no HR in its window has nothing to burn.
        case raw
        /// "Share with heart rate" (primary) + "Share original clip".
        case burnedAndRaw
    }

    /// The burned render's inputs — plain values, built on the MainActor, rendered off it.
    struct Plan: Sendable, Equatable {
        var localIdentifier: String
        /// Kept range within the source asset (seconds). The service clamps `duration` to the asset's
        /// real length (the stored `durationSec` is approximate) and re-slots the HR tile to match.
        var start: Double
        var duration: Double
        /// The clip's HR window samples (window-local) + the resolved tile, slotted over the whole render.
        var hr: PlacedClipHR
        /// The post's lower-third ("V5 Crimp Line · 6C · 40° · Attempt 2"), or nil when there's no name.
        var caption: String?
    }

    static func offer(for clip: MediaInput, payload: ClipHROverlay.Payload?) -> Offer {
        guard clip.kind == "video" else { return .none }
        // A reel / baked clip plays raw everywhere — sharing it raw IS sharing the burned version.
        if clip.isReel || clip.isBaked { return .raw }
        return plan(clip: clip, payload: payload, title: "", detail: "", attemptLabel: nil) == nil
            ? .raw : .burnedAndRaw
    }

    /// The burned render for `clip`, or nil when there's nothing to burn (photo, reel, baked, no HR,
    /// or a payload whose tile resolves to nothing — the same `resolveTile` gate the export uses).
    static func plan(clip: MediaInput, payload: ClipHROverlay.Payload?,
                     title: String, detail: String, attemptLabel: String?) -> Plan? {
        guard clip.kind == "video", !clip.isReel, !clip.isBaked,
              let payload, let tile = payload.values.resolveTile(payload.tile) else { return nil }
        let played = ClipHROverlay.playedRange(clip)
        guard played.span > 0.1 else { return nil }
        return Plan(localIdentifier: clip.localIdentifier,
                    start: played.start,
                    duration: played.span,
                    hr: PlacedClipHR(startSec: 0, durationSec: played.span,
                                     samples: payload.values.samples, tile: tile),
                    caption: caption(title: title, detail: detail, attemptLabel: attemptLabel))
    }

    /// The poster's name overlay flattened to one line: title · detail · attempt chip, blanks dropped.
    static func caption(title: String, detail: String, attemptLabel: String?) -> String? {
        let parts = [title, detail, attemptLabel ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Re-slot the plan's HR tile over the duration the render ACTUALLY inserted (the asset can be a
    /// hair shorter than the stored `durationSec`) so the dot parks on the last frame, not past it.
    static func clamped(_ plan: Plan, assetDuration: Double) -> Plan? {
        let available = assetDuration - plan.start
        guard available > 0.1 else { return nil }
        var p = plan
        p.duration = min(plan.duration, available)
        p.hr.durationSec = p.duration
        return p
    }
}
