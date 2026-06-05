import XCTest
import CoreGraphics
@testable import Snappet

/// Unit tests for the **pure** PiP grid maths: collage presets tile the unit canvas, `frames(count:)`
/// hands back only as many cells as asked, and snapping pulls a frame to the nearest alignment line
/// (rule-of-thirds / centre / edges) only within the threshold.
final class StudioGridLayoutTests: XCTestCase {

    func testSideBySideCellsFillTheCanvas() {
        let cells = StudioGridLayout.Preset.sideBySide.cells
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0].center, CGPoint(x: 0.25, y: 0.5))
        XCTAssertEqual(cells[1].center, CGPoint(x: 0.75, y: 0.5))
        for c in cells { XCTAssertEqual(c.size, CGSize(width: 0.5, height: 1)) }
    }

    func testQuadHasFourEqualCells() {
        let cells = StudioGridLayout.Preset.quad.cells
        XCTAssertEqual(cells.count, 4)
        for c in cells { XCTAssertEqual(c.size, CGSize(width: 0.5, height: 0.5)) }
        XCTAssertEqual(Set(cells.map { $0.center.x }), [0.25, 0.75])
        XCTAssertEqual(Set(cells.map { $0.center.y }), [0.25, 0.75])
    }

    func testThirdsRowCentersAndWidths() {
        let cells = StudioGridLayout.Preset.thirdsRow.cells
        XCTAssertEqual(cells.count, 3)
        XCTAssertEqual(cells[0].center.x, 1.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(cells[1].center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(cells[2].center.x, 5.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(cells[0].size.width, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testFramesReturnsAtMostCount() {
        XCTAssertEqual(StudioGridLayout.frames(preset: .quad, count: 2).count, 2)
        XCTAssertEqual(StudioGridLayout.frames(preset: .quad, count: 9).count, 4)   // capped at capacity
        XCTAssertEqual(StudioGridLayout.frames(preset: .quad, count: 0).count, 0)
    }

    func testSnapPullsCenterToNearestThird() {
        let size = CGSize(width: 0.2, height: 0.2)
        let r = StudioGridLayout.snap(center: CGPoint(x: 0.34, y: 0.5), size: size, threshold: 0.03)
        XCTAssertEqual(r.center.x, 1.0 / 3.0, accuracy: 1e-9)   // snapped to the 1/3 line
        XCTAssertEqual(r.center.y, 0.5, accuracy: 1e-9)          // already on centre
        XCTAssertTrue(r.guides.contains(StudioGridLayout.Guide(axis: .vertical, position: 1.0 / 3.0)))
    }

    func testSnapLeavesFrameAloneOutsideThreshold() {
        // Centre AND both edges must clear every snap line ([0, 1/3, 0.5, 2/3, 1]) by > threshold,
        // since snap() aligns edges too — not just the centre. A 0.1-wide box at 0.42 sits in the
        // 1/3→1/2 gap with edges at 0.37 / 0.47, all ≥ 0.03 from any line.
        let r = StudioGridLayout.snap(center: CGPoint(x: 0.42, y: 0.42),
                                      size: CGSize(width: 0.1, height: 0.1), threshold: 0.02)
        XCTAssertEqual(r.center, CGPoint(x: 0.42, y: 0.42))
        XCTAssertTrue(r.guides.isEmpty)
    }

    func testSnapAlignsAnEdgeToCanvasBound() {
        // Centre 0.44 with width 0.2 → trailing edge 0.54; leading edge 0.34 snaps to the 1/3 line,
        // shifting the centre so the edge lands on 1/3.
        let r = StudioGridLayout.snap(center: CGPoint(x: 0.34 + 0.1, y: 0.5),
                                      size: CGSize(width: 0.2, height: 0.2), threshold: 0.03)
        XCTAssertEqual(r.center.x, 1.0 / 3.0 + 0.1, accuracy: 1e-9)
    }
}
