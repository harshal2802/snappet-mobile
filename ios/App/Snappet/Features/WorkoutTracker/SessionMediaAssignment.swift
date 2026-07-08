import Foundation

/// **Pure** logic (Foundation only — no SwiftData / Photos / AVFoundation) that maps each tagged
/// clip to the set it was filmed during, from the session's set-completion timeline. Kept at a
/// testable edge — like `SessionHighlightInput` / `ClipEditGeometry` — so it runs in `SnappetTests`
/// with no device (the live PHAsset discovery that *feeds* it is the device-only part).
///
/// Capture is library-based (auto-discover + picker), so the set is **inferred** from capture time:
/// a clip belongs to the set whose work interval contains its `offsetSec`. We model each completed
/// set as owning the interval `(previousCompletion, thisCompletion]` — i.e. the work plus the
/// lead-in since the last set finished — so a clip filmed *during* a set, or during the rest right
/// after it, attaches to that set (the rest-period rule, `DESIGN-full-studio.md` §1.2). A clip
/// after the last completed set (a cool-down / victory shot) gets **no** assignment → General.
enum SessionMediaAssignment {

    /// One completed set on the session timeline: which exercise/set it is and when it finished
    /// (seconds from `session.startedAt`, the same axis as `SessionMedia.offsetSec` / `HRPoint.t`).
    struct SetCompletion: Equatable, Sendable {
        let exerciseID: UUID
        let setIndex: Int
        let completionOffset: Double
    }

    /// A clip to place: its id and capture offset (seconds from `session.startedAt`).
    struct ClipInput: Equatable, Sendable {
        let id: UUID
        let offsetSec: Double
    }

    /// The resolved target set for a clip.
    struct SetRef: Equatable, Sendable {
        let exerciseID: UUID
        let setIndex: Int
    }

    /// Flatten a session's exercises into the completed-set timeline (skips sets with no
    /// `completedAt`). Order is by completion time so the interval ownership in `assign` is correct.
    static func completions(from exercises: [SessionExercise], startedAt: Date) -> [SetCompletion] {
        var out: [SetCompletion] = []
        for ex in exercises {
            for (i, set) in ex.sets.enumerated() {
                guard let completedAt = set.completedAt else { continue }
                out.append(SetCompletion(
                    exerciseID: ex.id, setIndex: i,
                    completionOffset: completedAt.timeIntervalSince(startedAt)))
            }
        }
        return out.sorted { $0.completionOffset < $1.completionOffset }
    }

    /// Assign each clip to the set being performed at its capture time. A clip maps to the
    /// **earliest** set whose `completionOffset >= offsetSec` (the set it was filmed during / just
    /// before finishing). Clips after every completion are omitted from the result → General.
    /// Pure and order-independent in the clips; `completions` is sorted defensively.
    static func assign(clips: [ClipInput], completions: [SetCompletion]) -> [UUID: SetRef] {
        guard !completions.isEmpty else { return [:] }
        let sorted = completions.sorted { $0.completionOffset < $1.completionOffset }
        var result: [UUID: SetRef] = [:]
        for clip in clips {
            if let match = sorted.first(where: { $0.completionOffset >= clip.offsetSec }) {
                result[clip.id] = SetRef(exerciseID: match.exerciseID, setIndex: match.setIndex)
            }
            // else: captured after the last logged set → leave unassigned (General).
        }
        return result
    }

    /// Where a media row pinned to set `index` points after deleting the sets at `removed`
    /// (0-based offsets into the same `sets` array): `nil` when the pinned set itself was deleted
    /// (the row falls back to the exercise as a whole), otherwise the index shifted down past the
    /// deletions so it keeps naming the same surviving set. The player applies this to the
    /// session's `SessionMedia` rows in the same mutation as the deletion.
    static func reindexAfterDeletion(_ index: Int, removing removed: IndexSet) -> Int? {
        guard !removed.contains(index) else { return nil }
        return index - removed.count(in: 0..<index)
    }
}

/// One destination a clip can be **moved to** within a climb — i.e. one of the climb's attempts (prompt
/// 11). The live `SetMediaStrip` deep-tap menu's "Move to attempt…" submenu lists these; selecting one
/// reassigns the clip to that `(exerciseID, setIndex)` and pins it `.manual` (sticky vs auto-reconcile).
/// Pure value (Foundation-only) so the target list is unit-tested without a device.
struct ClipMoveTarget: Identifiable, Equatable, Sendable {
    /// Stable id (`"<exerciseID>-<setIndex>"`) — drives the `ForEach` and the per-item a11y suffix.
    let id: String
    /// The menu label, e.g. "Attempt 3" (1-based, matching the attempt rows shown on the card).
    let title: String
    /// The owning climb's `SessionExercise.id`.
    let exerciseID: UUID
    /// The 0-based index into the climb's `sets` (the attempt) this target reassigns to.
    let setIndex: Int
}

/// The clip move-targets for ONE entity = its logged efforts, in order (prompt 11; generalized in
/// Workout-Type Parity). An entity's `sets` ARE its efforts, so each is a reassignment destination titled
/// by the discipline's noun — "Attempt N" (climb), "Leg N" (run), or "Set N" (strength/timed/dance/other),
/// 1-based. Pure (Foundation-only) → unit-tested. An effort-less entity yields no targets (the strip only
/// renders once a clip exists, which means ≥1 effort was logged, so this is a defensive empty).
func clipMoveTargets(for ex: SessionExercise) -> [ClipMoveTarget] {
    let noun: String
    switch ex.discipline {
    case .climb: noun = "Attempt"
    case .run:   noun = "Leg"
    default:     noun = "Set"
    }
    return ex.sets.indices.map { i in
        ClipMoveTarget(id: "\(ex.id)-\(i)", title: "\(noun) \(i + 1)",
                       exerciseID: ex.id, setIndex: i)
    }
}
