import SwiftUI

/// A `Form` section that surfaces a `ReceiptValidation.Report`: a coloured headline row
/// (Balanced / Needs review / Doesn't add up) that expands to the individual checks. Advisory
/// only — it never disables Save.
struct ReceiptValidationBanner: View {
    let report: ReceiptValidation.Report
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(report.checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(check.status))
                            .foregroundStyle(color(check.status))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).font(.subheadline)
                            if !check.detail.isEmpty {
                                Text(check.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon(report.overall))
                    Text(report.headline).fontWeight(.semibold)
                }
                .foregroundStyle(color(report.overall))
                .accessibilityIdentifier("expense.receipt.validation")
            }
        }
    }

    private func icon(_ status: ReceiptValidation.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private func color(_ status: ReceiptValidation.Status) -> Color {
        switch status {
        case .pass: return SnappetColor.habits
        case .warn: return .orange
        case .fail: return SnappetColor.pomodoro
        }
    }
}
