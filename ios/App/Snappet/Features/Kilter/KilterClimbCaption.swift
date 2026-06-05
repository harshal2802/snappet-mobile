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
}
