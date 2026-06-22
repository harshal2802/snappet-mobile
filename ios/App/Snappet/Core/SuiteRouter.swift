import SwiftUI

/// The shell's top-level tabs. Lives beside `SuiteRouter` (not on `ShellTabs`) so anything that
/// routes — Home cards, and later QR deep links (#75) / App Intents (#81) — can target a tab.
enum SuiteTab: Hashable { case home, feed, apps }

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

    /// One-shot deep-link intent (#71 review fix): Home's "Resume <routine>" card sets this before
    /// `open(module:)`, and `WorkoutHomeView` consumes it in `.task` — re-opening the full-screen
    /// player via its existing `resume(_:)` path (the player is a `fullScreenCover` on the view's
    /// local state, so a pushed route alone lands on the dashboard with the player closed).
    /// Self-clearing on consume; a no-op when no active session exists.
    var pendingWorkoutResume = false

    /// One-shot QR/URL deep-link intent (#75, the `pendingWorkoutResume` pattern): the shell's
    /// `onOpenURL` sets this before `open(module: "kilter")`, and `KilterRootView` consumes it on
    /// appear/change — the shell can't push `KilterClimbRoute` itself because the climb push needs
    /// the root's `navigationDestination` + catalog lookup (installed? which angles?) to land
    /// gracefully when the climb isn't on this device. Self-clearing on consume; survives the
    /// cold-start window where the root hasn't been built yet.
    var pendingKilterClimb: KilterClimbLink?

    /// One-shot routine-import intent (workout-redesign E6, the `pendingKilterClimb` pattern): the shell's
    /// `onOpenURL` sets this from a scanned/opened `snappet://routine/v1/<blob>` before `open(module:
    /// "workout-log")`, and `WorkoutHomeView` consumes it on appear/change — the shell can't insert the
    /// routine itself because import is user-confirmed (an import-confirm preview with the "these N aren't
    /// in your library" landing) and inserts a NEW local `Routine` (new UUID, never overwrite) into the
    /// tracker's model context. Self-clearing on consume; survives the cold-start window before the root
    /// is built (`initial: true` on the consumer, the Kilter precedent).
    var pendingRoutineImport: SharedRoutine?

    /// One-shot "start a focus timer" intent (#81 Phase 2): the Today widget's Start-focus button
    /// (`snappet://pomodoro/start`) and the shell's `onOpenURL` set this before `open(module:
    /// "pomodoro")`, and `PomodoroRootView` consumes it on appear/change to call `timer.start()` —
    /// the engine is app-owned (`AppModel.pomodoro`), so the start has to happen inside the module.
    /// Self-clearing on consume; survives the cold-start window before the view is built.
    var pendingPomodoroStart = false

    /// One-shot Quick-Journal intent (#81 Phase 3): the Siri `QuickJournalIntent` (via the App-Group
    /// action inbox + `RootShell` dispatch) sets this before `open(module: "journal")`, and
    /// `JournalRootView` consumes it to open a new entry — prefilled with `text` when dictated.
    /// `nil` = nothing pending; a non-nil request with `text == nil` = a blank new entry.
    var pendingJournalCompose: JournalComposeRequest?

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
///
/// `zoomSourceID` names the `matchedTransitionSource` of the **card actually tapped** (the grid
/// card's module id, or the flagship hero's own id), so the zoom animates from the right card —
/// the hero used to borrow the grid card's source and zoomed from the wrong tile (#71 review fix).
/// `nil` (the default — programmatic entries like `open(module:)` and the Pomodoro re-entry chip)
/// means a plain push: an entry that wasn't a registered card must not claim one's source.
struct ModuleRoute: Hashable {
    let id: String
    var zoomSourceID: String? = nil
}

/// A pending Quick-Journal compose request carried by `SuiteRouter.pendingJournalCompose` (#81
/// Phase 3). `text` is the dictated/typed note when the Siri intent supplied one (nil = blank entry).
struct JournalComposeRequest: Equatable {
    var text: String?
}
