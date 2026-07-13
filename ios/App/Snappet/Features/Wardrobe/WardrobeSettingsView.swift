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

    private var archived: [WardrobeItem] { items.filter(\.isArchived) }

    var body: some View {
        List {
            Section {
                Label {
                    Text("Everything stays in **your** Apple ecosystem — no Snappet servers.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(SnappetColor.wardrobe)
                }
                .listRowBackground(SnappetColor.wardrobe.opacity(0.07))
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
                            .font(.caption.weight(.bold))
                            .tint(SnappetColor.wardrobe)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { modelContext.delete(archived[i]) }
                        try? modelContext.save()
                    }
                }
            }

            if items.isEmpty {
                Section {
                    Button {
                        WardrobeSampleCloset.seed(into: modelContext)
                    } label: {
                        settingRow(symbol: "sparkles.rectangle.stack", tint: SnappetColor.wardrobe,
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
                }
                .accessibilityIdentifier("wardrobe.settings.deleteAll")
            } footer: {
                Text("AI tagging & styling run on-device with Apple Intelligence. Nothing is ever uploaded.")
            }
        }
        .navigationTitle("Wardrobe Settings")
        .navigationBarTitleDisplayMode(.inline)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.ink)
                Text(subtitle).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            }
        }
    }

    private func deleteAll() {
        for item in items { modelContext.delete(item) }
        for event in wearEvents { modelContext.delete(event) }
        for outfit in outfits { modelContext.delete(outfit) }
        try? modelContext.save()
    }
}
