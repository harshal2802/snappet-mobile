import SwiftUI

@main
struct SnappetApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .onboarding:
            OnboardingView()
        default:
            NavigationStack {
                WorkoutListView()
                    .navigationTitle("Snappet")
            }
        }
    }
}
