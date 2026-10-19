import XCTest
@testable import Snappet

/// Which set a clip filmed from an exercise's page (or left behind by a closed timed set) belongs to (prompt 191).
final class ClipSetClaimTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testTheNextSetClaimsWhatWasFilmedSinceThePreviousOne() {
        // Set 1 done at 300 s; set 2 just logged at 620 s. Clip a was filmed before set 1, b and c during set 2.
        let clips = [ClipSetClaim.Clip(id: a, offsetSec: 200), .init(id: b, offsetSec: 480), .init(id: c, offsetSec: 600)]
        XCTAssertEqual(ClipSetClaim.claims(clips, completions: [300, 620], setIndex: 1), [b, c])
    }

    func testTheFirstSetClaimsEverythingFilmedBeforeIt() {
        let clips = [ClipSetClaim.Clip(id: a, offsetSec: 10), .init(id: b, offsetSec: 90)]
        XCTAssertEqual(ClipSetClaim.claims(clips, completions: [120], setIndex: 0), [a, b])
    }

    func testAClipFilmedAfterTheSetIsLeftForTheNextOne() {
        let clips = [ClipSetClaim.Clip(id: a, offsetSec: 700)]
        XCTAssertEqual(ClipSetClaim.claims(clips, completions: [300, 620], setIndex: 1), [])
    }

    func testAClipStartedAMomentBeforeThePreviousTapStillCounts() {
        // The previous set was tapped at 300 s; this clip started at 298 s for the next set.
        let clips = [ClipSetClaim.Clip(id: a, offsetSec: 298)]
        XCTAssertEqual(ClipSetClaim.claims(clips, completions: [300, 620], setIndex: 1), [a])
    }

    func testNothingWithoutACompletionTime() {
        XCTAssertEqual(ClipSetClaim.claims([.init(id: a, offsetSec: 10)], completions: [nil], setIndex: 0), [])
        XCTAssertEqual(ClipSetClaim.claims([.init(id: a, offsetSec: 10)], completions: [], setIndex: 0), [])
    }

    func testTheCameraContextLabel() {
        XCTAssertEqual(CameraContext(title: "Blue arete", detail: "attempt 3").label, "Blue arete · attempt 3")
        XCTAssertEqual(CameraContext(title: "Bench Press").label, "Bench Press")
    }
}
