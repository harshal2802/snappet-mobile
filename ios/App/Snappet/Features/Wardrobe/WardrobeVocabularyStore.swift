import SwiftData
import Foundation

// SwiftData side of the open dropdowns (wardrobe prompt 05). All decisions live in the pure
// `WardrobeVocabularyRules`; this only reads, writes and counts.

@MainActor
enum WardrobeVocabularyStore {

    private static func all(_ field: WardrobeVocabularyRules.Field,
                            in context: ModelContext) -> [WardrobeVocabulary] {
        let raw = field.rawValue
        let rows = (try? context.fetch(
            FetchDescriptor<WardrobeVocabulary>(
                predicate: #Predicate { $0.fieldRaw == raw }))) ?? []
        return rows
    }

    /// The rows a picker renders: remembered values (most used first) then unused built-ins.
    static func choices(for field: WardrobeVocabularyRules.Field,
                        in context: ModelContext) -> [WardrobeVocabularyRules.Choice] {
        WardrobeVocabularyRules.choices(
            field: field,
            remembered: all(field, in: context).map { ($0.value, $0.mapsToRaw, $0.useCount) },
            builtInTitles: builtInTitles(for: field))
    }

    /// Built-in raw → display title for a field. Kept here so the pure rules stay enum-agnostic.
    static func builtInTitles(
        for field: WardrobeVocabularyRules.Field) -> [(raw: String, title: String)] {
        switch field {
        case .category: return GarmentCategory.allCases.map { ($0.rawValue, $0.title) }
        case .color: return GarmentColorFamily.allCases.map { ($0.rawValue, $0.title) }
        case .pattern: return GarmentPattern.allCases.map { ($0.rawValue, $0.title) }
        case .style: return GarmentStyle.allCases.map { ($0.rawValue, $0.title) }
        case .brand, .size, .material: return []
        }
    }

    /// Remember a value, or bump its count if it's already known.
    ///
    /// Matching is `isSameValue`, so `'Uniqlo '` finds the existing `Uniqlo` and increments it
    /// instead of creating the duplicate the real closet is full of.
    @discardableResult
    static func remember(_ rawValue: String, field: WardrobeVocabularyRules.Field,
                         mapsToRaw: String = "", in context: ModelContext) -> WardrobeVocabulary? {
        let clean = WardrobeVocabularyRules.normalize(rawValue)
        guard !clean.isEmpty else { return nil }
        if let existing = all(field, in: context)
            .first(where: { WardrobeVocabularyRules.isSameValue($0.value, clean) }) {
            existing.useCount += 1
            // Backfill a mapping if this is the first time one was supplied.
            if existing.mapsToRaw.isEmpty, !mapsToRaw.isEmpty { existing.mapsToRaw = mapsToRaw }
            try? context.save()
            return existing
        }
        let row = WardrobeVocabulary(field: field, value: clean, mapsToRaw: mapsToRaw)
        context.insert(row)
        try? context.save()
        return row
    }

    /// Seed the vocabulary from values already in the closet, so the dropdowns aren't empty on
    /// first open. Idempotent — `remember` folds duplicates, and seeding twice only bumps counts,
    /// so this is gated by the caller to a single run.
    static func seedFromExistingItems(_ items: [WardrobeItem], in context: ModelContext) {
        for (value, count) in WardrobeVocabularyRules.fold(items.map(\.brand)) {
            if let row = remember(value, field: .brand, in: context) { row.useCount = count }
        }
        for (value, count) in WardrobeVocabularyRules.fold(items.map(\.sizeLabel)) {
            if let row = remember(value, field: .size, in: context) { row.useCount = count }
        }
        for (value, count) in WardrobeVocabularyRules.fold(items.map(\.material)) {
            if let row = remember(value, field: .material, in: context) { row.useCount = count }
        }
        try? context.save()
    }

    /// Existing values for duplicate-checking in the add-new form.
    static func existingValues(for field: WardrobeVocabularyRules.Field,
                               in context: ModelContext) -> [String] {
        all(field, in: context).map(\.value)
            + builtInTitles(for: field).map(\.title)
    }
}
