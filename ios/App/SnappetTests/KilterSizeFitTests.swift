import XCTest
@testable import Snappet

/// The board-size fit rule (device feedback 2026-10-03). Real numbers from the Kilter catalog: "cam pussie"
/// (Original layout) spans x 0…120, y 76…152; its finish is hole (0,152), wired only on the 16 x 12.
final class KilterSizeFitTests: XCTestCase {
    private let twelveByTwelve = KilterSizeBox(left: 0, right: 144, bottom: 0, top: 156)    // size 10
    private let sixteenByTwelve = KilterSizeBox(left: -24, right: 168, bottom: 0, top: 156)  // size 28

    func testCamPussieDoesNotFitATwelveByTwelve() {
        XCTAssertFalse(twelveByTwelve.fits(left: 0, right: 120, bottom: 76, top: 152),
                       "its box touches the 12 x 12's left edge — that column only exists on wider boards")
        XCTAssertTrue(sixteenByTwelve.fits(left: 0, right: 120, bottom: 76, top: 152))
    }

    func testFitIsStrictOnEverySide() {
        let box = KilterSizeBox(left: 0, right: 100, bottom: 0, top: 100)
        XCTAssertTrue(box.fits(left: 4, right: 96, bottom: 4, top: 96))
        XCTAssertFalse(box.fits(left: 0, right: 96, bottom: 4, top: 96), "left")
        XCTAssertFalse(box.fits(left: 4, right: 100, bottom: 4, top: 96), "right")
        XCTAssertFalse(box.fits(left: 4, right: 96, bottom: 0, top: 96), "bottom")
        XCTAssertFalse(box.fits(left: 4, right: 96, bottom: 4, top: 100), "top")
    }

    func testSQLMatchesTheSwiftRule() {
        XCTAssertEqual(KilterSizeBox.fitSQL,
                       "c.edge_left > ? AND c.edge_right < ? AND c.edge_bottom > ? AND c.edge_top < ?")
        XCTAssertEqual(twelveByTwelve.params, [0, 144, 0, 156], "bound in left, right, bottom, top order")
    }
}
