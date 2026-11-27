import XCTest
@testable import Snappet

/// `UITestStore` (prompt 266): the single decision behind the in-memory test store and the `uiTest.freshStore`
/// marker UI tests wait for. A normal launch must never count as the test store.
final class UITestStoreTests: XCTestCase {

    func testNoArgumentsIsTheRealStore() {
        XCTAssertFalse(UITestStore.isFreshStore([]))
        XCTAssertFalse(UITestStore.isFreshStore(["/var/containers/Bundle/Application/X/Snappet.app/Snappet"]))
        XCTAssertFalse(UITestStore.isTestLaunch([]))
        XCTAssertFalse(UITestStore.isTestLaunch(["/var/containers/Bundle/Application/X/Snappet.app/Snappet"]))
    }

    func testFreshStoreArgument() {
        XCTAssertTrue(UITestStore.isFreshStore(["-uiTestFreshStore"]))
        XCTAssertTrue(UITestStore.isFreshStore(["Snappet", "-uiTestFakeCamera", "-uiTestFreshStore"]))
    }

    func testEverySeedImpliesTheFreshStore() {
        let seeds = ["-uiTestSeedStudioDemo", "-uiTestSeedRecapClip", "-uiTestSeedRoutineHistory",
                     "-uiTestSeedActivityClips", "-uiTestSeedRacketHR", "-uiTestSeedRacketVideos",
                     "-uiTestSeedFestivalLineup", "-uiTestSeedFestivalNight", "-uiTestSeedFestivalPlan",
                     "-uiTestSeedRunningWorkout", "-uiTestSeedRunningWorkoutOld",
                     "-uiTestSeedStudioHRTiming"]
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

    // MARK: - The one test-launch gate (prompt 320)

    /// Every argument that puts the app on an in-memory store is a test launch — the gate for the cloud backup,
    /// clip copies, notifications, widgets and the rest. On 2026-11-26 a seed missing from the old four-argument
    /// list backed the test store up to the person's Google Drive.
    func testEveryTestStoreArgumentIsATestLaunch() {
        for arg in UITestStore.freshStoreArguments + ["-uiTestCorruptStore"] {
            XCTAssertTrue(UITestStore.isTestLaunch([arg]), arg)
            XCTAssertTrue(UITestStore.isTestLaunch(["Snappet", "-uiTestFakeCamera", arg]), arg)
        }
        XCTAssertEqual(Set(UITestStore.testLaunchArguments),
                       Set(UITestStore.freshStoreArguments + [UITestStore.corruptStoreArgument]))
    }

    /// Arguments that only tune a screen leave the store, and so the gate, alone.
    func testArgumentsThatDoNotChooseAStoreAreNotATestLaunch() {
        for arg in ["-uiTestFakeCamera", "-uiTestCloudVault", "-uiTestFestivalOnboarding", "-uiTestInstallKilterCatalog",
                    "-uiTestGoogleSignedIn", "-vaultHoldCopies", "-uiTestFreshStoreX", "uiTestFreshStore", "clips"] {
            XCTAssertFalse(UITestStore.isTestLaunch([arg]), arg)
        }
    }

    /// The UI-test target can't import the app, so `TestStoreGuard` keeps its own copy of the list. Read that
    /// source file and require the two lists to be equal (prompt 320).
    func testTheUITestGuardMirrorsTheList() throws {
        let source = try String(contentsOf: Self.appRoot.appendingPathComponent("SnappetUITests/TestStoreGuard.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static let freshStoreArguments: Set<String> = ["))
        let end = try XCTUnwrap(source.range(of: "]", range: start.upperBound..<source.endIndex))
        let mirrored = Self.uiTestArguments(in: String(source[start.upperBound..<end.lowerBound]))
        XCTAssertEqual(mirrored, Set(UITestStore.freshStoreArguments))
        XCTAssertTrue(source.contains("static let corruptStoreArgument = \"\(UITestStore.corruptStoreArgument)\""))
        XCTAssertTrue(source.contains("static let markerIdentifier = \"\(UITestStore.markerIdentifier)\""))
    }

    /// Every `-uiTestSeed…` the app knows is in the list — a new seed that forgets to join it would run the cloud
    /// backup, copies and the rest against its test store (the 2026-11-26 device run).
    func testEverySeedInTheAppSourceIsInTheList() throws {
        let appSources = Self.appRoot.appendingPathComponent("Snappet")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
        var seeds = Set<String>()
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            seeds.formUnion(Self.uiTestArguments(in: text).filter { $0.hasPrefix("-uiTestSeed") })
        }
        XCTAssertFalse(seeds.isEmpty)
        XCTAssertEqual(seeds.subtracting(UITestStore.freshStoreArguments), [],
                       "seed arguments that do not put the app on the test store")
    }

    // MARK: - Helpers

    /// `ios/App`, from this file's path (`ios/App/SnappetTests/UITestStoreTests.swift`).
    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every quoted `"-uiTest…"` literal in `text`.
    private static func uiTestArguments(in text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: "\"(-uiTest[A-Za-z]+)\"")
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }
}
