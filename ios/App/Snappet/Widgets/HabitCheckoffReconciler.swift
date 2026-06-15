import Foundation

/// Reconciles widget-originated habit check-offs (the App-Group outbox) into the canonical store
/// (#81 Phase 2). The PLANNING is **pure** — given the drained toggles, the (habitID, day) keys that
/// already have a `HabitCompletion`, and the set of habits that still exist — decide which
/// completions to INSERT (and when each was tapped, for the activity log) and which to DELETE. So the
/// decision is unit-tested with no SwiftData. Idempotent + order-tolerant: the LAST desired state per
/// (habitID, day) wins (a toggle-on-then-off nets to off), a desired state already matching the store
/// is a no-op (safe to re-apply after a save failure), and a toggle for a habit that no longer exists
/// is dropped (no orphan completions).
enum HabitCheckoffReconciler {
    struct CompletionKey: Hashable, Comparable {
        var habitID: UUID
        var day: Date
        static func < (lhs: CompletionKey, rhs: CompletionKey) -> Bool {
            (lhs.habitID.uuidString, lhs.day) < (rhs.habitID.uuidString, rhs.day)
        }
    }

    /// A completion to create, plus when the user actually tapped it — so the mirrored activity-log
    /// `UsageRecord` (which drives the day streak) is stamped on the right day, not at reconcile time.
    struct Insert: Equatable {
        var key: CompletionKey
        var loggedAt: Date
    }

    struct Plan: Equatable {
        var inserts: [Insert]
        var deletes: [CompletionKey]
    }

    /// `existing`: keys that already have a completion. `liveHabitIDs`: habits that still exist (an
    /// insert for any other id is dropped — the snapshot the widget tapped may be stale). `toggles`:
    /// drained outbox entries (any order). Days are normalised to start-of-day on every side.
    static func plan(toggles: [HabitToggle], existing: Set<CompletionKey>,
                     liveHabitIDs: Set<UUID>, calendar: Calendar = .current) -> Plan {
        // Fold to the last desired state per key (older requests first), tracking the most recent
        // desired-DONE request time per key for the activity-log timestamp.
        var desiredByKey: [CompletionKey: Bool] = [:]
        var doneRequestedAt: [CompletionKey: Date] = [:]
        for t in toggles.sorted(by: { $0.requestedAt < $1.requestedAt }) {
            let key = CompletionKey(habitID: t.habitID, day: calendar.startOfDay(for: t.day))
            desiredByKey[key] = t.desired
            if t.desired { doneRequestedAt[key] = t.requestedAt }
        }
        let have = Set(existing.map {
            CompletionKey(habitID: $0.habitID, day: calendar.startOfDay(for: $0.day))
        })

        var inserts: [Insert] = []
        var deletes: [CompletionKey] = []
        for (key, desired) in desiredByKey {
            let exists = have.contains(key)
            if desired && !exists {
                guard liveHabitIDs.contains(key.habitID) else { continue }   // drop orphan inserts
                inserts.append(Insert(key: key, loggedAt: doneRequestedAt[key] ?? key.day))
            } else if !desired && exists {
                deletes.append(key)
            }
        }
        inserts.sort { $0.key < $1.key }
        return Plan(inserts: inserts, deletes: deletes.sorted())
    }
}
