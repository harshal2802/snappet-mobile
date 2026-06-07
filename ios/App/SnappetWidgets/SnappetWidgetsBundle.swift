import SwiftUI
import WidgetKit

/// The widget extension's entry point. Vends the Live Activity widgets for the WorkoutTracker
/// overall timer (live-workout-studio A2) and the Kilter climbing-session timer. Home-screen
/// widgets can be added to this bundle later without touching the app target.
@main
struct SnappetWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
        KilterLiveActivity()
    }
}
