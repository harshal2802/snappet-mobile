import Foundation
import WidgetKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Keeps the household's off-app surfaces current (household prompt 04): the Home/Lock Screen widget,
/// the watch's chores page and the power-hour Live Activity all follow the store, and ticks made on the
/// widget or the watch come back through the App-Group outbox.
@MainActor
final class HouseholdSurfaces {
    static let shared = HouseholdSurfaces()

    /// The app's household store, if a household exists (never creates one). Set by `AppModel`.
    var store: () -> HouseholdStore? = { nil }
    let powerHour = PowerHourActivityController()
    private var publishTask: Task<Void, Never>?
    private var lastSnapshot: HouseholdWidgetSnapshot?

    /// UI-test launches run on an in-memory store; their snapshots mustn't leak into the shared App Group.
    private static let isUITest = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-uiTest") }

    // MARK: Out

    /// After any change, coalesced: one write per burst of ops (a sync can land dozens).
    func publishSoon() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    func publish(now: Date = .now) {
        guard let store = store() else { return }
        powerHour.sync(store: store, now: now)
        let snapshot = Self.snapshot(store: store, now: now)
        guard snapshot.withoutTimestamp != lastSnapshot?.withoutTimestamp, !Self.isUITest else { return }
        lastSnapshot = snapshot
        HouseholdWidgetStore.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HouseholdWidgetStore.kind)
        sendToWatch(snapshot)
    }

    static func snapshot(store: HouseholdStore, now: Date = .now, calendar: Calendar = .current) -> HouseholdWidgetSnapshot {
        let board = store.board
        let pet = HousePetState(store: store, now: now)
        let start = ChoreSchedule.weekStart(now, calendar: calendar)
        let chores = board.today(me: store.me, now: now, calendar: calendar).mine.map { row -> HouseholdWidgetSnapshot.Chore in
            var done = false, overdue = 0
            switch row.status {
            case .done(let round): done = round.members.contains(store.me)
            case .due(let d): overdue = d
            case .notDue: break
            }
            return .init(id: row.chore.id, name: row.chore.name, emoji: row.chore.emoji,
                         effort: row.chore.effort.label, done: done, overdueDays: overdue)
        }
        .sorted { ($0.done ? 1 : 0, -$0.overdueDays, $0.name) < ($1.done ? 1 : 0, -$1.overdueDays, $1.name) }
        let hour = board.powerHour(at: now).map { h in
            HouseholdWidgetSnapshot.PowerHour(start: h.start, end: h.end, done: board.powerHourProgress(h, now: now).done,
                                              target: h.target)
        }
        return HouseholdWidgetSnapshot(
            householdName: store.displayName, petName: store.petName, level: pet.level.level,
            stage: pet.level.stage.rawValue, mood: pet.mood, paused: pet.paused,
            goalDone: board.roundsByDay(weekStart: start, calendar: calendar).reduce(0, +),
            goalTarget: board.goal(now: now, calendar: calendar)?.target ?? 0,
            chores: Array(chores.prefix(8)), powerHour: hour, updatedAt: now)
    }

    private func sendToWatch(_ snapshot: HouseholdWidgetSnapshot) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? HouseholdWidgetStore.encode(snapshot) else { return }
        try? session.updateApplicationContext(HouseholdWatchMessage.snapshot(data).payload)
        #endif
    }

    // MARK: In

    /// Applies ticks from the widget and the watch. Called on foreground and when the watch sends one.
    func reconcile() {
        let pending = ChoreOutbox.pending()
        guard !pending.isEmpty, let store = store() else { return }
        ChoreOutbox.remove(ids: store.apply(pending))
    }
}

private extension HouseholdWidgetSnapshot {
    /// Equality without the timestamp, so an unchanged board doesn't rewrite the widget.
    var withoutTimestamp: HouseholdWidgetSnapshot {
        var s = self
        s.updatedAt = .distantPast
        return s
    }
}
