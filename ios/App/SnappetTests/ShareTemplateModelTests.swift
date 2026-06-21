import XCTest
import CoreGraphics
@testable import Snappet

/// F4 (R3) — the ShareComposer pure model: exact-dimension aspect math, template gating by payload,
/// default visible-metric sets, and `FeedShareEvent` channel derivation. Pure: no device, no SwiftUI.
final class ShareTemplateModelTests: XCTestCase {

    // MARK: Fixtures

    /// A rich, session-shaped card (multi-line) → supports Receipt.
    private func climbSessionCard() -> FeedCard {
        let payload = ClimbSessionPayload(
            title: "Evening session", hardestSendGrade: "V6",
            totalClimbs: 12, sends: 8, projects: 2, attemptsOnly: 2, totalAttempts: 20,
            durationSec: 3600, angle: 40, pyramid: [], isPRSession: false)
        return FeedCard(id: "c1", contentId: "cid-1", kind: .a1Session, category: .climbing,
                        salience: 0.5, anchorDate: Date(timeIntervalSince1970: 0),
                        sourceRefs: [], payload: .climbSession(payload),
                        shareHint: .sessionReceipt)
    }

    /// A sparse, single-stat card → Send Card only.
    private func streakCard() -> FeedCard {
        let payload = StreakPayload(days: 5, weeks: 1)
        return FeedCard(id: "s1", contentId: "cid-2", kind: .b5Streak, category: .milestone,
                        salience: 0.6, anchorDate: Date(timeIntervalSince1970: 0),
                        sourceRefs: [], payload: .streak(payload), shareHint: .sendCard)
    }

    // MARK: Aspect → exact pixel dimensions

    func testExportPixelSizeIsExactPerAspect() {
        XCTAssertEqual(ShareAspect.r9x16.exportPixelSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ShareAspect.r4x5.exportPixelSize,  CGSize(width: 1080, height: 1350))
        XCTAssertEqual(ShareAspect.r1x1.exportPixelSize,  CGSize(width: 1080, height: 1080))
    }

    func testExportRatiosMatchTheirNames() {
        XCTAssertEqual(ShareAspect.r9x16.ratio, 9.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(ShareAspect.r4x5.ratio,  4.0 / 5.0,  accuracy: 0.0001)
        XCTAssertEqual(ShareAspect.r1x1.ratio,  1.0,        accuracy: 0.0001)
    }

    func testPreviewSizeSharesAspectRatioWithExport() {
        for aspect in ShareAspect.allCases {
            let p = aspect.previewSize, e = aspect.exportPixelSize
            XCTAssertEqual(p.width / p.height, e.width / e.height, accuracy: 0.0001,
                           "preview must share the export aspect ratio (WYSIWYG): \(aspect)")
        }
    }

    func testExportScaleIsAnExactIntegerMultipleOfPreviewWidth() {
        // The renderer derives scale = exportWidth / previewWidth; assert it's the clean 3.0 the
        // canonical 1080-wide sizes intend (no fractional re-sampling).
        for aspect in ShareAspect.allCases {
            let scale = aspect.exportPixelSize.width / aspect.previewSize.width
            XCTAssertEqual(scale, 3.0, accuracy: 0.0001, "scale should be 3.0 for \(aspect)")
        }
    }

    // MARK: eligibleTemplates gating

    func testRichPayloadOffersCardAndReceipt() {
        let kinds = ShareTemplateModel.eligibleTemplates(for: climbSessionCard())
        XCTAssertEqual(kinds, [.card, .receipt])
        XCTAssertTrue(kinds.contains(.card), "Send Card is always present")
    }

    func testSparsePayloadOffersOnlySendCard() {
        let kinds = ShareTemplateModel.eligibleTemplates(for: streakCard())
        XCTAssertEqual(kinds, [.card])
        XCTAssertTrue(kinds.contains(.card), "Send Card is always present")
        XCTAssertFalse(kinds.contains(.receipt), "no session data → no Receipt thumbnail")
    }

    func testEveryCardKindOffersAtLeastSendCardAndNoUnimplementedTemplate() {
        // No card may surface a template kind that isn't in the implemented set (no dead thumbnails).
        let implemented = Set(ShareTemplateKind.allCases)
        for card in [climbSessionCard(), streakCard()] {
            let kinds = ShareTemplateModel.eligibleTemplates(for: card)
            XCTAssertTrue(kinds.contains(.card), "Send Card always offered")
            XCTAssertTrue(Set(kinds).isSubset(of: implemented), "only implemented kinds offered")
        }
    }

    // MARK: defaultVisibleMetrics

    func testSessionCardDefaultsIncludeSecondaryStats() {
        let metrics = ShareTemplateModel.defaultVisibleMetrics(for: climbSessionCard())
        XCTAssertEqual(metrics, [.headline, .subtitle, .primary, .secondary, .branding])
    }

    func testSingleStatCardHidesSecondaryByDefault() {
        let metrics = ShareTemplateModel.defaultVisibleMetrics(for: streakCard())
        XCTAssertEqual(metrics, [.headline, .subtitle, .primary, .branding])
        XCTAssertFalse(metrics.contains(.secondary))
    }

    // MARK: shareChannel derivation

    func testChannelInstagram() {
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: "com.burbn.instagram.shareextension"),
                       "export:instagram")
    }

    func testChannelMessages() {
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: "com.apple.UIKit.activity.Message"),
                       "export:imessage")
    }

    func testChannelSaveToPhotos() {
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: "com.apple.UIKit.activity.SaveToCameraRoll"),
                       "export:photos")
    }

    func testChannelUnknownActivityFallsBackToShare() {
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: "com.example.someotherapp"),
                       "export:share")
    }

    func testChannelNilOrEmptyFallsBackToShare() {
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: nil), "export:share")
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: ""), "export:share")
    }

    // MARK: shareTemplate mapping (composer pre-selection seam)

    func testShareTemplateKindMapsToPureShareTemplate() {
        XCTAssertEqual(ShareTemplateKind.card.shareTemplate, .sendCard)
        XCTAssertEqual(ShareTemplateKind.receipt.shareTemplate, .sessionReceipt)
    }
}
