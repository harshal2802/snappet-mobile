import SwiftUI

// Prompt 275: choose WHICH copied clips leave this iPhone — by age, by activity, by session.
// The choosing is pure (`MediaVaultFreeUp`); this screen only draws it and asks once.

struct ClipFreeUpView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MediaVaultFreeUpItem]?
    @State private var choice = MediaVaultFreeUpChoice()
    @State private var confirming = false
    @State private var now = Date()
    @State private var inStudio: Set<UUID> = []

    private var vault: MediaVaultService { app.mediaVault }
    private var all: [MediaVaultFreeUpItem] { items ?? [] }
    private var selection: [MediaVaultFreeUpItem] { MediaVaultFreeUp.selection(all, choice: choice, now: now) }

    var body: some View {
        let selected = selection
        let total = MediaVaultFreeUp.total(selected)
        List {
            if items == nil {
                Section { HStack { ProgressView(); Text("Looking at your clips…").foregroundStyle(.secondary) } }
            } else if all.isEmpty {
                Section {
                    Text(vault.libraryVisible ? "No clip on this iPhone has a copy in Google Drive yet."
                                              : "Allow full access to Photos in Settings to free up space. With limited access Snappet can’t tell which clips are on this iPhone.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Age") {
                    Picker("Filmed", selection: $choice.age) {
                        ForEach(MediaVaultFreeUpChoice.Age.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("mediaVault.freeUp.age")
                }
                Section("Activities") {
                    ForEach(MediaVaultFreeUp.activities(all)) { group in
                        check(group.name, detail: MediaVaultText.freeUpTotal(count: group.clips, bytes: group.bytes),
                              isOn: choice.activities?.contains(group.name) ?? true) { toggleActivity(group.name) }
                            .accessibilityIdentifier("mediaVault.freeUp.activity.\(group.name)")
                    }
                }
                Section {
                    NavigationLink {
                        ClipFreeUpSessionsView(groups: MediaVaultFreeUp.sessions(MediaVaultFreeUp.narrowed(all, choice: choice, now: now)),
                                               picked: $choice.sessions)
                    } label: {
                        HStack {
                            Text("Sessions")
                            Spacer()
                            Text(choice.sessions.map { "\($0.count) picked" } ?? "All").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("mediaVault.freeUp.sessions")
                } footer: {
                    Text("A clip is removed only when it matches all three.")
                }
                Section {
                    Text(total.count > 0 ? MediaVaultText.freeUpTotal(count: total.count, bytes: total.bytes)
                                         : "Nothing matches.")
                        .accessibilityIdentifier("mediaVault.freeUp.total")
                    if let warning = MediaVaultText.usedInStudio(selected.filter { inStudio.contains($0.id) }.count) {
                        Label(warning, systemImage: "film.stack").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("mediaVault.freeUp.studio")
                    }
                    Button("Remove from this iPhone…", role: .destructive) { confirming = true }
                        .disabled(total.count == 0 || vault.isBusy)
                        .accessibilityIdentifier("mediaVault.freeUp.go")
                } header: {
                    Text("Selected")
                } footer: {
                    Text("The copies stay in Google Drive and the clips keep playing from there.")
                }
            }
        }
        .navigationTitle("Free up space")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            now = Date()
            items = await vault.freeUpItems(context: context)
            inStudio = vault.clipsUsedInStudio(context: context)
        }
        // An alert so Cancel is always shown (a confirmation dialog here loses it — see Manage copies).
        .alert("Remove \(total.count) clip\(total.count == 1 ? "" : "s") from this iPhone?", isPresented: $confirming) {
            Button("Check copies, then remove from iPhone", role: .destructive) {
                let ids = Set(selected.map(\.id))
                let vault = vault, app = app, context = context
                Task { await vault.freeUpSpace(context: context, only: ids); await app.reconcileMediaLinks() }
                dismiss()   // progress and the result show on Manage copies
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each copy is checked in Google Drive first; a clip whose copy can’t be confirmed stays. iOS then asks you once more and keeps the originals in Recently Deleted for 30 days. After that Google Drive holds the only copy. With iCloud Photos on, they leave your other Apple devices too.")
        }
    }

    private func toggleActivity(_ name: String) {
        var set = choice.activities ?? Set(all.map(\.activity))
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
        choice.activities = set == Set(all.map(\.activity)) ? nil : set
    }

    private func check(_ title: String, detail: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        ClipFreeUpCheckRow(title: title, detail: detail, isOn: isOn, action: action)
    }
}

/// A row that is ticked or not. The tick is the whole truth: no tick, not included.
struct ClipFreeUpCheckRow: View {
    let title: String
    let detail: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? SnappetColor.brand : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Pick sessions. "All sessions" is its own ticked row, so nothing is included by a hidden rule.
struct ClipFreeUpSessionsView: View {
    let groups: [MediaVaultFreeUp.Group]
    @Binding var picked: Set<UUID>?

    var body: some View {
        List {
            Section {
                ClipFreeUpCheckRow(title: "All sessions", detail: "\(groups.count) with copied clips", isOn: picked == nil) { picked = nil }
                    .accessibilityIdentifier("mediaVault.freeUp.sessions.all")
            }
            Section {
                ForEach(groups) { group in
                    let id = UUID(uuidString: group.id)
                    ClipFreeUpCheckRow(title: title(group), detail: MediaVaultText.freeUpTotal(count: group.clips, bytes: group.bytes),
                                       isOn: id.map { picked?.contains($0) ?? false } ?? false) {
                        guard let id else { return }
                        var set = picked ?? []
                        if set.contains(id) { set.remove(id) } else { set.insert(id) }
                        picked = set.isEmpty ? nil : set
                    }
                }
            } footer: {
                Text("Only sessions that match the age and activities you chose are listed.")
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func title(_ group: MediaVaultFreeUp.Group) -> String {
        guard let date = group.startedAt else { return group.name }
        return group.name + " · " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
