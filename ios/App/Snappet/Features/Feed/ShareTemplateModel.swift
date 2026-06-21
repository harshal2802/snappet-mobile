import Foundation
import CoreGraphics

// MARK: - Recap Feed — ShareComposer pure model (F4 / R3)
//
// The share-composer's testable core. Foundation + CoreGraphics ONLY — no SwiftUI /
// AVFoundation / UIKit — so it unit-tests without a simulator. It owns:
//   • `ShareAspect` → the EXACT export pixel size (the cropping-bug mitigation): the renderer
//     produces literal target pixels so Instagram / iMessage perform zero re-crop.
//   • `eligibleTemplates(for:)` — payload gating so the picker never shows a dead thumbnail.
//   • `defaultVisibleMetrics(for:)` — the metric set shown by default per card kind (R5 wires the
//     live toggles into the templates; this is the seam).
//   • `shareChannel(forActivityType:)` — the `FeedShareEvent` channel derived from the chosen
//     `UIActivityType` raw string (a pure String → String map; no UIKit dependency).

// MARK: Aspect → exact pixel size

/// The three share aspect ratios. `exportPixelSize` is the LITERAL target pixel size the
/// renderer must emit (no intrinsic sizing, no Apple re-crop); `previewSize` is the smaller
/// point size used for the on-screen WYSIWYG preview.
enum ShareAspect: String, CaseIterable, Identifiable, Sendable {
    case r9x16 = "9:16"
    case r4x5  = "4:5"
    case r1x1  = "1:1"

    var id: String { rawValue }

    /// EXACT export dimensions in pixels (the cropping-bug mitigation). These are the literal
    /// canonical social sizes: 9:16 → 1080×1920, 4:5 → 1080×1350, 1:1 → 1080×1080.
    var exportPixelSize: CGSize {
        switch self {
        case .r9x16: return CGSize(width: 1080, height: 1920)
        case .r4x5:  return CGSize(width: 1080, height: 1350)
        case .r1x1:  return CGSize(width: 1080, height: 1080)
        }
    }

    /// On-screen preview size (points). Same aspect ratio as `exportPixelSize` so preview == export.
    var previewSize: CGSize {
        switch self {
        case .r9x16: return CGSize(width: 360, height: 640)
        case .r4x5:  return CGSize(width: 360, height: 450)
        case .r1x1:  return CGSize(width: 360, height: 360)
        }
    }

    /// The aspect ratio (width / height) — handy for layout + dimension assertions.
    var ratio: CGFloat { exportPixelSize.width / exportPixelSize.height }
}

// MARK: Template kinds (currently-implemented set)

/// The share templates that actually have a rendering view today. Kept to the CURRENTLY-IMPLEMENTED
/// set so the composer's exhaustive switch never offers a dead thumbnail.
///
/// R5: add `gradePRTicket` / `boardPolaroid` / `pyramidCard` here AND their `ShareCardView` (or
/// dedicated template) rendering + extend `eligibleTemplates(for:)` gating below. Do NOT add a case
/// before its view exists — it would surface a thumbnail with nothing behind it.
enum ShareTemplateKind: String, CaseIterable, Identifiable, Sendable {
    case card    = "Send Card"
    case receipt = "Receipt"
    // R5: case gradePRTicket = "Grade PR", boardPolaroid = "Polaroid", pyramidCard = "Pyramid"

    var id: String { rawValue }

    /// The pure `ShareTemplate` (F0 `shareHint`) this kind corresponds to — lets the composer
    /// pre-select from a card's `shareHint` and lets R5 map new hints to new kinds.
    var shareTemplate: ShareTemplate {
        switch self {
        case .card:    return .sendCard
        case .receipt: return .sessionReceipt
        }
    }
}

// MARK: Toggleable metrics

/// The fields a user can show/hide on an exported card. R3 defines the enum + per-card defaults;
/// R5 wires the live toggles into the templates so preview == export.
enum ShareMetric: String, CaseIterable, Identifiable, Sendable {
    case headline   // the big hero number/grade
    case subtitle   // the kicker line ("Climb session", "New hardest ever", …)
    case primary    // the first supporting stat line
    case secondary  // the remaining supporting stat lines (receipt-style)
    case branding   // the "snappet · recap" footer

    var id: String { rawValue }
}

// MARK: - The pure model

enum ShareTemplateModel {

    // MARK: Template gating (no dead thumbnails)

    /// The templates a card's `payload` actually supports.
    ///
    /// Every card supports **Send Card** (a single hero stat always renders). A card adds
    /// **Receipt** only when it carries multi-line / session data worth a stacked receipt
    /// (climb / workout sessions, the on-the-board board summary, and the pyramid).
    static func eligibleTemplates(for card: FeedCard) -> [ShareTemplateKind] {
        var kinds: [ShareTemplateKind] = [.card]   // Send Card: universal.

        if supportsReceipt(card.payload) {
            kinds.append(.receipt)
        }

        // R5: append .gradePRTicket when case .gradePR; .boardPolaroid when a board/clip session;
        //     .pyramidCard when case .pyramid / .pyramidHealth (needs >= 1 pyramid row).
        return kinds
    }

    /// A Receipt needs multi-line session-shaped data (several stat lines stacked). Single-number
    /// milestone / trend / insight cards stay Send-Card-only — no empty receipt rows.
    private static func supportsReceipt(_ payload: FeedCardPayload) -> Bool {
        switch payload {
        case .climbSession, .workoutSession, .onTheBoard, .pyramid:
            return true
        default:
            return false
        }
    }

    // MARK: Default visible metrics

    /// The metric set shown by default for a card. Session/receipt-style cards default to the full
    /// stacked set; single-stat cards hide the `secondary` lines. R5 lets the user toggle from here.
    static func defaultVisibleMetrics(for card: FeedCard) -> Set<ShareMetric> {
        let base: Set<ShareMetric> = [.headline, .subtitle, .primary, .branding]
        if supportsReceipt(card.payload) {
            return base.union([.secondary])
        }
        return base
    }

    // MARK: ShareEvent channel derivation

    /// Map a chosen share destination (`UIActivity.ActivityType.rawValue`, passed in as a plain
    /// String so this stays UIKit-free) to a `FeedShareEvent.channel`.
    ///
    /// `nil` (sheet dismissed without a known activity, or completion gave no type) → `export:share`.
    static func shareChannel(forActivityType activityType: String?) -> String {
        guard let raw = activityType, !raw.isEmpty else { return Channel.share }
        let lower = raw.lowercased()

        // Instagram (Stories sticker / feed) — third-party activity, e.g.
        // "com.burbn.instagram.shareextension" / "...PostToInstagram".
        if lower.contains("instagram") { return Channel.instagram }
        // Messages — "com.apple.UIKit.activity.Message".
        if lower.contains("message") { return Channel.imessage }
        // Save to Photos / camera roll — "com.apple.UIKit.activity.SaveToCameraRoll".
        if lower.contains("savetocameraroll") || lower.contains("camera") || lower.contains("photo") {
            return Channel.photos
        }
        return Channel.share
    }

    /// The canonical `export:*` channel strings (the seam: `export:*` today, `user:*` tomorrow).
    enum Channel {
        static let instagram = "export:instagram"
        static let imessage  = "export:imessage"
        static let photos    = "export:photos"
        static let share     = "export:share"
        static let clip      = "export:clip"
    }
}
