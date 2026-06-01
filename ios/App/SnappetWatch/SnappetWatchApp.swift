import SwiftUI

/// The Snappet watchOS companion. Its single job (A1) is to run an
/// `HKWorkoutSession` + `HKLiveWorkoutBuilder` on command from the phone and relay
/// live heart rate / energy back over `WCSession`. It is intentionally minimal —
/// the rich UX lives on the phone (RESEARCH.md §3.1).
@main
struct SnappetWatchApp: App {
    @State private var manager = WorkoutWatchManager()

    var body: some Scene {
        WindowGroup {
            WatchWorkoutView()
                .environment(manager)
        }
    }
}
