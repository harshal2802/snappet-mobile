import SwiftUI
import WidgetKit

/// The widget extension's entry point. Currently vends a single Live Activity widget for the
/// WorkoutTracker overall timer (live-workout-studio A2). Home-screen widgets can be added to
/// this bundle later without touching the app target.
@main
struct SnappetWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
    }
}
