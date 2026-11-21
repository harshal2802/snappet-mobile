import XCTest
@testable import Snappet

/// `UITestStore` (prompt 266): the single decision behind the in-memory test store and the `uiTest.freshStore`
/// marker UI tests wait for. A normal launch must never count as the test store.
final class UITestStoreTests: XCTestCase {

    func testNoArgumentsIsTheRealStore() {
        XCTAssertFalse(UITestStore.isFreshStore([]))
        XCTAssertFalse(UITestStore.isFreshStore(["/var/containers/Bundle/Application/X/Snappet.app/Snappet"]))
    }

    func testFreshStoreArgument() {
        XCTAssertTrue(UITestStore.isFreshStore(["-uiTestFreshStore"]))
        XCTAssertTrue(UITestStore.isFreshStore(["Snappet", "-uiTestFakeCamera", "-uiTestFreshStore"]))
    }

    func testEverySeedImpliesTheFreshStore() {
        let seeds = ["-uiTestSeedStudioDemo", "-uiTestSeedRecapClip", "-uiTestSeedRoutineHistory",
                     "-uiTestSeedActivityClips", "-uiTestSeedRacketHR", "-uiTestSeedRacketVideos",
                     "-uiTestSeedFestivalLineup", "-uiTestSeedFestivalNight", "-uiTestSeedFestivalPlan",
                     "-uiTestSeedRunningWorkout", "-uiTestSeedRunningWorkoutOld"]
        for seed in seeds {
            XCTAssertTrue(UITestStore.isFreshStore([seed]), seed)
        }
        // The literal list matches the seed types' own constants.
        XCTAssertEqual(Set(seeds + ["-uiTestFreshStore"]), Set(UITestStore.freshStoreArguments))
    }

    func testUnrelatedUITestArgumentsAreNotTheTestStore() {
        for arg in ["-uiTestFakeCamera", "-uiTestCorruptStore", "-uiTestFestivalOnboarding",
                    "-uiTestInstallKilterCatalog", "-uiTestStubRallySignal", "-racketCameraProbe",
                    "-uiTestFreshStoreX", "uiTestFreshStore"] {
            XCTAssertFalse(UITestStore.isFreshStore([arg]), arg)
        }
    }
}
