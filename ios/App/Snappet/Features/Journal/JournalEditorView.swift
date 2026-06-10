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
    @State private var tagInput: String = ""
    @State private var savedOrDiscarded = false

    var body: some View {
        Form {
            Section {
                TextField("Title (optional)", text: $entry.title)
                    .font(.headline)
                    .accessibilityIdentifier("journal.titleField")
            }
            Section("Entry") {
                TextEditor(text: $entry.body)
                    .frame(minHeight: 220)
                    .focused($bodyFocused)
                    .accessibilityIdentifier("journal.bodyField")
            }
            Section("Tags") {
                if !entry.tags.isEmpty {
                    TagChips(tags: entry.tags) { removeTag($0) }
                }
                TextField("Add a tag", text: $tagInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .accessibilityIdentifier("journal.tagField")
                    .onChange(of: tagInput) { _, newValue in
                        // Commit on comma so a "tag," entry produces a chip without return.
                        if newValue.contains(",") { commitTags() }
                    }
                    .onSubmit { commitTags() }
            }
        }
        .navigationTitle(isNew ? "New Entry" : "Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save() }
                    .accessibilityIdentifier("journal.save")
            }
        }
        .onAppear {
            if isNew { bodyFocused = true }
        }
        .onDisappear {
            guard isNew && !savedOrDiscarded else { return }
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty && body.isEmpty && entry.tags.isEmpty {
                modelContext.delete(entry)
                try? modelContext.save()
            }
        }
    }

    /// Fold the current `tagInput` (possibly comma-separated) into `entry.tags`, normalized.
    private func commitTags() {
        let pieces = tagInput.split(separator: ",").map(String.init)
        guard !pieces.isEmpty else { tagInput = ""; return }
        entry.tags = JournalEntry.normalizeTags(entry.tags + pieces)
        tagInput = ""
    }

    private func removeTag(_ tag: String) {
        entry.tags.removeAll { $0 == tag }
    }

    private func save() {
        // Fold any uncommitted text in the tag field before persisting.
        commitTags()

        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop an entirely empty new entry rather than persisting a blank row.
        if isNew && trimmedTitle.isEmpty && trimmedBody.isEmpty && entry.tags.isEmpty {
            modelContext.delete(entry)
            try? modelContext.save()
            savedOrDiscarded = true
            dismiss()
            return
        }

        entry.updatedAt = .now
        try? modelContext.save()

        if isNew {
            core.log(module: "journal", action: "entry",
                     summary: "Journaled: \(firstWords(title: trimmedTitle, body: trimmedBody))")
        }
        savedOrDiscarded = true
        dismiss()
    }

    /// The title if present, otherwise the first ~5 words of the body.
    private func firstWords(title: String, body: String) -> String {
        if !title.isEmpty { return title }
        let words = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return words.prefix(5).joined(separator: " ")
    }
}

/// A wrapping row of removable tag chips.
private struct TagChips: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        // A simple flow using a wrapping layout; small tag counts keep this cheap.
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    onRemove(tag)
                } label: {
                    HStack(spacing: 4) {
                        Text("#\(tag)")
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.tint.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
    }
}

/// Minimal wrapping layout so chips flow onto new lines instead of clipping.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rows.append(0)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
