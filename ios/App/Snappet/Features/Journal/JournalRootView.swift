import SwiftUI
import SwiftData

/// The Quick Journal root: a list of entries (newest first) with create / view-edit /
/// delete. Pushed into the suite's NavigationStack, so it adds no stack of its own.
struct JournalRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Query(sort: \JournalEntry.createdAt, order: .reverse) private var entries: [JournalEntry]

    @State private var newEntry: JournalEntry?

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No entries yet", systemImage: "book.closed",
                    description: Text("Tap + to write your first journal entry."))
            } else {
                entryList
            }
        }
        .navigationTitle("Journal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createEntry()
                } label: {
                    Label("New Entry", systemImage: "plus")
                }
            }
        }
        .navigationDestination(for: JournalEntry.self) { entry in
            JournalEditorView(entry: entry, isNew: false)
        }
        .navigationDestination(item: $newEntry) { entry in
            JournalEditorView(entry: entry, isNew: true)
        }
    }

    private var entryList: some View {
        List {
            ForEach(entries) { entry in
                NavigationLink(value: entry) {
                    JournalRow(entry: entry)
                }
            }
            .onDelete(perform: deleteEntries)
        }
    }

    private func createEntry() {
        let entry = JournalEntry(title: "", body: "")
        modelContext.insert(entry)
        newEntry = entry
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(entries[index])
        }
        try? modelContext.save()
    }
}

/// A single row: title (or first line of body) plus the created date.
private struct JournalRow: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .font(.headline)
                .lineLimit(1)
            Text(entry.createdAt, format: .dateTime.month().day().year().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var displayTitle: String {
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let firstLine = entry.body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "Untitled" : firstLine
    }
}
