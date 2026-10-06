import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the household **power hour** Live Activity (household prompt 04, wireframe frame 7): started when the
/// board has a running power hour (whoever started it, once it has synced here), updated with the count on
/// every change, ended when it's over. The countdown is `Text(timerInterval:)` on `start...end`, so the OS
/// ticks it without the app. Every entry point is a no-op where ActivityKit is unavailable or Live
/// Activities are off. Rendering on the Lock Screen needs a device; a build proves the shape.
@MainActor
final class PowerHourActivityController {
    #if canImport(ActivityKit)
    private var activity: Activity<PowerHourActivityAttributes>?
    private var activityHourID: UUID?
    #endif

    func sync(store: HouseholdStore, now: Date = .now) {
        #if canImport(ActivityKit)
        guard let hour = store.board.powerHour(at: now) else { end(); return }
        let progress = store.board.powerHourProgress(hour, now: now)
        let state = PowerHourActivityAttributes.ContentState(start: hour.start, end: hour.end, done: progress.done,
                                                             target: hour.target, people: progress.members.count)
        let content = ActivityContent(state: state, staleDate: hour.end)
        if activity == nil {
            // Re-adopt one left on the Lock Screen by a previous launch.
            activity = Activity<PowerHourActivityAttributes>.activities.first
            activityHourID = activity.map { _ in hour.opID }
        }
        if let activity, activityHourID == hour.opID {
            nonisolated(unsafe) let act = activity
            Task { await act.update(content) }
            scheduleEnd(at: hour.end)
            return
        }
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: PowerHourActivityAttributes(householdName: store.displayName, petName: store.petName),
            content: content)
        activityHourID = hour.opID
        scheduleEnd(at: hour.end)
        #endif
    }

    func end() {
        #if canImport(ActivityKit)
        guard let activity else { return }
        self.activity = nil
        activityHourID = nil
        nonisolated(unsafe) let act = activity
        Task { await act.end(nil, dismissalPolicy: .default) }
        #endif
    }

    /// While the app is open past the end, take it down on time.
    private var endTask: Task<Void, Never>?
    private func scheduleEnd(at date: Date) {
        endTask?.cancel()
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow) + 1))
            guard !Task.isCancelled else { return }
            HouseholdSurfaces.shared.publish()
            if Date.now >= date { self?.end() }
        }
    }
}
