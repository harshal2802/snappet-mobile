import Foundation

/// Pure, device-free formatting + validation for a logged `SetLog` across `SetKind`s — so the freeform
/// player, summaries, and history render any kind from **one** place and it's unit-tested without a view
/// or a device (the repo's pure-logic-at-a-thin-edge rule). No SwiftData, no SwiftUI. (dynamic-sessions D4)
enum SetMeasure {

    /// A one-line summary of a logged set, e.g. "8 × 60 kg", "0:45", "V4 · Flash · 3 tries".
    static func summary(_ set: SetLog, kind: SetKind, unit: WeightUnit) -> String {
        switch kind {
        case .repsWeight:
            let reps = set.actualReps.map { "\($0)" }
            let weight = set.actualWeight.map { "\(formatWeight($0)) \((set.weightUnit ?? unit).display)" }
            switch (reps, weight) {
            case let (r?, w?): return "\(r) × \(w)"
            case let (r?, nil): return "\(r) reps"
            case let (nil, w?): return w
            default: return "—"
            }

        case .duration:
            guard let secs = set.durationSec, secs > 0 else { return "—" }
            return formatDuration(secs)

        case .climbAttempt:
            var parts: [String] = []
            if let grade = set.climbGradeLabel, !grade.isEmpty { parts.append(grade) }
            if let status = set.climbStatusRaw.flatMap(KilterAscentStatus.init(rawValue:)) {
                parts.append(status.label)
            }
            let tries = set.climbAttempts ?? 1
            if tries > 1 { parts.append("\(tries) tries") }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        }
    }

    /// Whether a (filled-in) set is worth logging for its kind — guards the "Add" action so an empty
    /// entry isn't saved. A set is always "loggable" once it carries its kind's minimum input.
    static func hasInput(_ set: SetLog, kind: SetKind) -> Bool {
        switch kind {
        case .repsWeight: return set.actualReps != nil || set.actualWeight != nil
        case .duration:   return (set.durationSec ?? 0) > 0
        case .climbAttempt:
            let hasGrade = !(set.climbGradeLabel ?? "").isEmpty
            return hasGrade || set.climbStatusRaw != nil
        }
    }

    /// Whether the climb attempt counts as a send (flash or sent) — for a session's send tally.
    static func isSend(_ set: SetLog) -> Bool {
        set.climbStatusRaw.flatMap(KilterAscentStatus.init(rawValue:))?.isSend ?? false
    }

    // MARK: - Formatting

    /// Weight without a trailing ".0" (60.0 → "60", 62.5 → "62.5").
    static func formatWeight(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Seconds → "M:SS" (or "H:MM:SS" past an hour).
    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
