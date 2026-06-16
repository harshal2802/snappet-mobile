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
            // A climb attempt MAY have been timed (workout-with-timer PR 4): when it carries a captured
            // duration, append it ("V4 · Sent · 3 tries · 0:42") reusing the one duration funnel. Reuses
            // `durationSec` (no model change) — it was unused for `.climbAttempt` until now.
            if let secs = set.durationSec, secs > 0 { parts.append(formatDuration(secs)) }
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

    /// A field-copy of `set` for the freeform player's one-tap "Repeat set": every kind-specific field
    /// (reps/weight/unit · durationSec · climb grade/status/attempts) carries over verbatim — the
    /// field-copy is the whole point — so tapping logs a quick loop of identical sets without reopening
    /// the sheet. The completion stamp is **cleared** (`completedAt = nil`) because `appendLog` owns the
    /// real stamp: it re-stamps `completedAt = .now` on every append, so any value set here would be
    /// overwritten. Pure and `SetLog`-shaped (no view/SwiftData), so it's unit-tested without a device
    /// and stays the one definition of "duplicate a set". (workout-with-timer PR 3)
    static func duplicate(_ set: SetLog) -> SetLog {
        var copy = set
        copy.completedAt = nil
        return copy
    }

    /// A user-typed climb name → the `displayName` to store, whitespace-trimmed. An empty/whitespace-only
    /// entry falls back to the generic `"Climbing"` so a named free-flow climb session never logs under a
    /// blank header. Pure (no view), so the trim/fallback rule is the one tested definition the freeform
    /// player's "Name this climb" prompt routes through. (workout-with-timer PR 5)
    static func climbName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Climbing" : trimmed
    }

    // MARK: - Input parsing (shared by the live player and the summary's edit mode, issue #73)

    /// Reps text → `Int`, whitespace-trimmed; empty/non-numeric → `nil` (the player's exact rule).
    static func parseReps(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces))
    }

    /// Weight text → `Double`, accepting a decimal comma ("62,5"); empty/non-numeric → `nil`.
    /// Bounded: non-finite values and magnitudes ≥ 100 000 are rejected — no real lift, and they
    /// poison formatting and every downstream stat.
    static func parseWeight(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")
                                     .trimmingCharacters(in: .whitespaces)),
              value.isFinite, abs(value) < 100_000 else { return nil }
        return value
    }

    // MARK: - Formatting

    /// Weight without a trailing ".0" (60.0 → "60", 62.5 → "62.5"). `Int(exactly:)`, not `Int(_:)`
    /// — a value past `Int.max` (corrupt/legacy data) must fall back to `String(value)`, not trap.
    static func formatWeight(_ value: Double) -> String {
        if value == value.rounded(), let whole = Int(exactly: value.rounded()) {
            return String(whole)
        }
        return String(value)
    }

    /// Seconds → "M:SS" (or "H:MM:SS" past an hour).
    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Seconds → the `(minutes, seconds)` strings the timed-set sheet's Min/Sec fields hold — the inverse
    /// of the build path's `min*60 + sec`, so a live-timed capture (`StopwatchView` PR 2) fills the SAME
    /// state the Manual fields write and the save path stays one expression. Total minutes (no hour wrap,
    /// matching the two minute/second fields); negatives/non-finite clamp to "0"/"0". (workout-with-timer PR 2)
    static func splitDuration(_ seconds: Double) -> (minutes: String, seconds: String) {
        guard seconds.isFinite, seconds > 0 else { return ("0", "0") }
        let total = Int(seconds.rounded())
        return (String(total / 60), String(total % 60))
    }
}
