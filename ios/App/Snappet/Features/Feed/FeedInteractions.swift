import SwiftUI
import SwiftData

// MARK: - Recap Feed — reactions / saves (F2)
//
// Double-tap a card → toggle a private FeedReaction; long-press → toggle a FeedSaveItem. Both are
// append-only F0b rows keyed by the activity's contentId; framed as private memory/curation
// (actorRef="self", visibility stays private) — NOT a social like.

enum FeedInteractionWriter {

    /// All rows of `M` for one activity. Generic `FetchDescriptor` (no predicate) + in-memory filter —
    /// mirrors `SnappetBackup`'s `all<M: PersistentModel>` and sidesteps the non-translatable
    /// generic-`#Predicate` problem. Row counts here are tiny (append-only), so the scan is free.
    private static func rows<M: ActivityScoped>(
        _ type: M.Type, contentId: String, in context: ModelContext
    ) -> [M] {
        guard !contentId.isEmpty, let all = try? context.fetch(FetchDescriptor<M>()) else { return [] }
        return all.filter { $0.activityContentId == contentId }
    }

    /// Toggle: delete all matching rows if present, else insert `make()`. Returns the new on-state.
    @discardableResult
    private static func toggle<M: ActivityScoped>(
        _ type: M.Type, contentId: String, in context: ModelContext, make: () -> M
    ) -> Bool {
        guard !contentId.isEmpty else { return false }
        let existing = rows(type, contentId: contentId, in: context)
        if !existing.isEmpty {
            existing.forEach(context.delete)
            try? context.save()
            return false
        }
        context.insert(make())
        try? context.save()
        return true
    }

    @discardableResult
    static func toggleReaction(contentId: String, in context: ModelContext) -> Bool {
        toggle(FeedReaction.self, contentId: contentId, in: context) {
            FeedReaction(activityContentId: contentId, typeRaw: "emoji", value: "❤️")
        }
    }

    @discardableResult
    static func toggleSave(contentId: String, collectionId: String = "saved", in context: ModelContext) -> Bool {
        toggle(FeedSaveItem.self, contentId: contentId, in: context) {
            FeedSaveItem(activityContentId: contentId, collectionId: collectionId)
        }
    }

    // Membership probes. The feed strips read batched @Query membership (not these) on the hot path;
    // these remain the writer's queryable API for tests and one-off callers.
    static func isReacted(contentId: String, in context: ModelContext) -> Bool {
        !rows(FeedReaction.self, contentId: contentId, in: context).isEmpty
    }

    static func isSaved(contentId: String, in context: ModelContext) -> Bool {
        !rows(FeedSaveItem.self, contentId: contentId, in: context).isEmpty
    }
}

/// The visible reactions strip (card footer + detail). Private memory/curation, not social likes.
///
/// Membership (`reacted`/`saved`) is passed in from the host's hoisted @Query of FeedReaction/
/// FeedSaveItem (one query each, not 2 FetchDescriptors per card). The toggle writers mutate those
/// @Model tables, so the host @Query auto-refreshes and re-renders this strip with the new membership
/// on the next run-loop tick — no local @State mirror needed (it would only desync from the card-body
/// double-tap/long-press gestures, which also call the writers).
struct FeedReactionStrip: View {
    let contentId: String
    let reacted: Bool
    let saved: Bool
    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(spacing: 18) {
            Button {
                FeedInteractionWriter.toggleReaction(contentId: contentId, in: context)
            } label: {
                Label("React", systemImage: reacted ? "heart.fill" : "heart")
                    .foregroundStyle(reacted ? SnappetColor.brand : SnappetColor.textSecondary)
            }
            .accessibilityIdentifier("feed.react")
            Button {
                FeedInteractionWriter.toggleSave(contentId: contentId, in: context)
            } label: {
                Label("Save", systemImage: saved ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(saved ? SnappetColor.kilter : SnappetColor.textSecondary)
            }
            .accessibilityIdentifier("feed.save")
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.plain)
    }
}
