import Foundation

/// The one answer to "is this launch on the UI-test store?" (prompt 266).
///
/// UI tests pass `-uiTestFreshStore` (or a `-uiTestSeed…` argument that implies it) to get an empty,
/// in-memory SwiftData store. `SnappetApp.init` uses this to pick the in-memory store, and the root view
/// uses it to show the invisible `uiTest.freshStore` marker that the UI tests wait for before their first tap
/// (`SnappetUITests/TestStoreGuard.swift` mirrors `freshStoreArguments`; keep the two lists in step).
/// A normal launch has none of these arguments, so it gets the real store and no marker.
enum UITestStore {
    /// The accessibility identifier of the invisible marker present only on the test store.
    static let markerIdentifier = "uiTest.freshStore"

    /// Every launch argument that means "use a fresh in-memory store".
    static let freshStoreArguments: [String] = baseArguments + debugOnlyArguments

    /// Seeds that exist in DEBUG builds only (their code is not in a release build).
    private static var debugOnlyArguments: [String] {
        #if DEBUG
        return [StudioHRTimingSeed.argument]
        #else
        return []
        #endif
    }

    private static let baseArguments: [String] = [
        "-uiTestFreshStore",
        StudioDemoSeed.argument,
        RecapClipSeed.argument,
        RoutineHistorySeed.argument,
        ActivityClipsSeed.argument,
        RacketHRSeed.argument,
        RacketVideoSeed.argument,
        FestivalLineupSeed.argument,
        // The night seed layers over the lineup seed, so it implies the fresh store too.
        FestivalNightSeed.argument,
        FestivalPlanSeed.argument,
        RunningWorkoutSeed.argument,
        RunningWorkoutSeed.oldArgument,
    ]

    /// The fallback-banner test (`-uiTestCorruptStore`): an in-memory store too, flagged as a fallback.
    static let corruptStoreArgument = "-uiTestCorruptStore"

    /// Every launch argument that puts the app on an in-memory test store: the fresh-store list, the
    /// corrupt-store simulation, and the UI-test helper's restore-only launch (it shows no app at all).
    /// A launch with any of these is a TEST LAUNCH (prompt 320).
    static let testLaunchArguments: [String] =
        freshStoreArguments + [corruptStoreArgument, TestLaunchPrefs.restoreArgument]

    /// True when `arguments` ask for the in-memory test store. Pure: pass `ProcessInfo.processInfo.arguments`.
    static func isFreshStore(_ arguments: [String]) -> Bool {
        arguments.contains { freshStoreArguments.contains($0) }
    }

    /// The one gate for everything that reaches outside the in-memory store (prompt 320): the cloud backup and
    /// its restore offer, clip copies, the network watch, Health deliveries, notifications, Live Activities,
    /// Spotlight, the widgets' App Group files, and real files on disk. On 2026-11-26 a seeded device run
    /// (`-uiTestSeedStudioDevicePhotos`) uploaded the test store to the person's Google Drive because the old
    /// checks listed only four of these arguments. Pure: pass the launch arguments.
    static func isTestLaunch(_ arguments: [String]) -> Bool {
        arguments.contains { testLaunchArguments.contains($0) }
    }

    /// `isTestLaunch` for this process's own arguments (they never change while it runs).
    static let onTestLaunch: Bool = isTestLaunch(ProcessInfo.processInfo.arguments)
}
