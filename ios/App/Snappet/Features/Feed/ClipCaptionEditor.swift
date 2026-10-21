import SwiftUI

/// ✎ Caption (prompt 196, wireframe screen 4): write what it felt like, add suggested #tags from what you logged,
/// and choose what the post shows (stats line · set chips · heart-rate tile).
struct ClipCaptionEditor: View {
    let post: ClipFeedPost
    let initial: ClipCaption
    let onSave: (ClipCaption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClipCaption
    @FocusState private var focused: Bool

    init(post: ClipFeedPost, initial: ClipCaption, onSave: @escaping (ClipCaption) -> Void) {
        self.post = post
        self.initial = initial
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    private var suggestions: [String] { ClipCaption.suggestions(post: post, text: draft.text) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Caption") {
                    TextField("What did it feel like?", text: $draft.text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                        .accessibilityIdentifier("clips.caption.field")
                }
                if !suggestions.isEmpty {
                    Section("Suggested tags") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestions, id: \.self) { tag in
                                    Button { add(tag) } label: {
                                        Text("#\(tag)").font(.caption.weight(.bold))
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(SnappetColor.budget.opacity(0.14), in: Capsule())
                                            .foregroundStyle(SnappetColor.budget)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("clips.caption.tag.\(tag)")
                                }
                            }
                        }
                    }
                }
                Section("On the post") {
                    if let stats = post.stats {
                        Toggle("Stats line (\(stats.line))", isOn: $draft.showStats)
                            .accessibilityIdentifier("clips.caption.showStats")
                    }
                    Toggle("Set chips", isOn: $draft.showSets).accessibilityIdentifier("clips.caption.showSets")
                    Toggle("Heart-rate tile", isOn: $draft.showHR).accessibilityIdentifier("clips.caption.showHR")
                }
            }
            .navigationTitle("Caption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }.accessibilityIdentifier("clips.caption.save")
                }
            }
            .onAppear { if initial.text.isEmpty { focused = true } }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(_ tag: String) {
        let sep = draft.text.isEmpty || draft.text.hasSuffix(" ") ? "" : " "
        draft.text += "\(sep)#\(tag)"
    }
}
