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
            let base: String
            switch (reps, weight) {
            case let (r?, w?): base = "\(r) × \(w)"
            case let (r?, nil): base = "\(r) reps"
            case let (nil, w?): base = w
            default: base = "—"
            }
            // A strength set MAY also be timed (Workout-Type Parity: time-under-tension / a timed hold).
            // Append the captured duration ("8 × 60 kg · 0:42") reusing the one duration funnel, mirroring
            // the `.climbAttempt` branch below. No change when there's no duration (the common case).
            if base != "—", let secs = set.durationSec, secs > 0 {
                return base + " · " + formatDuration(secs)
            }
            return base

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

    /// A one-line set summary for **display** surfaces (session detail, recents) — workout-redesign E2.
    /// Like `summary`, but discipline-aware and **unit-converting**: the weight is shown in the user's
    /// preferred display `unit` (the detail view shows the user's unit, not the set's stored unit), and a
    /// running leg renders distance · time · derived pace. This is the ONE funnel for the per-set display
    /// string (the `SetTileRow.detailText` logic moved here verbatim so it's unit-tested). The freeform
    /// player's live rows keep using `summary` (raw stored unit, no conversion).
    static func displaySummary(_ set: SetLog, discipline: WorkoutDiscipline, kind: SetKind,
                               unit: WeightUnit, distanceUnit: DistanceUnit) -> String {
        if discipline == .run { return runSummary(set, unit: distanceUnit) }
        switch kind {
        case .climbAttempt, .duration:
            return summary(set, kind: kind, unit: unit)
        case .repsWeight:
            var base: String
            if let w = set.actualWeight, w > 0 {
                let kg = WorkoutMath.toKg(w, set.weightUnit)
                base = "\(WorkoutMath.formatWeight(kg: kg, unit: unit)) \(unit.display) × \(set.actualReps ?? 0)"
            } else {
                base = set.actualReps.map { "\($0) reps" } ?? "done"
            }
            // A timed strength set carries a duration too → append it ("8 × 60 kg · 0:42").
            if base != "done", let secs = set.durationSec, secs > 0 {
                base += " · " + formatDuration(secs)
            }
            return base
        }
    }

    /// A one-line summary of a single **attempt** under a climb card (Quick Session redesign): the
    /// type-aware outcome (`ClimbType.statusLabel` — boulder "Sent", a route "Redpoint"), an optional
    /// captured duration, and the try count when > 1 — but **never** the grade. The grade lives once on
    /// the climb-card header (attempts are stamped with it for the pure stats), so repeating it on every
    /// row would be noise. e.g. "Sent · 0:42", "Onsight", "Project · 2 tries". Pure → unit-tested.
    static func attemptRow(_ set: SetLog, type: ClimbType) -> String {
        var parts: [String] = []
        if let status = set.climbStatusRaw.flatMap(KilterAscentStatus.init(rawValue:)) {
            parts.append(type.statusLabel(status))
        }
        if let secs = set.durationSec, secs > 0 { parts.append(formatDuration(secs)) }
        let tries = set.climbAttempts ?? 1
        if tries > 1 { parts.append("\(tries) tries") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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

    /// Duration text → seconds (the inverse of `formatDuration`), for the all-axis set editor. Accepts
    /// "M:SS" / "H:MM:SS", a plain seconds count ("90"), or a trailing-s form ("45s"); empty/malformed →
    /// `nil`. Bounded to a day so a fat-fingered value can't poison TUT stats.
    static func parseDuration(_ text: String) -> Double? {
        let t = text.lowercased().replacingOccurrences(of: "s", with: "")
            .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let secs: Double
        if t.contains(":") {
            let nums = t.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
            guard nums.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            let v = nums.compactMap { $0 }
            switch v.count {
            case 2: secs = v[0] * 60 + v[1]
            case 3: secs = v[0] * 3600 + v[1] * 60 + v[2]
            default: return nil
            }
        } else {
            guard let v = Double(t) else { return nil }
            secs = v
        }
        guard secs.isFinite, secs >= 0, secs < 86_400 else { return nil }
        return secs
    }

    /// Distance text (a decimal in the display `unit`, accepting a comma) → metres, for the all-axis set
    /// editor (the inverse of `formatDistance`'s number). Empty/non-positive/non-finite → `nil`; bounded.
    static func parseDistance(_ text: String, unit: DistanceUnit) -> Double? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")
                                 .trimmingCharacters(in: .whitespaces)),
              v.isFinite, v > 0, v < 100_000 else { return nil }
        return unit == .km ? v * 1000 : v * metersPerMile
    }

    /// The display-unit distance **number** (no unit suffix) for a metres value — what the editor's
    /// distance field shows, round-tripping with `parseDistance`. ≤ 0 / non-finite → "".
    static func distanceFieldText(_ meters: Double, unit: DistanceUnit) -> String {
        guard meters.isFinite, meters > 0 else { return "" }
        return trimmedDecimal(meters / (unit == .km ? 1000 : metersPerMile), decimals: 2)
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

    // MARK: - Distance / pace / run (Workout-Type Parity) — pure formatters; wired by the running phase.

    private static let metersPerMile = 1609.344

    /// A decimal trimmed of trailing zeros: 5.20 → "5.2", 5.00 → "5", 3.23 → "3.23".
    private static func trimmedDecimal(_ value: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// Metres → a unit-aware distance string ("5.2 km" / "3.23 mi"); non-finite / ≤ 0 → "—".
    static func formatDistance(_ meters: Double, unit: DistanceUnit) -> String {
        guard meters.isFinite, meters > 0 else { return "—" }
        switch unit {
        case .km: return "\(trimmedDecimal(meters / 1000, decimals: 2)) km"
        case .mi: return "\(trimmedDecimal(meters / metersPerMile, decimals: 2)) mi"
        }
    }

    /// Seconds-per-kilometre → a unit-aware pace string ("5:01/km" / "8:04/mi"); non-finite / ≤ 0 → "—".
    static func formatPace(secPerKm: Double, unit: DistanceUnit) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let perUnit = unit == .km ? secPerKm : secPerKm * (metersPerMile / 1000)
        let total = Int(perUnit.rounded())
        return String(format: "%d:%02d/%@", total / 60, total % 60, unit.display)
    }

    /// A one-line summary of a running effort: "5.2 km · 26:04 · 5:01/km" (distance · duration · derived
    /// pace). Pace is computed from distance + duration and omitted when either is missing. Pure → tested.
    static func runSummary(_ set: SetLog, unit: DistanceUnit) -> String {
        var parts: [String] = []
        let dist = set.distanceMeters ?? 0
        let dur = set.durationSec ?? 0
        if dist > 0 { parts.append(formatDistance(dist, unit: unit)) }
        if dur > 0 { parts.append(formatDuration(dur)) }
        if dist > 0, dur > 0 { parts.append(formatPace(secPerKm: dur / (dist / 1000), unit: unit)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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
