import SwiftUI

/// "Merge with…" (Library redesign L3, prompt 185): pick which of your other activities are really this one. Names that
/// look alike are suggested first; everything else of the same discipline follows. Nothing is pre-ticked — merging
/// rewrites history, so you choose every log (and can undo from the page).
struct LibraryMergeSheet: View {
    let target: LibraryCatalog.Row
    /// Your other activities of the same discipline that can merge.
    let candidates: [LibraryCatalog.Row]
    let onMerge: ([ActivityKey]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<ActivityKey>
    @State private var query = ""

    init(target: LibraryCatalog.Row, candidates: [LibraryCatalog.Row], onMerge: @escaping ([ActivityKey]) -> Void) {
        self.target = target
        self.candidates = candidates
        self.onMerge = onMerge
        _picked = State(initialValue: [])
    }

    private var suggested: [LibraryCatalog.Row] { LibraryMaintenance.lookalikes(of: target, in: candidates) }
    private var others: [LibraryCatalog.Row] {
        let s = Set(suggested.map(\.key))
        return LibraryCatalog.sorted(LibraryCatalog.filter(candidates.filter { !s.contains($0.key) }, query: query,
                                                           discipline: target.discipline), by: .recent)
    }
    private var pickedSessions: Int { candidates.filter { picked.contains($0.key) }.reduce(0) { $0 + $1.sessions } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The logs you pick are renamed to “\(target.title)” everywhere. Grades, attempts and clips stay as they are.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !suggested.isEmpty {
                    Section("Looks like the same \(target.discipline == .climb ? "climb" : "activity")") {
                        ForEach(suggested) { row($0) }
                    }
                }
                if !others.isEmpty {
                    Section("Others") { ForEach(others) { row($0) } }
                }
                if suggested.isEmpty && others.isEmpty {
                    Text("Nothing else to merge with.").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query)
            .navigationTitle("Merge with…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Merge" : "Merge \(pickedSessions) \(pickedSessions == 1 ? "session" : "sessions")") {
                        onMerge(Array(picked)); dismiss()
                    }
                    .disabled(picked.isEmpty)
                    .accessibilityIdentifier("library.merge.confirm")
                }
            }
        }
    }

    private func row(_ r: LibraryCatalog.Row) -> some View {
        let on = picked.contains(r.key)
        return Button {
            if on { picked.remove(r.key) } else { picked.insert(r.key) }
        } label: {
            HStack {
                LibraryYoursRow(row: r, unit: .kg)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? SnappetColor.workout : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("library.merge.row")
    }
}
