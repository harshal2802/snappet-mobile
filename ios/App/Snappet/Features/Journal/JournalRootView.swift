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
        .onChange(of: newEntry) { oldValue, newValue in
            // The item binding nils out exactly when the new-entry editor pops (Done,
            // back button, or edge swipe). Unlike the editor's own onDisappear, it does
            // NOT fire on a tab switch — so a still-pushed editor can never have its
            // entry deleted out from under it.
            guard newValue == nil, let abandoned = oldValue else { return }
            discardIfAbandonedBlank(abandoned)
        }
        .onAppear { sweepAbandonedBlanks() }
        // Static title + `presenting:` keeps the dialog copy stable through the dismiss
        // animation (no nil-fallback flash) — the same immunity the Habit dialog has.
        .confirmationDialog(
            "Delete this entry?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDeletes
        ) { staged in
            Button("Delete", role: .destructive) { delete(staged) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
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
        // One shared instant: `isAbandonedBlank` relies on `updatedAt == createdAt`, and the
        // init's two independent `.now` defaults would differ by microseconds.
        let now = Date.now
        let entry = JournalEntry(title: "", body: "", createdAt: now, updatedAt: now)
        modelContext.insert(entry)
        newEntry = entry
    }

    /// Drop a popped new entry that never got content — the back-button/edge-swipe path
    /// the editor's Done guard can't see. Idempotent with Done's own blank-delete via the
    /// `modelContext` check.
    private func discardIfAbandonedBlank(_ entry: JournalEntry) {
        guard entry.modelContext != nil, JournalEntry.isAbandonedBlank(entry) else { return }
        modelContext.delete(entry)
        try? modelContext.save()
    }

    /// Remove blank never-saved rows that survived a process death while the new-entry
    /// editor was open (autosave persists the pre-inserted row and no view callback ever
    /// fires). Runs on appear, when no abandoned editor can be on top of us.
    private func sweepAbandonedBlanks() {
        let strays = entries.filter { $0 !== newEntry && JournalEntry.isAbandonedBlank($0) }
        guard !strays.isEmpty else { return }
        for entry in strays { modelContext.delete(entry) }
        try? modelContext.save()
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
