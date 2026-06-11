import SwiftUI

/// The shell's top-level tabs. Lives beside `SuiteRouter` (not on `ShellTabs`) so anything that
/// routes — Home cards, and later QR deep links (#75) / App Intents (#81) — can target a tab.
enum SuiteTab: Hashable { case home, apps }

/// Shared programmatic navigation for the whole suite shell (#71): the selected top-level tab
/// plus the App Library `NavigationStack`'s path.
///
/// Owned by `RootShell` and injected shell-wide via `.environment`, so surfaces *outside* the
/// Apps tab (the Home dashboard today; a `.onOpenURL` / App-Intent entry tomorrow) can route into
/// any module. Mini-apps are pushed into the App Library's stack and must not nest their own, so
/// to navigate they push values onto this shared path. Using plain `Button`s that
/// `push(_:)` — rather than `NavigationLink(value:)` rows in a `List` — keeps every row a real,
/// reliably hittable control: SwiftUI exposes List `NavigationLink` rows without a button trait, so
/// UI tests can't activate them, whereas Buttons they can.
@MainActor
@Observable
final class SuiteRouter {
    var tab: SuiteTab
    var path = NavigationPath()

    init(initialTab: SuiteTab = .home) {
        tab = initialTab
    }

    func push<V: Hashable>(_ value: V) { path.append(value) }
    func popToRoot() { path = NavigationPath() }

    /// Deep-link entry, usable from anywhere in the shell: jump to the Apps tab and **replace**
    /// the stack with the module's root (replacing — not appending — so repeated entries can't
    /// pile a stale stack). For a screen deeper inside the module, `push` its typed route right
    /// after (e.g. `open(module: "kilter"); push(KilterPlanRoute())`).
    func open(module id: String) {
        tab = .apps
        path = NavigationPath([ModuleRoute(id: id)])
    }
}

/// Route value for entering a mini-app (push by module id) — from the App Library's cards, a Home
/// feed row / Today card, or a future external deep link.
struct ModuleRoute: Hashable { let id: String }
