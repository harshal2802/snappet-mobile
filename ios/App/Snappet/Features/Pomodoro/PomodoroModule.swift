import SwiftUI

/// Module descriptor for the Pomodoro focus-timer mini-app. The App Library reads
/// this to render the tile and route into `PomodoroRootView`.
enum PomodoroModule {
    @MainActor static var module: AppModule {
        AppModule(id: "pomodoro", title: "Pomodoro", subtitle: "Focus timer",
                  systemImage: "timer", tint: SnappetColor.moduleAccent("pomodoro"), category: .productivity) { PomodoroRootView() }
    }
}
