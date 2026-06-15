import Foundation

/// Reconciles widget-originated habit check-offs (the App-Group outbox) into the canonical store
/// (#81 Phase 2). The PLANNING is **pure** — given the drained toggles and the (habitID, day) keys
/// that already have a `HabitCompletion`, decide which completions to INSERT and which to DELETE — so
/// it's unit-tested with no SwiftData. Idempotent + order-tolerant: the LAST desired state per
/// (habitID, day) wins (a toggle-on-then-off nets to off), and a desired state already matching the
/// store is a no-op (so re-applying after a save failure is safe).
enum HabitCheckoffReconciler {
    struct CompletionKey: Hashable, Comparable {
        var habitID: UUID
        var day: Date
        static func < (lhs: CompletionKey, rhs: CompletionKey) -> Bool {
            (lhs.habitID.uuidString, lhs.day) < (rhs.habitID.uuidString, rhs.day)
        }
    }

    struct Plan: Equatable {
        var inserts: [CompletionKey]   // (habitID, day) needing a new HabitCompletion
        var deletes: [CompletionKey]   // existing completions to remove
    }

    /// `existing`: keys that already have a completion. `toggles`: drained outbox entries (any order).
    /// Days are normalised to start-of-day on both sides so comparisons are exact.
    static func plan(toggles: [HabitToggle], existing: Set<CompletionKey>,
                     calendar: Calendar = .current) -> Plan {
        // Fold to the last desired state per key (older requests first).
        var desiredByKey: [CompletionKey: Bool] = [:]
        for t in toggles.sorted(by: { $0.requestedAt < $1.requestedAt }) {
            desiredByKey[CompletionKey(habitID: t.habitID, day: calendar.startOfDay(for: t.day))] = t.desired
        }
        let have = Set(existing.map {
            CompletionKey(habitID: $0.habitID, day: calendar.startOfDay(for: $0.day))
        })

        var inserts: [CompletionKey] = []
        var deletes: [CompletionKey] = []
        for (key, desired) in desiredByKey {
            let exists = have.contains(key)
            if desired && !exists { inserts.append(key) }
            else if !desired && exists { deletes.append(key) }
        }
        return Plan(inserts: inserts.sorted(), deletes: deletes.sorted())
    }
}
