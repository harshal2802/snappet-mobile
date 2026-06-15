import SwiftUI
import WidgetKit

/// The widget extension's entry point. Vends the Live Activity widgets for the WorkoutTracker
/// overall timer (live-workout-studio A2) and the Kilter climbing-session timer, plus the
/// home-screen **Today** widget (#81 Phase 2 — day streak + habits remaining + interactive
/// check-off), all reading the App-Group snapshot the app publishes.
@main
struct SnappetWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
        KilterLiveActivity()
        PomodoroLiveActivity()
        TodayWidget()
    }
}
