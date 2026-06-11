import SwiftUI
import SwiftData

@main
struct SnappetApp: App {
    let container: ModelContainer
    @State private var appModel: AppModel
    /// Whether the persistent store opened, or the in-memory fallback fired (issue #68) —
    /// `StoreHealthBanner` makes the fallback visible instead of a silent blank app.
    @State private var storeHealth: StoreHealth

    init() {
        // The shared on-device store for the whole suite (Snappet Core). A corrupt
        // store should never brick the app → fall back to in-memory, but the fallback
        // is RECORDED in StoreHealth and surfaced by StoreHealthBanner (issue #68).
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
        if freshStore {
            // @AppStorage lives in UserDefaults, which the in-memory store swap doesn't
            // touch — clear the remembered "me" so expense tests are deterministic
            // (the KilterCatalogFixture precedent for its kilter.* keys).
            UserDefaults.standard.removeObject(forKey: "expense.myName")
        }
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
        _appModel = State(wrappedValue: AppModel())
        // `-uiTestCorruptStore` simulates an unopenable on-disk store (the `try?` else
        // branch below can't be forced from a test) so the fallback banner is testable.
        // Test-only, like the args above; a normal launch never hits it.
        let corruptStore = args.contains("-uiTestCorruptStore")
        func inMemory() -> ModelContainer {
            try! ModelContainer(
                for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        var health = StoreHealth.Mode.ok
        if freshStore {
            container = inMemory()   // requested, not a fallback — stays healthy
        } else if corruptStore {
            container = inMemory()
            health = .fallbackInMemory
        } else if let c = try? ModelContainer(for: schema) {
            container = c
        } else {
            // The previously-silent branch: an empty in-memory store, now flagged so the
            // user is told their changes won't persist (issue #68).
            container = inMemory()
            health = .fallbackInMemory
        }
        _storeHealth = State(wrappedValue: StoreHealth(mode: health))
        // Strictly guarded inside `seedIfRequested` (no-ops without the arg) — ZERO production
        // impact. Seeds into the fresh in-memory store before any UI appears.
        if seedStudioDemo {
            StudioDemoSeed.seedIfRequested(into: container.mainContext)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootShell()
                // Mounted here (not in RootShell) so the corrupt-store warning rides above
                // whatever the shell shows; renders nothing while the store is healthy.
                .safeAreaInset(edge: .top, spacing: 0) {
                    StoreHealthBanner(health: storeHealth)
                }
                .environment(appModel)
                .tint(SnappetColor.brand)
        }
        .modelContainer(container)
    }
}
