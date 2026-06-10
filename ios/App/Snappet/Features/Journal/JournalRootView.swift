import SwiftUI
import SwiftData

/// The Quick Journal root: a list of entries (newest first) with create / view-edit /
/// delete, plus live search/filter by title, body, or tag. Pushed into the suite's
/// NavigationStack, so it adds no stack of its own.
struct JournalRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Environment(SuiteRouter.self) private var router
    @Query(sort: \JournalEntry.createdAt, order: .reverse) private var entries: [JournalEntry]

    @State private var newEntry: JournalEntry?
    @State private var searchText: String = ""
    /// Entries staged by a swipe-delete, awaiting the user's confirmation.
    @State private var pendingDeletes: [JournalEntry]?

    /// Entries matching the current search query (title, body, or any tag — case-insensitive).
    /// Kept out of `body` so the view stays thin.
    private var filteredEntries: [JournalEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            entry.title.lowercased().contains(query)
                || entry.body.lowercased().contains(query)
                || entry.tags.contains { $0.contains(query) }
        }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No entries yet", systemImage: "book.closed",
                    description: Text("Tap + to write your first journal entry."))
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                entryList
            }
        }
        .navigationTitle("Journal")
        .searchable(text: $searchText, prompt: "Search title, body, or tag")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createEntry()
                } label: {
                    Label("New Entry", systemImage: "plus")
                }
                .accessibilityIdentifier("journal.add")
            }
        }
        .navigationDestination(for: JournalEntry.self) { entry in
            JournalEditorView(entry: entry, isNew: false)
        }
        .navigationDestination(item: $newEntry) { entry in
            JournalEditorView(entry: entry, isNew: true)
        }
        .confirmationDialog(
            pendingDeletes?.count == 1 ? "Delete this entry?" : "Delete \(pendingDeletes?.count ?? 0) entries?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entries = pendingDeletes { delete(entries) }
                pendingDeletes = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletes = nil }
        } message: {
            Text("This permanently removes the entry and can't be undone.")
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletes != nil },
            set: { if !$0 { pendingDeletes = nil } }
        )
    }

    private var entryList: some View {
        List {
            ForEach(filteredEntries) { entry in
                Button { router.push(entry) } label: {
                    JournalRow(entry: entry)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("journalRow")
            }
            .onDelete(perform: deleteEntries)
        }
    }

    private func createEntry() {
        let entry = JournalEntry(title: "", body: "")
        modelContext.insert(entry)
        newEntry = entry
    }

    /// Swipe-delete stages the entries behind a confirmation — a journal entry is a whole
    /// document, so one accidental swipe shouldn't silently destroy it.
    private func deleteEntries(at offsets: IndexSet) {
        // Map list offsets through the filtered view so the right entries are staged.
        let visible = filteredEntries
        pendingDeletes = offsets.map { visible[$0] }
    }

    private func delete(_ entries: [JournalEntry]) {
        for entry in entries {
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }
}

/// A single row: title (or first line of body), the created date, and any tags.
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
            if !entry.tags.isEmpty {
                Text(entry.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
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
