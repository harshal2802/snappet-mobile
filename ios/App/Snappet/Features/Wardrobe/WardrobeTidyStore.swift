import SwiftData
import Foundation

// Applying (and un-applying) the cleanup proposal (wardrobe prompt 05).
//
// The plan itself is pure and inert; this is the only code that writes. Every rewrite is recorded
// as a `WardrobeTidyEdit` under one `batchID` **before** the item is touched, so "Undo tidy up" is
// a replay of `oldValue`s rather than a guess. That matters because this runs over a real 100-item
// closet and rewrites ~105 values in one tap.

@MainActor
enum WardrobeTidyStore {

    /// Build the proposal from the live closet.
    static func plan(in context: ModelContext) -> WardrobeTidyPlan.Plan {
        let items = (try? context.fetch(FetchDescriptor<WardrobeItem>())) ?? []
        return WardrobeTidyPlan.make(rows: items.map {
            WardrobeTidyPlan.Row(id: $0.id, name: $0.name, material: $0.material,
                                 brand: $0.brand, sizeLabel: $0.sizeLabel)
        })
    }

    /// Apply `edits`, recording each one. Returns the batch id so the caller can offer an undo.
    ///
    /// `extra` carries the user's answers for the uncertain values (value → field), which is how a
    /// print ends up in `material` and a real brand in `brand` without the plan having guessed.
    @discardableResult
    static func apply(_ edits: [WardrobeTidyPlan.Edit], in context: ModelContext) -> UUID {
        let batchID = UUID()
        let items = (try? context.fetch(FetchDescriptor<WardrobeItem>())) ?? []
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        for edit in edits {
            guard let item = byID[edit.itemID] else { continue }
            let old = currentValue(of: item, field: edit.field)
            // Record FIRST: a crash between the write and the record would leave an edit that
            // undo can't reverse.
            context.insert(WardrobeTidyEdit(batchID: batchID, itemID: item.id,
                                            fieldRaw: edit.field.rawValue,
                                            oldValue: old, newValue: edit.newValue))
            setValue(edit.newValue, of: item, field: edit.field)
        }
        try? context.save()

        // The brands the cleanup just created should populate the dropdown immediately.
        for item in items where !item.brand.isEmpty {
            WardrobeVocabularyStore.remember(item.brand, field: .brand, in: context)
        }
        for item in items where !item.sizeLabel.isEmpty {
            WardrobeVocabularyStore.remember(item.sizeLabel, field: .size, in: context)
        }
        return batchID
    }

    /// The most recent batch that hasn't been undone — what "Undo tidy up" would reverse.
    static func undoableBatch(in context: ModelContext) -> (id: UUID, count: Int, at: Date)? {
        let edits = ((try? context.fetch(FetchDescriptor<WardrobeTidyEdit>())) ?? [])
            .filter { !$0.isUndone }
        guard let latest = edits.max(by: { $0.appliedAt < $1.appliedAt }) else { return nil }
        let batch = edits.filter { $0.batchID == latest.batchID }
        return (latest.batchID, batch.count, latest.appliedAt)
    }

    /// Restore every `oldValue` in a batch and mark it undone.
    ///
    /// The rows are **kept, not deleted** — the history of what was done (and reversed) survives,
    /// and a second undo of the same batch becomes a no-op rather than re-applying anything.
    static func undo(batchID: UUID, in context: ModelContext) {
        let edits = ((try? context.fetch(FetchDescriptor<WardrobeTidyEdit>())) ?? [])
            .filter { $0.batchID == batchID && !$0.isUndone }
        guard !edits.isEmpty else { return }
        let items = (try? context.fetch(FetchDescriptor<WardrobeItem>())) ?? []
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        // Reverse order, so several edits to one field unwind to the earliest value.
        for edit in edits.sorted(by: { $0.appliedAt > $1.appliedAt }) {
            guard let itemID = edit.itemID, let item = byID[itemID],
                  let field = WardrobeTidyPlan.Field(rawValue: edit.fieldRaw) else { continue }
            setValue(edit.oldValue, of: item, field: field)
            edit.isUndone = true
        }
        try? context.save()
    }

    // MARK: - Field access

    private static func currentValue(of item: WardrobeItem,
                                     field: WardrobeTidyPlan.Field) -> String {
        switch field {
        case .brand: return item.brand
        case .sizeLabel: return item.sizeLabel
        case .material: return item.material
        case .name: return item.name
        }
    }

    private static func setValue(_ value: String, of item: WardrobeItem,
                                 field: WardrobeTidyPlan.Field) {
        switch field {
        case .brand: item.brand = value
        case .sizeLabel: item.sizeLabel = value
        case .material: item.material = value
        case .name: item.name = value
        }
    }
}
