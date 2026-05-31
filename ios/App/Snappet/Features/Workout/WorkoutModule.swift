import SwiftUI

/// The Workout mini-app: HR-driven auto-highlight reels. Wraps the existing
/// workout-list → reel flow and handles its OWN Health/Photos permission priming on
/// first entry (value-first, #60 §C) — permissions are scoped to this module, not the
/// whole suite, so the rest of the apps open instantly.
enum WorkoutModule {
    @MainActor
    static var module: AppModule {
        AppModule(
            id: "workout",
            title: "Workout Reels",
            subtitle: "Auto-highlight reels from your heart rate",
            systemImage: "figure.run",
            tint: .pink,
            category: .fitness
        ) { WorkoutModuleView() }
    }
}

struct WorkoutModuleView: View {
    @Environment(AppModel.self) private var model

    // No own NavigationStack — this view is pushed into the App Library's stack.
    var body: some View {
        Group {
            switch model.phase {
            case .onboarding:
                OnboardingView()
            case .loading:
                ProgressView("Loading…")
            case .error(let msg):
                ContentUnavailableView("Something went wrong",
                    systemImage: "exclamationmark.triangle", description: Text(msg))
            case .ready:
                WorkoutListView()
            }
        }
        .navigationTitle("Workout Reels")
        .task { await model.start() }
    }
}
