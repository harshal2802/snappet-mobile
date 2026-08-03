import SwiftUI
import SwiftData

/// The cleanup review (wardrobe prompt 05): what would move, grouped and counted, with the
/// uncertain values separated out. **Nothing is written until Apply**, and Apply is reversible.
struct WardrobeTidyView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var plan = WardrobeTidyPlan.Plan()
    /// User's answer for each uncertain value: what field it really belongs in.
    @State private var uncertainChoice: [String: WardrobeTidyPlan.Field] = [:]
    @State private var appliedBatch: UUID?
    @State private var appliedCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if let appliedBatch { doneState(appliedBatch) }
                else if plan.isEmpty { emptyState }
                else { proposal }
            }
            .background(SnappetColor.paper)
            .navigationTitle("Tidy up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(appliedBatch == nil ? "Not now" : "Done") { dismiss() }
                }
            }
        }
        .onAppear { plan = WardrobeTidyStore.plan(in: modelContext) }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("✨").font(.system(size: 44))
            Text("Nothing to tidy").font(.headline)
            Text("Brands and sizes are already in their own fields.")
                .font(.caption).foregroundStyle(SnappetColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func doneState(_ batch: UUID) -> some View {
        VStack(spacing: 12) {
            Text("✅").font(.system(size: 44))
            Text("\(appliedCount) changes applied").font(.headline)
            Text("Brands and sizes now live in their own fields, and your dropdowns know them.")
                .font(.caption).foregroundStyle(SnappetColor.textSecondary)
                .multilineTextAlignment(.center)
            Button(role: .destructive) {
                WardrobeTidyStore.undo(batchID: batch, in: modelContext)
                appliedBatch = nil
                plan = WardrobeTidyStore.plan(in: modelContext)
            } label: {
                Label("Undo tidy up", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.bold))
            }
            .buttonStyle(.bordered)
            .padding(.top, 6)
            .accessibilityIdentifier("wardrobe.tidy.undo")
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var proposal: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                banner

                if !plan.brandGroups.isEmpty {
                    header("Material → Brand", detail: "\(brandItemCount) items")
                    ForEach(plan.brandGroups, id: \.value) { group in
                        moveRow(group.value, count: group.count)
                    }
                    Text("Values differing only by spacing or case are merged into one brand.")
                        .font(.system(size: 10.5)).foregroundStyle(SnappetColor.textSecondary)
                        .padding(.horizontal, 4)
                }

                if plan.sizeCount > 0 {
                    header("Name → Size", detail: "\(plan.sizeCount) items")
                    moveRow("“… size M / S” in the item name", count: plan.sizeCount)
                    Text("The size words are removed from the name; the rest is left alone.")
                        .font(.system(size: 10.5)).foregroundStyle(SnappetColor.textSecondary)
                        .padding(.horizontal, 4)
                }

                if !plan.uncertain.isEmpty { uncertainSection }

                applyButton
            }
            .padding(16)
        }
    }

    private var banner: some View {
        Text("We found details stored in the wrong fields. Nothing changes until you apply — "
             + "and you can undo it afterwards.")
            .font(.caption)
            .foregroundStyle(SnappetColor.textSecondary)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func header(_ title: String, detail: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .heavy)).tracking(0.08)
            Spacer()
            Text(detail).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(SnappetColor.textSecondary)
        .padding(.top, 8).padding(.horizontal, 4)
    }

    private func moveRow(_ label: String, count: Int) -> some View {
        HStack {
            Text(label).font(.subheadline).lineLimit(1)
            Spacer()
            Text("\(count) →").font(.subheadline.weight(.bold))
                .foregroundStyle(SnappetColor.wardrobe)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(SnappetColor.hairline))
    }

    /// The values the plan refuses to classify. Defaulting these to "skip" is deliberate — an
    /// unanswered question must not become a silent write.
    private var uncertainSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            header("Not sure", detail: "\(plan.uncertain.count) values")
            Text("These look like prints rather than brands. Pick where each belongs, or leave "
                 + "them alone.")
                .font(.system(size: 10.5)).foregroundStyle(SnappetColor.textSecondary)
                .padding(.horizontal, 4)

            ForEach(plan.uncertain) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.value).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Picker("", selection: binding(for: item)) {
                        Text("Skip").tag(Optional<WardrobeTidyPlan.Field>.none)
                        Text("Brand").tag(Optional(WardrobeTidyPlan.Field.brand))
                        Text("Material").tag(Optional(WardrobeTidyPlan.Field.material))
                    }
                    .pickerStyle(.segmented)
                }
                .padding(11)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(SnappetColor.hairline))
            }
        }
    }

    private var applyButton: some View {
        Button {
            let edits = plan.edits + uncertainEdits
            appliedCount = edits.count
            appliedBatch = WardrobeTidyStore.apply(edits, in: modelContext)
        } label: {
            Text("Apply \(plan.changeCount + uncertainEdits.count) changes")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(SnappetColor.brand)
        .padding(.top, 12)
        .accessibilityIdentifier("wardrobe.tidy.apply")
    }

    // MARK: - Helpers

    private var brandItemCount: Int { plan.brandGroups.reduce(0) { $0 + $1.count } }

    private func binding(for item: WardrobeTidyPlan.Uncertain)
        -> Binding<WardrobeTidyPlan.Field?> {
        Binding(get: { uncertainChoice[item.id] },
                set: { uncertainChoice[item.id] = $0 })
    }

    /// Edits derived from the user's answers. A value left on "Skip" contributes nothing.
    private var uncertainEdits: [WardrobeTidyPlan.Edit] {
        plan.uncertain.flatMap { unc -> [WardrobeTidyPlan.Edit] in
            guard let field = uncertainChoice[unc.id] else { return [] }
            return unc.itemIDs.flatMap { id -> [WardrobeTidyPlan.Edit] in
                switch field {
                case .brand:
                    // Move it: set the brand AND clear material, mirroring a confident edit.
                    return [.init(itemID: id, field: .brand, oldValue: "", newValue: unc.value),
                            .init(itemID: id, field: .material, oldValue: unc.value, newValue: "")]
                case .material:
                    // Keep it where it is, but normalized (this is still a change worth recording
                    // when the stored value had stray whitespace).
                    return [.init(itemID: id, field: .material,
                                  oldValue: unc.value, newValue: unc.value)]
                case .sizeLabel, .name:
                    return []
                }
            }
        }
    }
}
