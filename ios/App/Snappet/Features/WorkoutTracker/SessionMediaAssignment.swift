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
}
