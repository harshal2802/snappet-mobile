import XCTest
@testable import Snappet

/// Prompt 147 (3D buddy prototype): the pure stage/Form → look mapping.
final class BuddyLookTests: XCTestCase {

    func testSizeGrowsWithStageOnly() {
        let sizes = BuddyStage.allCases.map { BuddyLook(stage: $0, form: 0.5).bodyScale }
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(Set(sizes).count, sizes.count)
        // Form never shrinks the buddy — losing consistency changes mood, not progress.
        XCTAssertEqual(BuddyLook(stage: .adult, form: 0).bodyScale, BuddyLook(stage: .adult, form: 1).bodyScale)
    }

    func testFeaturesUnlockByStage() {
        XCTAssertEqual(BuddyStage.allCases.map { BuddyLook(stage: $0, form: 1).antennae }, [0, 0, 1, 2, 2])
        XCTAssertTrue(BuddyLook(stage: .hatchling, form: 1).hasShellCup)
        XCTAssertFalse(BuddyLook(stage: .sprout, form: 1).hasArms)
        XCTAssertTrue(BuddyLook(stage: .adult, form: 1).hasArms)
        XCTAssertTrue(BuddyLook(stage: .legend, form: 1).hasCrown)
    }

    func testFormDrivesMood() {
        let high = BuddyLook(stage: .adult, form: 0.9), low = BuddyLook(stage: .adult, form: 0.1)
        XCTAssertGreaterThan(high.eyeOpen, low.eyeOpen)
        XCTAssertGreaterThan(high.bobHz, low.bobHz)
        XCTAssertGreaterThan(high.saturation, low.saturation)
        XCTAssertGreaterThan(low.droop, high.droop)
        XCTAssertEqual(high.mood, "Fired up")
        XCTAssertEqual(BuddyLook(stage: .adult, form: 0.5).mood, "Steady")
        XCTAssertEqual(BuddyLook(stage: .adult, form: 0.3).mood, "Tired")
        XCTAssertEqual(low.mood, "Sleepy")
    }

    func testSparksNeedStageAndForm() {
        XCTAssertEqual(BuddyLook(stage: .legend, form: 1).sparks, 3)
        XCTAssertEqual(BuddyLook(stage: .legend, form: 0.1).sparks, 1)
        XCTAssertEqual(BuddyLook(stage: .adult, form: 0.8).sparks, 1)
        XCTAssertEqual(BuddyLook(stage: .adult, form: 0.5).sparks, 0)
        XCTAssertEqual(BuddyLook(stage: .sprout, form: 1).sparks, 0)
    }

    func testPauseSleepsWithoutGlow() {
        let p = BuddyLook(stage: .legend, form: 1, paused: true)
        XCTAssertLessThan(p.eyeOpen, 0.1)
        XCTAssertEqual(p.glow, 0)
        XCTAssertEqual(p.sparks, 0)
        XCTAssertEqual(p.mood, "Resting — Form is held")
        XCTAssertEqual(p.bodyScale, BuddyLook(stage: .legend, form: 1).bodyScale)
    }

    func testEggOnlyPeeksAndFormIsClamped() {
        XCTAssertLessThanOrEqual(BuddyLook(stage: .egg, form: 1).eyeOpen, 0.6)
        XCTAssertEqual(BuddyLook(stage: .sprout, form: 3).form, 1)
        XCTAssertEqual(BuddyLook(stage: .sprout, form: -1).form, 0)
    }
}
