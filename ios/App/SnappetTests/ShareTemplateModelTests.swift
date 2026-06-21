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

    /// A workout session card (multi-line) → supports Receipt.
    private func workoutSessionCard() -> FeedCard {
        let payload = WorkoutSessionPayload(
            title: "Push day", disciplineRaw: "strength", totalVolume: 4200, distanceMeters: nil,
            exerciseCount: 5, setCount: 18, durationSec: 3000)
        return FeedCard(id: "w1", contentId: "cid-w", kind: .a2Session, category: .strength,
                        salience: 0.5, anchorDate: Date(timeIntervalSince1970: 0),
                        sourceRefs: [], payload: .workoutSession(payload), shareHint: .sessionReceipt)
    }

    /// A grade-PR card → supports the Grade PR Ticket.
    private func gradePRCard() -> FeedCard {
        let payload = GradePRPayload(newGrade: "V7", newDifficulty: 21, previousGrade: "V6", climbName: "Crimp Time")
        return FeedCard(id: "g1", contentId: "cid-g", kind: .b1GradePR, category: .milestone,
                        salience: 0.9, anchorDate: Date(timeIntervalSince1970: 0),
                        sourceRefs: [], payload: .gradePR(payload), shareHint: .gradePRTicket)
    }

    /// An on-the-board card → supports the Board Polaroid (and NOT Receipt anymore — R3 nit fix).
    private func onTheBoardCard() -> FeedCard {
        let payload = OnTheBoardPayload(litCount: 9, hardestGrade: "V5", gradeSpread: "V3–V5")
        return FeedCard(id: "o1", contentId: "cid-o", kind: .a3OnTheBoard, category: .climbing,
                        salience: 0.4, anchorDate: Date(timeIntervalSince1970: 0),
                        sourceRefs: [], payload: .onTheBoard(payload), shareHint: .boardPolaroid)
    }

    /// A pyramid card → supports the Pyramid Card (and NOT Receipt anymore — R3 nit fix).
    private func pyramidCard() -> FeedCard {
        let rows = [
            PyramidRow(grade: "V6", difficulty: 18, sends: 2, flashes: 0, projects: 1, attemptsOnly: 1),
            PyramidRow(grade: "V5", difficulty: 15, sends: 6, flashes: 2, projects: 0, attemptsOnly: 0),
            PyramidRow(grade: "V4", difficulty: 12, sends: 10, flashes: 4, projects: 0, attemptsOnly: 0),
        ]
        let payload = PyramidPayload(rows: rows, totalSends: 18, maxGrade: "V6")
        return FeedCard(id: "p1", contentId: "cid-p", kind: .c1Pyramid, category: .recap,
                        salience: 0.5, anchorDate: Date(timeIntervalSince1970: 0),
                        sourceRefs: [], payload: .pyramid(payload), shareHint: .pyramidCard)
    }

    /// A pyramid-health card → supports the Pyramid Card (per-grade rows).
    private func pyramidHealthCard() -> FeedCard {
        let rows = [PyramidRow(grade: "V5", difficulty: 15, sends: 6, flashes: 2, projects: 0, attemptsOnly: 0)]
        let payload = PyramidHealthPayload(rows: rows, consolidateGrade: "V5", note: "Top-heavy — shore up V5.")
        return FeedCard(id: "ph1", contentId: "cid-ph", kind: .c2PyramidHealth, category: .recap,
                        salience: 0.5, anchorDate: Date(timeIntervalSince1970: 0),
                        sourceRefs: [], payload: .pyramidHealth(payload), shareHint: .pyramidCard)
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

    func testClimbSessionOffersCardReceiptAndBoardPolaroid() {
        // A climb session is a multi-line receipt AND a board moment (Board Polaroid).
        let kinds = ShareTemplateModel.eligibleTemplates(for: climbSessionCard())
        XCTAssertEqual(kinds, [.card, .receipt, .boardPolaroid])
        XCTAssertTrue(kinds.contains(.card), "Send Card is always present")
    }

    func testSparsePayloadOffersOnlySendCard() {
        let kinds = ShareTemplateModel.eligibleTemplates(for: streakCard())
        XCTAssertEqual(kinds, [.card])
        XCTAssertTrue(kinds.contains(.card), "Send Card is always present")
        XCTAssertFalse(kinds.contains(.receipt), "no session data → no Receipt thumbnail")
        XCTAssertFalse(kinds.contains(.gradePRTicket))
        XCTAssertFalse(kinds.contains(.boardPolaroid))
        XCTAssertFalse(kinds.contains(.pyramidCard))
    }

    func testEveryCardKindOffersAtLeastSendCardAndNoUnimplementedTemplate() {
        // No card may surface a template kind that isn't in the implemented set (no dead thumbnails).
        let implemented = Set(ShareTemplateKind.allCases)
        let cards = [climbSessionCard(), workoutSessionCard(), streakCard(),
                     gradePRCard(), onTheBoardCard(), pyramidCard(), pyramidHealthCard()]
        for card in cards {
            let kinds = ShareTemplateModel.eligibleTemplates(for: card)
            XCTAssertTrue(kinds.contains(.card), "Send Card always offered")
            XCTAssertTrue(Set(kinds).isSubset(of: implemented), "only implemented kinds offered")
        }
    }

    // MARK: R5 — new template gating (each offered only for its payload)

    func testGradePRTicketOnlyForGradePRPayload() {
        XCTAssertTrue(ShareTemplateModel.eligibleTemplates(for: gradePRCard()).contains(.gradePRTicket))
        // Not offered for any other payload.
        for card in [climbSessionCard(), workoutSessionCard(), streakCard(), onTheBoardCard(),
                     pyramidCard(), pyramidHealthCard()] {
            XCTAssertFalse(ShareTemplateModel.eligibleTemplates(for: card).contains(.gradePRTicket),
                           "Grade PR Ticket should only be offered for .gradePR")
        }
    }

    func testBoardPolaroidOnlyForClimbSessionAndOnTheBoard() {
        XCTAssertTrue(ShareTemplateModel.eligibleTemplates(for: climbSessionCard()).contains(.boardPolaroid))
        XCTAssertTrue(ShareTemplateModel.eligibleTemplates(for: onTheBoardCard()).contains(.boardPolaroid))
        // Not offered for non-board payloads.
        for card in [workoutSessionCard(), streakCard(), gradePRCard(), pyramidCard(), pyramidHealthCard()] {
            XCTAssertFalse(ShareTemplateModel.eligibleTemplates(for: card).contains(.boardPolaroid),
                           "Board Polaroid should only be offered for climb/board payloads")
        }
    }

    func testPyramidCardOnlyForPyramidPayloads() {
        XCTAssertTrue(ShareTemplateModel.eligibleTemplates(for: pyramidCard()).contains(.pyramidCard))
        XCTAssertTrue(ShareTemplateModel.eligibleTemplates(for: pyramidHealthCard()).contains(.pyramidCard))
        // Not offered for non-pyramid payloads.
        for card in [climbSessionCard(), workoutSessionCard(), streakCard(), gradePRCard(), onTheBoardCard()] {
            XCTAssertFalse(ShareTemplateModel.eligibleTemplates(for: card).contains(.pyramidCard),
                           "Pyramid Card should only be offered for .pyramid / .pyramidHealth")
        }
    }

    func testOnTheBoardGetsPolaroidNotReceipt() {
        // R3 nit fix: on-the-board now gets the bespoke Board Polaroid, NOT the generic Receipt.
        let kinds = ShareTemplateModel.eligibleTemplates(for: onTheBoardCard())
        XCTAssertFalse(kinds.contains(.receipt), "on-the-board no longer offers a Receipt (R3 nit fix)")
        XCTAssertTrue(kinds.contains(.boardPolaroid))
        XCTAssertEqual(kinds, [.card, .boardPolaroid])
    }

    func testPyramidGetsPyramidCardNotReceipt() {
        // R3 nit fix: pyramid now gets the bespoke Pyramid Card, NOT the generic Receipt.
        let kinds = ShareTemplateModel.eligibleTemplates(for: pyramidCard())
        XCTAssertFalse(kinds.contains(.receipt), "pyramid no longer offers a Receipt (R3 nit fix)")
        XCTAssertTrue(kinds.contains(.pyramidCard))
        XCTAssertEqual(kinds, [.card, .pyramidCard])
    }

    func testWorkoutSessionStillOffersReceipt() {
        // Receipt narrowed to the genuinely multi-line sessions — workout sessions keep it.
        let kinds = ShareTemplateModel.eligibleTemplates(for: workoutSessionCard())
        XCTAssertTrue(kinds.contains(.receipt), "workout sessions remain Receipt-eligible")
        XCTAssertEqual(kinds, [.card, .receipt])
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

    func testBoardAndPyramidCardsDefaultToStackedSecondary() {
        // The bespoke multi-line cards keep the full stacked metric set by default (R5).
        let full: Set<ShareMetric> = [.headline, .subtitle, .primary, .secondary, .branding]
        XCTAssertEqual(ShareTemplateModel.defaultVisibleMetrics(for: onTheBoardCard()), full)
        XCTAssertEqual(ShareTemplateModel.defaultVisibleMetrics(for: pyramidCard()), full)
        XCTAssertEqual(ShareTemplateModel.defaultVisibleMetrics(for: pyramidHealthCard()), full)
        XCTAssertEqual(ShareTemplateModel.defaultVisibleMetrics(for: workoutSessionCard()), full)
    }

    func testGradePRCardHidesSecondaryByDefault() {
        // A grade PR is a single-hero milestone — secondary is off by default.
        let metrics = ShareTemplateModel.defaultVisibleMetrics(for: gradePRCard())
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

    func testChannelIsCaseInsensitive() {
        // Activity-type matching is lowercased, so case must not matter.
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: "COM.BURBN.INSTAGRAM.ShareExtension"),
                       "export:instagram")
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: "COM.APPLE.UIKIT.ACTIVITY.MESSAGE"),
                       "export:imessage")
    }

    func testChannelCameraAndPhotoVariantsMapToPhotos() {
        // The Photos branch also catches generic "camera" / "photo" activity strings.
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: "com.apple.UIKit.activity.SaveToCameraRoll"),
                       "export:photos")
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: "com.example.CameraExtension"),
                       "export:photos")
        XCTAssertEqual(ShareTemplateModel.shareChannel(forActivityType: "com.example.PhotoSaver"),
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
        XCTAssertEqual(ShareTemplateKind.gradePRTicket.shareTemplate, .gradePRTicket)
        XCTAssertEqual(ShareTemplateKind.boardPolaroid.shareTemplate, .boardPolaroid)
        XCTAssertEqual(ShareTemplateKind.pyramidCard.shareTemplate, .pyramidCard)
    }

    // MARK: ShareMetric.chipLabel (R5 carried — the pure model is fully covered)

    func testShareMetricChipLabelIsExpectedNonEmptyLabel() {
        let expected: [ShareMetric: String] = [
            .headline:  "Hero",
            .subtitle:  "Kicker",
            .primary:   "Stat",
            .secondary: "More",
            .branding:  "Logo",
        ]
        for metric in ShareMetric.allCases {
            let label = metric.chipLabel
            XCTAssertFalse(label.isEmpty, "chipLabel must be non-empty for \(metric)")
            XCTAssertEqual(label, expected[metric], "unexpected chipLabel for \(metric)")
        }
        // Guard: every case is exercised (no metric silently added without a label assertion).
        XCTAssertEqual(Set(expected.keys), Set(ShareMetric.allCases))
    }

    func testShareHintPreSelectsItsTemplateWhenEligible() {
        // The card's `shareHint` maps to an eligible kind so the composer can pre-select it (R5 seam).
        for card in [gradePRCard(), onTheBoardCard(), pyramidCard()] {
            let eligible = ShareTemplateModel.eligibleTemplates(for: card)
            let hinted = eligible.first { $0.shareTemplate == card.shareHint }
            XCTAssertNotNil(hinted, "the shareHint template should be eligible for \(card.id)")
        }
    }
}
