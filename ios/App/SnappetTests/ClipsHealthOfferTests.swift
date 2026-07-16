import XCTest
@testable import Snappet

/// The Clips "Connect Apple Health" offer's pure gate (highlights P5). The card closes the
/// fresh-install read-priming gap the retired Workout Reels onboarding left behind — and because
/// HealthKit read-auth status is NOT queryable, the gate is exactly these two inputs: a watch
/// import already existing (proof the grant works) and the persisted asked/dismissed flag.
final class ClipsHealthOfferTests: XCTestCase {

    func testShowsOnlyOnTheFreshInstallGap() {
        XCTAssertTrue(ClipsHealthOffer.shouldShow(hasWatchImportedSession: false, resolved: false),
                      "no watch import + never asked/dismissed → the gap is open, show the card")
    }

    func testAWatchImportProvesTheGrantAndHidesTheCard() {
        XCTAssertFalse(ClipsHealthOffer.shouldShow(hasWatchImportedSession: true, resolved: false),
                       "a watch-imported session existing means read access already works")
    }

    func testResolvedIsFinalWhetherConnectedOrDismissed() {
        // One flag covers BOTH outcomes deliberately: the system sheet's answer can't be read
        // back, so asked is as final as dismissed — the card never returns.
        XCTAssertFalse(ClipsHealthOffer.shouldShow(hasWatchImportedSession: false, resolved: true))
        XCTAssertFalse(ClipsHealthOffer.shouldShow(hasWatchImportedSession: true, resolved: true))
    }

    func testResolvedKeyIsStable() {
        // Persisted in UserDefaults and cleared by SnappetApp's fresh-store launch path —
        // renaming it would resurface the card for users who already dismissed it.
        XCTAssertEqual(ClipsHealthOffer.resolvedKey, "clips.healthOffer.resolved")
    }
}
