import Foundation

/// Formats the **climb-name overlay caption** shown over a clip in the studio — the climb's name on
/// the first line, then `grade · angle°`, optionally with the setter. Pure (Foundation-only) so it's
/// unit-tested without a device and stays free of any rendering/UI concern: the studio resolves the
/// climb metadata (from `KilterLogEntry` + `KilterCatalog`) and asks this to build the string, which
/// then becomes a freely-editable `OverlayItem.content`.
enum KilterClimbCaption {

    /// Build the caption. `name` is required; `gradeLabel`/`angle`/`setter` are folded in when present.
    /// `includeSetter` only adds the `· by …` suffix when there's a non-empty setter to show.
    static func caption(name: String, gradeLabel: String, angle: Int,
                        setter: String?, includeSetter: Bool) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var detail: [String] = []
        let grade = gradeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !grade.isEmpty { detail.append(grade) }
        if angle > 0 { detail.append("\(angle)°") }
        if includeSetter, let setter = setter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !setter.isEmpty {
            detail.append("by \(setter)")
        }
        let detailLine = detail.joined(separator: " · ")
        if trimmedName.isEmpty { return detailLine }
        if detailLine.isEmpty { return trimmedName }
        return "\(trimmedName)\n\(detailLine)"
    }

    /// Compose the climb-name tag's content with an optional **"Attempt N"** line (prompt 10): the studio
    /// editor toggles this on/off for a clip attached to a specific attempt. ON appends "Attempt N" on its
    /// own line (so it reads under the base caption — which may itself already be two lines); OFF returns
    /// the base caption unchanged. A non-positive `attempt` or `showAttempt == false` is a no-op, so the
    /// base caption stays the single source of truth and remains freely editable. Pure (Foundation-only).
    static func climbTagContent(caption: String, attempt: Int?, showAttempt: Bool) -> String {
        guard showAttempt, let attempt, attempt > 0 else { return caption }
        let base = caption
        return base.isEmpty ? "Attempt \(attempt)" : "\(base)\nAttempt \(attempt)"
    }

    /// **Compose** a climb-name tag's RENDERED string from its parts (prompt 12): the user-editable BASE
    /// `caption` (kept verbatim as `OverlayItem.content`), optionally a ` · by {setter}` suffix on the
    /// detail line, then an `Attempt N` line on its own. The base and the system-derived lines never
    /// share an encoding, so toggling the setter / attempt can't corrupt user text and there's no regex
    /// strip — the canvas chip and the export build the SAME string from this one pure helper, so
    /// preview == file. Pure (Foundation-only) → unit-tested without a device.
    ///
    /// `setter` is appended only when `showSetter` is on AND a non-empty setter is supplied: as
    /// ` · by {setter}` after the LAST line of the base caption (the detail line, e.g.
    /// "Blue Crux\n6c · 40°" → "Blue Crux\n6c · 40° · by jdoe"). `Attempt N` is appended only when
    /// `showAttempt` is on and `attempt > 0`, on its own trailing line.
    static func composeClimbTag(base: String, setter: String?, showSetter: Bool,
                                attempt: Int?, showAttempt: Bool) -> String {
        var body = base
        if showSetter, let setter = setter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !setter.isEmpty {
            // Ride the LAST line (the detail line, e.g. "grade · angle") — append to the end of the base
            // so the setter sits beside it, then the Attempt line (if any) goes below them both.
            body = body.isEmpty ? "by \(setter)" : "\(body) · by \(setter)"
        }
        return climbTagContent(caption: body, attempt: attempt, showAttempt: showAttempt)
    }
}
