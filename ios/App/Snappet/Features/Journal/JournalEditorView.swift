import SwiftUI
import SwiftData

/// View / edit a single entry. Used both for brand-new entries (`isNew == true`,
/// logs usage on first save) and for editing existing ones.
struct JournalEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    @Bindable var entry: JournalEntry
    let isNew: Bool

    @FocusState private var bodyFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Title (optional)", text: $entry.title)
                    .font(.headline)
            }
            Section("Entry") {
                TextEditor(text: $entry.body)
                    .frame(minHeight: 220)
                    .focused($bodyFocused)
            }
        }
        .navigationTitle(isNew ? "New Entry" : "Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save() }
            }
        }
        .onAppear {
            if isNew { bodyFocused = true }
        }
    }

    private func save() {
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop an entirely empty new entry rather than persisting a blank row.
        if isNew && trimmedTitle.isEmpty && trimmedBody.isEmpty {
            modelContext.delete(entry)
            try? modelContext.save()
            dismiss()
            return
        }

        entry.updatedAt = .now
        try? modelContext.save()

        if isNew {
            core.log(module: "journal", action: "entry",
                     summary: "Journaled: \(firstWords(title: trimmedTitle, body: trimmedBody))")
        }
        dismiss()
    }

    /// The title if present, otherwise the first ~5 words of the body.
    private func firstWords(title: String, body: String) -> String {
        if !title.isEmpty { return title }
        let words = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return words.prefix(5).joined(separator: " ")
    }
}
