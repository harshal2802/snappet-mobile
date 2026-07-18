import SwiftUI

/// The **import-confirm preview** for a lineup / plan arriving over a scanned QR or a
/// `snappet://festival/…` link (festival prompt 05, the `RoutineImportSheet` analog). NEVER
/// silent-imports: it shows what's arriving — a whole lineup to install, a plan to star onto a lineup
/// you have (or a subset to install if you don't), or a hosted lineup to fetch — and only on the CTA
/// does the host run the (pure-decided) action.
struct FestivalImportSheet: View {
    let shared: SharedLineup
    /// The pack ids already installed — decides "add to my <festival>" vs "install".
    let installedPackIDs: Set<String>
    /// Run the confirmed import (the host owns the model context + installer). May be async (a fetch).
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var action: SharedLineup.ReceiveAction {
        shared.receiveAction(installedPackIDs: installedPackIDs)
    }

    /// The carried set count (payload forms) — the "· N sets" line.
    private var setCount: Int? { shared.carriedPack?.allSets.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "music.mic")
                                .font(.title3)
                                .foregroundStyle(SnappetColor.festival)
                                .frame(width: 40, height: 40)
                                .background(SnappetColor.surfaceMuted,
                                            in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shared.title).font(.title3.weight(.semibold))
                                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Label(explainer, systemImage: explainerIcon)
                        .font(.footnote)
                }
            }
            .navigationTitle(shared.isPlan ? "Add a plan" : "Add a lineup")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Label(ctaLabel, systemImage: "plus.circle.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.festival)
                .padding()
                .background(.bar)
                .accessibilityIdentifier("festival.import.confirm")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var subtitle: String {
        var parts = [shared.isPlan ? "A plan" : "A lineup"]
        if let n = setCount { parts.append("\(n) set\(n == 1 ? "" : "s")") }
        switch action {
        case .fetchInstall: parts.append("install link")
        default: if shared.carriedPack != nil { parts.append("from the code, no download") }
        }
        return parts.joined(separator: " · ")
    }

    private var explainer: String {
        switch action {
        case .installLineup:
            return "This installs as a new festival on this device (a reinstall keeps your stars)."
        case .applyPlan:
            return "You already have this festival — these sets get starred in your plan. Nothing is overwritten."
        case .installPlan:
            return "You don't have this festival yet — its starred sets install as a small lineup you can grow later."
        case .fetchInstall:
            return "The full lineup is fetched once from Snappet Lineups, then works offline."
        }
    }

    private var explainerIcon: String {
        switch action {
        case .applyPlan: return "star.fill"
        case .fetchInstall: return "arrow.down.circle"
        default: return "info.circle"
        }
    }

    private var ctaLabel: String {
        switch action {
        case .applyPlan(let packID, _):
            let name = shared.carriedPack?.name ?? packID
            return "Add to my \(name)"
        case .fetchInstall:
            return "Get this lineup"
        default:
            return shared.isPlan ? "Add this plan" : "Add this lineup"
        }
    }
}
