import SwiftUI

/// Shared programmatic-navigation path for the App Library's `NavigationStack`.
///
/// Mini-apps are pushed into the App Library's stack and must not nest their own, so to navigate
/// they push values onto this shared path (injected via `.environment`). Using plain `Button`s that
/// `push(_:)` — rather than `NavigationLink(value:)` rows in a `List` — keeps every row a real,
/// reliably hittable control: SwiftUI exposes List `NavigationLink` rows without a button trait, so
/// UI tests can't activate them, whereas Buttons they can.
@MainActor
@Observable
final class SuiteRouter {
    var path = NavigationPath()

    func push<V: Hashable>(_ value: V) { path.append(value) }
    func popToRoot() { path = NavigationPath() }
}

/// Route value for entering a mini-app from the App Library (push by module id).
struct ModuleRoute: Hashable { let id: String }
