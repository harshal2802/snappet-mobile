import SwiftUI
import SwiftData

/// Wardrobe settings: the Snappet-level backup pointer (wardrobe rows ride the suite
/// backup file — the locked decision; no wardrobe-only codec), archived items, sample
/// closet, and the delete-everything hatch. All copy leads with the privacy story.
struct WardrobeSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WardrobeItem.createdAt, order: .reverse) private var items: [WardrobeItem]
    @Query private var wearEvents: [WearEvent]
    @Query private var outfits: [WardrobeOutfit]

    @State private var confirmDeleteAll = false
    @State private var showTidy = false

    private var archived: [WardrobeItem] { items.filter(\.isArchived) }

    /// How much the cleanup would move — computed from the live closet so the row disappears
    /// once there's nothing left to tidy.
    private var tidyChangeCount: Int {
        let plan = WardrobeTidyPlan.make(rows: items.map {
            WardrobeTidyPlan.Row(id: $0.id, name: $0.name, material: $0.material,
                                 brand: $0.brand, sizeLabel: $0.sizeLabel)
        })
        return plan.changeCount + plan.uncertain.count
    }

    var body: some View {
        List {
            Section {
                Label {
                    Text("Everything stays in **your** Apple ecosystem — no Snappet servers.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(SnappetColor.textSecondary)
                }
            }

            Section {
                NavigationLink {
                    BackupView(storeIsFallback: false)
                } label: {
                    settingRow(symbol: "externaldrive.badge.icloud", tint: SnappetColor.budget,
                               title: "Backup & restore",
                               subtitle: "Wardrobe rides the Snappet suite backup — \(items.count) items, \(outfits.count) outfits, \(wearEvents.count) wears")
                }
                .accessibilityIdentifier("wardrobe.settings.backup")
            } footer: {
                Text("One file covers every Snappet mini-app. The data model is iCloud-sync-ready; live CloudKit sync is planned.")
            }

            if !archived.isEmpty {
                Section("Archived · \(archived.count)") {
                    ForEach(archived) { item in
                        HStack(spacing: 10) {
                            WardrobeItemTile(item: item, height: 38).frame(width: 38)
                            Text(item.name).font(.subheadline)
                            Spacer()
                            Button("Restore") {
                                item.isArchived = false
                                try? modelContext.save()
                            }
                            .font(.caption.weight(.medium))
                            .tint(SnappetColor.brand)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            // Sweep photo rows first — plain UUID FK, no cascade (prompt 04).
                            WardrobePhotoStore.deleteAll(forItem: archived[i].id, in: modelContext)
                            modelContext.delete(archived[i])
                        }
                        try? modelContext.save()
                    }
                }
            }

            if tidyChangeCount > 0 {
                Section {
                    Button {
                        showTidy = true
                    } label: {
                        settingRow(symbol: "wand.and.sparkles", tint: SnappetColor.brand,
                                   title: "Tidy up details",
                                   subtitle: tidyChangeCount == 1
                                       ? "1 value looks like it's in the wrong field — review the move"
                                       : "\(tidyChangeCount) values look like they're in the wrong field — review the moves")
                    }
                    .accessibilityIdentifier("wardrobe.settings.tidy")
                }
            }

            if items.isEmpty {
                Section {
                    Button {
                        WardrobeSampleCloset.seed(into: modelContext)
                    } label: {
                        settingRow(symbol: "sparkles.rectangle.stack", tint: SnappetColor.brand,
                                   title: "Try a sample closet",
                                   subtitle: "13 demo pieces — delete any time")
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Label("Delete all wardrobe data", systemImage: "trash")
                        .foregroundStyle(SnappetColor.perfHard)
                }
                .accessibilityIdentifier("wardrobe.settings.deleteAll")
            } footer: {
                Text("AI tagging & styling run on-device with Apple Intelligence. Nothing is ever uploaded.")
            }
        }
        .navigationTitle("Wardrobe settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTidy) {
            WardrobeTidyView()
        }
        .confirmationDialog("Delete all wardrobe data?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete \(items.count) items, \(outfits.count) outfits & wear history", role: .destructive) {
                deleteAll()
            }
        } message: {
            Text("Removes every item, outfit and wear event. Other Snappet apps are untouched. This can't be undone.")
        }
    }

    private func settingRow(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                // Neutral icon tiles (prompt 234 — were white glyphs on pink / blue fills).
                .foregroundStyle(SnappetColor.textSecondary)
                .frame(width: 28, height: 28)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline).foregroundStyle(SnappetColor.ink)
                Text(subtitle).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            }
        }
    }

    private func deleteAll() {
        // Photo rows have a plain UUID FK with no cascade, so "delete everything" has to name
        // them explicitly or the closet's bytes survive the closet (wardrobe prompt 04).
        for item in items { WardrobePhotoStore.deleteAll(forItem: item.id, in: modelContext) }
        for item in items { modelContext.delete(item) }
        for event in wearEvents { modelContext.delete(event) }
        for outfit in outfits { modelContext.delete(outfit) }
        try? modelContext.save()
    }
}
