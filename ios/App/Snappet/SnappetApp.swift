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
        // UI tests pass `-uiTestFreshStore` to get an isolated, empty in-memory store so
        // each run is deterministic (the on-disk store persists between launches on the sim,
        // which would otherwise pollute data-creating tests). Only affects SwiftData;
        // `@AppStorage` (UserDefaults) is untouched.
        let freshStore = ProcessInfo.processInfo.arguments.contains("-uiTestFreshStore")
        if freshStore {
            container = try! ModelContainer(
                for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } else if let c = try? ModelContainer(for: schema) {
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
