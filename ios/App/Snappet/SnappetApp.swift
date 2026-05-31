import SwiftUI
import SwiftData

@main
struct SnappetApp: App {
    let container: ModelContainer
    @State private var appModel = AppModel()

    init() {
        // The shared on-device store for the whole suite (Snappet Core). A corrupt
        // store should never brick the app → fall back to in-memory.
        let schema = Schema(SnappetSchema.models)
        if let c = try? ModelContainer(for: schema) {
            container = c
        } else {
            container = try! ModelContainer(
                for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootShell()
                .environment(appModel)
        }
        .modelContainer(container)
    }
}
