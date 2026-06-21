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
/// R5 completes the named library: `card`/`receipt` (R3) + the three bespoke templates
/// `gradePRTicket` / `boardPolaroid` / `pyramidCard`, each backed by a view in `ShareTemplates.swift`
/// and gated by payload in `eligibleTemplates(for:)` below (no thumbnail without a view behind it).
enum ShareTemplateKind: String, CaseIterable, Identifiable, Sendable {
    case card         = "Send Card"
    case receipt      = "Receipt"
    case gradePRTicket = "Grade PR Ticket"
    case boardPolaroid = "Board Polaroid"
    case pyramidCard   = "Pyramid Card"

    var id: String { rawValue }

    /// The pure `ShareTemplate` (F0 `shareHint`) this kind corresponds to — lets the composer
    /// pre-select from a card's `shareHint` and lets R5 map new hints to new kinds.
    var shareTemplate: ShareTemplate {
        switch self {
        case .card:          return .sendCard
        case .receipt:       return .sessionReceipt
        case .gradePRTicket: return .gradePRTicket
        case .boardPolaroid: return .boardPolaroid
        case .pyramidCard:   return .pyramidCard
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

    /// A short, human-readable label for the metric toggle chip (R5). Pure String — no SwiftUI.
    var chipLabel: String {
        switch self {
        case .headline:  return "Hero"
        case .subtitle:  return "Kicker"
        case .primary:   return "Stat"
        case .secondary: return "More"
        case .branding:  return "Logo"
        }
    }
}

// MARK: - The pure model

enum ShareTemplateModel {

    // MARK: Template gating (no dead thumbnails)

    /// The templates a card's `payload` actually supports.
    ///
    /// Every card supports **Send Card** (a single hero stat always renders). The rest are
    /// payload-gated so the picker never shows a dead thumbnail:
    ///   • **Receipt** — only genuinely multi-line session data (`.climbSession` / `.workoutSession`).
    ///   • **Grade PR Ticket** — only a `.gradePR` payload (the new-grade hero + "up from X").
    ///   • **Board Polaroid** — board moments: `.climbSession` and `.onTheBoard`.
    ///   • **Pyramid Card** — the grade pyramid: `.pyramid` and `.pyramidHealth` (carries per-grade rows).
    ///
    /// R3-nit fix: `.onTheBoard` / `.pyramid` were dropped from Receipt — they now get their bespoke
    /// Board Polaroid / Pyramid Card instead of a generic stacked receipt.
    static func eligibleTemplates(for card: FeedCard) -> [ShareTemplateKind] {
        var kinds: [ShareTemplateKind] = [.card]   // Send Card: universal.

        if supportsReceipt(card.payload) { kinds.append(.receipt) }
        if supportsGradePRTicket(card.payload) { kinds.append(.gradePRTicket) }
        if supportsBoardPolaroid(card.payload) { kinds.append(.boardPolaroid) }
        if supportsPyramidCard(card.payload) { kinds.append(.pyramidCard) }

        return kinds
    }

    /// A Receipt needs genuinely multi-line session-shaped data (several stat lines stacked): only
    /// the climb / workout sessions. Single-number milestone / trend / insight cards — and the board
    /// summary / pyramid, which get their own bespoke templates — stay off the Receipt.
    private static func supportsReceipt(_ payload: FeedCardPayload) -> Bool {
        switch payload {
        case .climbSession, .workoutSession:
            return true
        default:
            return false
        }
    }

    /// The Grade PR Ticket is the new-grade hero + "up from X" — only a `.gradePR` payload carries it.
    private static func supportsGradePRTicket(_ payload: FeedCardPayload) -> Bool {
        if case .gradePR = payload { return true }
        return false
    }

    /// The Board Polaroid is a framed climb/board moment — climb sessions and the on-the-board summary.
    private static func supportsBoardPolaroid(_ payload: FeedCardPayload) -> Bool {
        switch payload {
        case .climbSession, .onTheBoard:
            return true
        default:
            return false
        }
    }

    /// The Pyramid Card draws per-grade pyramid rows — the all-time pyramid and the pyramid-health nudge.
    private static func supportsPyramidCard(_ payload: FeedCardPayload) -> Bool {
        switch payload {
        case .pyramid, .pyramidHealth:
            return true
        default:
            return false
        }
    }

    // MARK: Default visible metrics

    /// The metric set shown by default for a card. Multi-line cards (sessions, the board summary, the
    /// pyramid — anything with stacked supporting stats) default to the full set including `secondary`;
    /// single-stat cards hide the `secondary` lines. R5 lets the user toggle live from this seed.
    static func defaultVisibleMetrics(for card: FeedCard) -> Set<ShareMetric> {
        let base: Set<ShareMetric> = [.headline, .subtitle, .primary, .branding]
        if hasStackedSecondary(card.payload) {
            return base.union([.secondary])
        }
        return base
    }

    /// Whether a payload carries stacked secondary stat lines worth showing by default — the
    /// multi-line sessions plus the bespoke board / pyramid cards (R5).
    private static func hasStackedSecondary(_ payload: FeedCardPayload) -> Bool {
        switch payload {
        case .climbSession, .workoutSession, .onTheBoard, .pyramid, .pyramidHealth:
            return true
        default:
            return false
        }
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
