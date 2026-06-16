import Foundation

/// Pure, device-free model + logic for a **persisted** planned session — the keystone that decouples
/// a plan from the volatile `KilterRecommender` output. `KilterRecommender` stays a pure *generator*;
/// once the climber taps **Start**, its `Plan` is snapshotted into ordered `KilterPlanItem`s and the
/// live UI reads done-state from `KilterPlanItem.status` instead of re-deriving it from
/// `logs ∩ recommend()` every render. That single move kills the "completed send/project pick vanishes
/// on the next log" defect (the recommender used to drop now-sent UUIDs and reshuffle), and gives the
/// session a stable, re-enterable home.
///
/// No SwiftData / no UI here, so it is unit-tested in `SnappetTests` with synthetic inputs exactly like
/// `KilterRecommender` and `KilterSessionStats`. The `@Model` wrapper that persists this (`KilterPlan`)
/// lives in `KilterModels.swift`; it stores `[KilterPlanItem]` as an embedded Codable array, the same
/// shape `KilterSession.hrSeries: [HRPoint]` already uses.

/// How a planned pick has resolved as the session runs. Stored by `rawValue` on `KilterPlanItem`.
enum KilterPlanItemStatus: String, Codable, Sendable, CaseIterable {
    /// Not yet attempted — the only state a Plan-ready item can be in.
    case pending
    /// Logged as a send or flash (`KilterAscentStatus.isSend`).
    case sent
    /// Logged as an attempt or project — worked, not (yet) sent.
    case attempted
    /// The climber explicitly skipped this pick (a deliberate "not today", distinct from pending).
    case skipped

    /// Whether the pick earned a green tick / counts toward "N of M done" (engaged with, not skipped).
    var isDone: Bool { self == .sent || self == .attempted }
}

/// One ordered pick in a persisted plan, carrying its own completion state so done-ness survives any
/// recommender re-run. A plain Codable value (embedded in `KilterPlan.items`), so the progress logic
/// below is testable without SwiftData. `climbUUID` is the same key `SessionMedia.assignedClimbUUID`
/// uses, so a plan row inherits its session clips by a pure join — no foreign key from plan → media.
struct KilterPlanItem: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    /// Position in the frozen plan (0-based); the display + "next up" order.
    var order: Int
    /// `KilterRecommender.Goal.rawValue` — what this pick is *for* (warmup / send / project).
    var goalRaw: String
    var climbUUID: String
    var climbName: String
    var setter: String
    var gradeLabel: String
    var difficulty: Double
    /// `KilterPlanItemStatus.rawValue`.
    var statusRaw: String
    /// Pinned across "Shuffle" while the plan is still in **Plan ready** (survives a re-roll).
    var locked: Bool
    /// When the pick resolved (sent/attempted); `nil` while pending/skipped.
    var completedAt: Date?

    init(id: UUID = UUID(), order: Int, goal: KilterRecommender.Goal, climbUUID: String,
         climbName: String, setter: String, gradeLabel: String, difficulty: Double,
         status: KilterPlanItemStatus = .pending, locked: Bool = false, completedAt: Date? = nil) {
        self.id = id
        self.order = order
        self.goalRaw = goal.rawValue
        self.climbUUID = climbUUID
        self.climbName = climbName
        self.setter = setter
        self.gradeLabel = gradeLabel
        self.difficulty = difficulty
        self.statusRaw = status.rawValue
        self.locked = locked
        self.completedAt = completedAt
    }

    var goal: KilterRecommender.Goal { KilterRecommender.Goal(rawValue: goalRaw) ?? .send }
    var status: KilterPlanItemStatus { KilterPlanItemStatus(rawValue: statusRaw) ?? .pending }
}

/// Pure operations over a plan's `[KilterPlanItem]`. Every function is total + deterministic and never
/// touches SwiftData — the view/manager calls these and persists the returned array.
enum KilterPlanProgress {

    /// Snapshot a recommender `Plan` into ordered plan items — the freeze that happens on **Start**.
    /// Picks keep the recommender's warm-up → send → project order; each starts `pending`.
    static func items(from plan: KilterRecommender.Plan) -> [KilterPlanItem] {
        plan.picks.enumerated().map { idx, pick in
            KilterPlanItem(order: idx, goal: pick.goal, climbUUID: pick.item.uuid,
                           climbName: pick.item.name, setter: pick.item.setter,
                           gradeLabel: pick.item.gradeLabel, difficulty: pick.item.difficulty)
        }
    }

    /// Resolve a logged ascent against the plan: flip the lowest-order still-`pending` item for this
    /// climb to `sent`/`attempted`. Logging a climb that isn't a pending pick leaves the plan unchanged
    /// (an ad-hoc/off-plan climb, or one already resolved) — **except** that a later *send* of a climb
    /// already marked `attempted` upgrades it to `sent`. Pure: returns the new array; the caller saves.
    static func applyingLog(climbUUID: String, ascent: KilterAscentStatus, at date: Date,
                            to items: [KilterPlanItem]) -> [KilterPlanItem] {
        let resolved: KilterPlanItemStatus = ascent.isSend ? .sent : .attempted
        if let idx = lowestOrderIndex(of: climbUUID, status: .pending, in: items) {
            var copy = items
            copy[idx].statusRaw = resolved.rawValue
            copy[idx].completedAt = date
            return copy
        }
        // No pending pick for this climb. Upgrade an attempted one if this is the send that closes it.
        if ascent.isSend, let idx = lowestOrderIndex(of: climbUUID, status: .attempted, in: items) {
            var copy = items
            copy[idx].statusRaw = KilterPlanItemStatus.sent.rawValue
            copy[idx].completedAt = date
            return copy
        }
        return items
    }

    /// Mark a pick skipped by id (a deliberate pass; it stops being "next up" but isn't done).
    static func skipping(id: UUID, in items: [KilterPlanItem]) -> [KilterPlanItem] {
        items.map { item in
            guard item.id == id else { return item }
            var copy = item
            copy.statusRaw = KilterPlanItemStatus.skipped.rawValue
            return copy
        }
    }

    /// Done-vs-total for the progress header — `done` counts sent + attempted; skipped picks count
    /// toward neither (the summary surfaces them as "N skipped"). `total` is every pick in the plan.
    static func progress(_ items: [KilterPlanItem]) -> (done: Int, total: Int) {
        (items.lazy.filter { $0.status.isDone }.count, items.count)
    }

    /// The pick to surface as **Next up**: the lowest-order item still `pending`.
    static func nextPending(_ items: [KilterPlanItem]) -> KilterPlanItem? {
        items.filter { $0.status == .pending }.min { $0.order < $1.order }
    }

    /// The still-`pending` picks' climb UUIDs, in plan order — for the climb screen's "Next pick →"
    /// loop (kept on the session manager so the climb screen needn't re-fetch the plan each render).
    static func pendingClimbUUIDs(_ items: [KilterPlanItem]) -> [String] {
        items.filter { $0.status == .pending }.sorted { $0.order < $1.order }.map(\.climbUUID)
    }

    /// Whether every pick has resolved one way or another (sent / attempted / skipped) — the natural
    /// "you've worked the whole list" cue the plan-home uses to nudge **Finish plan**.
    static func allResolved(_ items: [KilterPlanItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.status != .pending }
    }

    private static func lowestOrderIndex(of climbUUID: String, status: KilterPlanItemStatus,
                                         in items: [KilterPlanItem]) -> Int? {
        items.indices
            .filter { items[$0].climbUUID == climbUUID && items[$0].status == status }
            .min { items[$0].order < items[$1].order }
    }
}
