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

    /// True when `arguments` ask for the in-memory test store. Pure: pass `ProcessInfo.processInfo.arguments`.
    static func isFreshStore(_ arguments: [String]) -> Bool {
        arguments.contains { freshStoreArguments.contains($0) }
    }
}
