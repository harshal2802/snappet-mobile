import XCTest
@testable import Snappet

/// Prompt 215: the photo-of-your-board geometry and which photo a climb shows.
final class KilterBoardPhotoTests: XCTestCase {
    private let square = [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10), CGPoint(x: 110, y: 210), CGPoint(x: 10, y: 210)]

    func testBilinearHitsCornersAndCentre() {
        XCTAssertEqual(KilterBoardPhotoMath.point(square, u: 0, v: 0), square[0])
        XCTAssertEqual(KilterBoardPhotoMath.point(square, u: 1, v: 1), square[2])
        XCTAssertEqual(KilterBoardPhotoMath.point(square, u: 0.5, v: 0.5), CGPoint(x: 60, y: 110))
    }

    func testExtendedGrowsEachSideByTheMargin() {
        let q = KilterBoardPhotoMath.extended(square, margin: 0.1)
        XCTAssertEqual(q[0].x, 0, accuracy: 1e-9); XCTAssertEqual(q[0].y, -10, accuracy: 1e-9)   // 10% of 100 × 200
        XCTAssertEqual(q[2].x, 120, accuracy: 1e-9); XCTAssertEqual(q[2].y, 230, accuracy: 1e-9)
    }

    func testPhotoRectMatchesTheExtendedQuad() {
        // The view grows the hole area by the same margin the rectifier kept, so holes stay aligned.
        let r = KilterBoardPhotoMath.photoRect(holeArea: CGRect(x: 10, y: 10, width: 100, height: 200), margin: 0.1)
        XCTAssertEqual(r, CGRect(x: 0, y: -10, width: 120, height: 240))
    }

    func testOutputSizeKeepsTheBoardAspect() {
        let tall = KilterBoardPhotoMath.outputSize(aspect: 0.75, longSide: 1600)
        XCTAssertEqual(tall, CGSize(width: 1200, height: 1600))
        let wide = KilterBoardPhotoMath.outputSize(aspect: 2, longSide: 1600)
        XCTAssertEqual(wide, CGSize(width: 1600, height: 800))
    }

    func testPickPrefersTheConnectedBoardThenNewestForTheSize() {
        let gym = UUID(), home = UUID()
        let old = KilterBoardPhotoEntry(file: "a", boardID: gym, layoutId: 1, sizeId: 7, savedAt: .init(timeIntervalSince1970: 100))
        let newer = KilterBoardPhotoEntry(file: "b", boardID: home, layoutId: 1, sizeId: 7, savedAt: .init(timeIntervalSince1970: 200))
        let otherSize = KilterBoardPhotoEntry(file: "c", boardID: gym, layoutId: 1, sizeId: 9, savedAt: .init(timeIntervalSince1970: 300))
        let all = [old, newer, otherSize]
        XCTAssertEqual(KilterBoardPhotoPick.best(all, layoutId: 1, sizeId: 7, boardID: gym), old, "your board's own photo")
        XCTAssertEqual(KilterBoardPhotoPick.best(all, layoutId: 1, sizeId: 7, boardID: nil), newer, "else newest for the size")
        XCTAssertNil(KilterBoardPhotoPick.best(all, layoutId: 2, sizeId: 7, boardID: gym), "never another layout")
    }

    func testRectifierOutputsTheBoardAspect() {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in
            UIColor.darkGray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let out = KilterBoardPhotoRectifier.rectify(img, corners: KilterBoardPhotoMath.defaultCorners, aspect: 0.75)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.size, CGSize(width: 1200, height: 1600))
    }
}
