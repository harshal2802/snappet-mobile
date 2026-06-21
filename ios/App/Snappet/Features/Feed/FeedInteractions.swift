import SwiftUI
import SwiftData

// MARK: - Recap Feed — reactions / saves (F2)
//
// Double-tap a card → toggle a private FeedReaction; long-press → toggle a FeedSaveItem. Both are
// append-only F0b rows keyed by the activity's contentId; framed as private memory/curation
// (actorRef="self", visibility stays private) — NOT a social like.

enum FeedInteractionWriter {

    @discardableResult
    static func toggleReaction(contentId: String, in context: ModelContext) -> Bool {
        guard !contentId.isEmpty else { return false }
        let existing = (try? context.fetch(FetchDescriptor<FeedReaction>(
            predicate: #Predicate { $0.activityContentId == contentId }))) ?? []
        if let first = existing.first {
            existing.forEach(context.delete)
            try? context.save()
            _ = first
            return false
        }
        context.insert(FeedReaction(activityContentId: contentId, typeRaw: "emoji", value: "❤️"))
        try? context.save()
        return true
    }

    @discardableResult
    static func toggleSave(contentId: String, collectionId: String = "saved", in context: ModelContext) -> Bool {
        guard !contentId.isEmpty else { return false }
        let existing = (try? context.fetch(FetchDescriptor<FeedSaveItem>(
            predicate: #Predicate { $0.activityContentId == contentId }))) ?? []
        if !existing.isEmpty {
            existing.forEach(context.delete)
            try? context.save()
            return false
        }
        context.insert(FeedSaveItem(activityContentId: contentId, collectionId: collectionId))
        try? context.save()
        return true
    }

    static func isReacted(contentId: String, in context: ModelContext) -> Bool {
        guard !contentId.isEmpty else { return false }
        let rows = (try? context.fetch(FetchDescriptor<FeedReaction>(
            predicate: #Predicate { $0.activityContentId == contentId }))) ?? []
        return !rows.isEmpty
    }

    static func isSaved(contentId: String, in context: ModelContext) -> Bool {
        guard !contentId.isEmpty else { return false }
        let rows = (try? context.fetch(FetchDescriptor<FeedSaveItem>(
            predicate: #Predicate { $0.activityContentId == contentId }))) ?? []
        return !rows.isEmpty
    }
}

/// The visible reactions strip (card footer + detail). Private memory/curation, not social likes.
struct FeedReactionStrip: View {
    let contentId: String
    @Environment(\.modelContext) private var context
    @State private var reacted = false
    @State private var saved = false

    var body: some View {
        HStack(spacing: 18) {
            Button {
                reacted = FeedInteractionWriter.toggleReaction(contentId: contentId, in: context)
            } label: {
                Label("React", systemImage: reacted ? "heart.fill" : "heart")
                    .foregroundStyle(reacted ? SnappetColor.brand : SnappetColor.textSecondary)
            }
            .accessibilityIdentifier("feed.react")
            Button {
                saved = FeedInteractionWriter.toggleSave(contentId: contentId, in: context)
            } label: {
                Label("Save", systemImage: saved ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(saved ? SnappetColor.kilter : SnappetColor.textSecondary)
            }
            .accessibilityIdentifier("feed.save")
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.plain)
        .task {
            reacted = FeedInteractionWriter.isReacted(contentId: contentId, in: context)
            saved = FeedInteractionWriter.isSaved(contentId: contentId, in: context)
        }
    }
}
