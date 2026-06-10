import SwiftUI
import SwiftData

@main
struct SnappetApp: App {
    let container: ModelContainer
    @State private var appModel: AppModel

    init() {
        // The shared on-device store for the whole suite (Snappet Core). A corrupt
        // store should never brick the app → fall back to in-memory.
        let schema = Schema(SnappetSchema.models)
        // UI tests pass `-uiTestFreshStore` to get an isolated, empty in-memory store so
        // each run is deterministic (the on-disk store persists between launches on the sim,
        // which would otherwise pollute data-creating tests). Only affects SwiftData;
        // `@AppStorage` (UserDefaults) is untouched.
        //
        // `-uiTestSeedStudioDemo` is a sibling test-only arg (Live Workout Studio walkthrough):
        // it IMPLIES a fresh in-memory store for determinism, and then seeds a completed
        // WorkoutSession with a synthetic HR series so the B2 enriched summary renders on the
        // simulator. Both args are test-only; a normal/production launch hits neither branch.
        let args = ProcessInfo.processInfo.arguments
        let seedStudioDemo = args.contains(StudioDemoSeed.argument)
        let freshStore = args.contains("-uiTestFreshStore") || seedStudioDemo
        // Kilter catalog (issue #42): the app ships no catalog. Under the catalog test args this clears
        // any leftover on-device catalog and — only with `-uiTestInstallKilterCatalog` — installs a
        // synthetic fixture so the Kilter UI tests have data to browse. No-ops on a normal launch.
        KilterCatalogFixture.installForUITestingIfRequested()
        // Resolve the demo "Saved" band BEFORE building AppModel — its LiveMetricsCoordinator
        // constructs the BLE source eagerly and reads BandMemory (UserDefaults) at that moment,
        // so the picker only shows the "Saved" flow if the band is persisted first. A normal
        // launch takes the else branch, which clears any leftover demo band (a no-op for real
        // users, whose band id differs from the fixed demo id).
        if seedStudioDemo {
            StudioDemoSeed.seedRememberedBandIfRequested()
        } else {
            // Undo any leftover demo band so a normal launch (and the shared unit-test host on the
            // simulator) starts clean — see clearRememberedBandSeedIfStale.
            StudioDemoSeed.clearRememberedBandSeedIfStale()
        }
        // Capture whether the on-disk store failed to open so the UI can surface a
        // persistent banner (issue #68). `-uiTestCorruptStore` simulates the condition
        // without requiring an actually corrupted store on the simulator.
        let simulateCorrupt = args.contains("-uiTestCorruptStore")
        var storeCorrupted = false
        let theAppModel = AppModel()
        if freshStore {
            container = try! ModelContainer(
                for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } else if !simulateCorrupt, let c = try? ModelContainer(for: schema) {
            container = c
        } else {
            storeCorrupted = !freshStore // true only on a real failure or the test arg
            container = try! ModelContainer(
                for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        theAppModel.storeCorrupted = storeCorrupted
        _appModel = State(wrappedValue: theAppModel)
        // Strictly guarded inside `seedIfRequested` (no-ops without the arg) — ZERO production
        // impact. Seeds into the fresh in-memory store before any UI appears.
        if seedStudioDemo {
            StudioDemoSeed.seedIfRequested(into: container.mainContext)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootShell()
                .environment(appModel)
                .tint(SnappetColor.brand)
        }
        .modelContainer(container)
    }
}
