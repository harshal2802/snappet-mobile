import Foundation

// The PURE analysis behind "clean up what's already in the wrong fields" (wardrobe prompt 05).
// It PROPOSES; it never mutates. The store applies the edits and records them for undo.
//
// Written against the measured closet, not a hypothetical one: `material` was being used as a
// brand field (Uniqlo 32, Lululemon 30, Temu 10, Amazon 5), 41 of 95 values carried stray
// whitespace, and size was typed into 10 item names ("Black tank top size M").
//
// The load-bearing judgement here is what it REFUSES to decide. Six of the real values —
// "Subtronics “BE NICE PLEASE”", "One piece zoro", "Illenium", "Lollapalooza",
// "Insomniac camp edc", "Hello kitty" — are festival/anime PRINTS, not brands. Brand-vs-print is
// not machine-decidable, so those go to an `uncertain` bucket the user resolves, rather than being
// quietly written into the brand field where they'd pollute the vocabulary forever.

enum WardrobeTidyPlan {

    /// Which property an edit rewrites.
    enum Field: String, Equatable, Sendable {
        case brand, sizeLabel, material, name
    }

    /// One proposed change to one item.
    struct Edit: Equatable, Identifiable, Sendable {
        var itemID: UUID
        var field: Field
        var oldValue: String
        var newValue: String

        var id: String { "\(itemID.uuidString)#\(field.rawValue)" }
    }

    /// A value the analysis will not classify on its own.
    struct Uncertain: Equatable, Identifiable, Sendable {
        var value: String
        var itemIDs: [UUID]
        /// What it would be if accepted as a brand — offered, never applied.
        var suggestion: Field

        var id: String { value.lowercased() }
    }

    /// What the review screen renders.
    struct Plan: Equatable, Sendable {
        var edits: [Edit] = []
        var uncertain: [Uncertain] = []
        /// Distinct brand values the confident edits would create, with their item counts.
        var brandGroups: [(value: String, count: Int)] = []
        var sizeCount: Int = 0

        var isEmpty: Bool { edits.isEmpty && uncertain.isEmpty }
        var changeCount: Int { edits.count }

        static func == (a: Plan, b: Plan) -> Bool {
            a.edits == b.edits && a.uncertain == b.uncertain && a.sizeCount == b.sizeCount
                && a.brandGroups.map(\.value) == b.brandGroups.map(\.value)
                && a.brandGroups.map(\.count) == b.brandGroups.map(\.count)
        }
    }

    /// The minimum an item must expose for analysis — keeps this file free of SwiftData.
    struct Row: Equatable, Sendable {
        var id: UUID
        var name: String
        var material: String
        var brand: String
        var sizeLabel: String

        init(id: UUID, name: String, material: String, brand: String = "", sizeLabel: String = "") {
            self.id = id
            self.name = name
            self.material = material
            self.brand = brand
            self.sizeLabel = sizeLabel
        }
    }

    /// Values that read as a retailer/label rather than a print. Deliberately a **known-brands
    /// allow-list plus a fabric check**, not a cleverness heuristic: the cost of a wrong guess here
    /// is a permanently polluted brand vocabulary, and the user is right there to ask.
    private static let knownBrands: Set<String> = [
        "uniqlo", "lululemon", "temu", "amazon", "zara", "nike", "adidas", "h&m", "gap",
        "levi's", "levis", "patagonia", "north face", "the north face", "columbia", "decathlon",
        "kalenji", "quechua", "wei-tex", "google", "apple", "shein", "primark", "muji",
        "hot topic", "urban outfitters", "asos", "lands' end", "landsend",
        "old navy", "target", "walmart", "costco", "reebok", "puma", "under armour", "asics",
        "new balance", "vans", "converse", "carhartt", "dickies", "arc'teryx", "arcteryx",
    ]

    /// Words that mean the value really is a fabric and should stay in `material`.
    private static let fabricWords: Set<String> = [
        "cotton", "wool", "linen", "silk", "polyester", "nylon", "denim", "leather", "cashmere",
        "fleece", "merino", "rayon", "viscose", "spandex", "elastane", "acrylic", "suede",
    ]

    /// Analyze a closet and propose moves. Pure: same input, same plan, no side effects.
    static func make(rows: [Row]) -> Plan {
        var plan = Plan()
        var brandCounts: [String: Int] = [:]
        var brandDisplay: [String: String] = [:]
        var brandOrder: [String] = []
        var uncertainMap: [String: Uncertain] = [:]
        var uncertainOrder: [String] = []

        for row in rows {
            // 1. material → brand, when the item has no brand yet and the value isn't a fabric.
            let material = WardrobeVocabularyRules.normalize(row.material)
            if !material.isEmpty, row.brand.isEmpty {
                let key = material.lowercased()
                if knownBrands.contains(key) {
                    plan.edits.append(Edit(itemID: row.id, field: .brand,
                                           oldValue: row.material, newValue: material))
                    plan.edits.append(Edit(itemID: row.id, field: .material,
                                           oldValue: row.material, newValue: ""))
                    if brandCounts[key] == nil { brandOrder.append(key); brandDisplay[key] = material }
                    brandCounts[key, default: 0] += 1
                } else if !isFabric(key) {
                    // Neither a known brand nor a fabric — a print, a one-off retailer, or noise.
                    if uncertainMap[key] == nil {
                        uncertainOrder.append(key)
                        uncertainMap[key] = Uncertain(value: material, itemIDs: [], suggestion: .brand)
                    }
                    uncertainMap[key]?.itemIDs.append(row.id)
                }
                // A fabric stays put: no edit, no question.
            }

            // 2. size out of the name.
            if row.sizeLabel.isEmpty, let found = sizeInName(row.name) {
                plan.edits.append(Edit(itemID: row.id, field: .sizeLabel,
                                       oldValue: "", newValue: found.size))
                plan.edits.append(Edit(itemID: row.id, field: .name,
                                       oldValue: row.name, newValue: found.cleanedName))
                plan.sizeCount += 1
            }
        }

        plan.brandGroups = brandOrder
            .map { (brandDisplay[$0] ?? $0, brandCounts[$0] ?? 0) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        plan.uncertain = uncertainOrder.compactMap { uncertainMap[$0] }
        return plan
    }

    private static func isFabric(_ lowercased: String) -> Bool {
        fabricWords.contains(where: lowercased.contains)
    }

    /// Pull a trailing "size X" out of a name. Conservative on purpose — it only fires on the
    /// literal word "size" followed by a short token, which is exactly the shape the real closet
    /// uses ("Black tank top size M"). It will not try to read "M" out of "Medium wash jeans".
    static func sizeInName(_ name: String) -> (size: String, cleanedName: String)? {
        let lower = name.lowercased()
        guard let range = lower.range(of: "size ") else { return nil }
        let after = name[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let token = after.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !token.isEmpty, token.count <= 6 else { return nil }
        var cleaned = String(name[..<range.lowerBound])
        // Keep anything that followed the size token (rare, but don't silently delete it).
        let tail = after.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { cleaned += " " + tail }
        cleaned = WardrobeVocabularyRules.normalize(cleaned)
        guard !cleaned.isEmpty else { return nil }   // never leave an item nameless
        return (token.uppercased(), cleaned)
    }
}
