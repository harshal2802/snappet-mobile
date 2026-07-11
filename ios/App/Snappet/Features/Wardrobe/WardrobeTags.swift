import Foundation

// The Wardrobe tag vocabulary — the PURE core of the mini-app (wardrobe prompt 01).
// Every AI/vision output is mapped into these closed enums so the composer, the coach,
// and the stats all reason over one small, testable domain. No platform imports here:
// the Vision/FoundationModels edges live in `Services/` and call into these mappings.

/// What a piece of clothing *is* — drives outfit slots, grid sections, and placeholders.
enum GarmentCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case top, bottom, dress, outerwear, shoes, accessory, headwear, bag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .dress: return "Dress"
        case .outerwear: return "Outerwear"
        case .shoes: return "Shoes"
        case .accessory: return "Accessory"
        case .headwear: return "Headwear"
        case .bag: return "Bag"
        }
    }

    var pluralTitle: String {
        switch self {
        case .top: return "Tops"
        case .bottom: return "Bottoms"
        case .dress: return "Dresses"
        case .outerwear: return "Outerwear"
        case .shoes: return "Shoes"
        case .accessory: return "Accessories"
        case .headwear: return "Headwear"
        case .bag: return "Bags"
        }
    }

    /// Placeholder glyph for items with no photo (sample closet, failed capture).
    var emoji: String {
        switch self {
        case .top: return "👕"
        case .bottom: return "👖"
        case .dress: return "👗"
        case .outerwear: return "🧥"
        case .shoes: return "👟"
        case .accessory: return "🧣"
        case .headwear: return "🧢"
        case .bag: return "👜"
        }
    }

    /// Map a Vision classification label (e.g. "jersey", "running shoe") to a category.
    /// Substring match over a curated keyword table; first hit wins in table order so the
    /// more specific garment words (jacket/coat) are checked before generic ones (shirt).
    static func fromVisionLabel(_ label: String) -> GarmentCategory? {
        let l = label.lowercased()
        let table: [(GarmentCategory, [String])] = [
            (.outerwear, ["jacket", "coat", "parka", "blazer", "windbreaker", "raincoat", "poncho", "vest"]),
            (.dress,     ["dress", "gown", "frock", "kimono", "sarong"]),
            (.shoes,     ["shoe", "sneaker", "loafer", "boot", "sandal", "heel", "trainer", "cleat", "clog", "running shoe"]),
            (.headwear,  ["hat", "cap", "beanie", "fedora", "sombrero", "bonnet"]),
            (.bag,       ["backpack", "handbag", "purse", "tote", "satchel", "bag"]),
            (.accessory, ["scarf", "necktie", "tie", "belt", "glove", "mitten", "sock", "sunglass", "watch", "necklace", "bow tie", "stole"]),
            (.bottom,    ["jean", "trouser", "pant", "chino", "short", "skirt", "legging", "jogger", "sweatpant", "miniskirt", "overskirt"]),
            (.top,       ["jersey", "t-shirt", "tee", "sweatshirt", "hoodie", "shirt", "blouse", "sweater", "cardigan", "polo", "tank", "singlet", "pajama"]),
        ]
        for (category, keywords) in table where keywords.contains(where: { l.contains($0) }) {
            return category
        }
        return nil
    }
}

/// A curated color family — coarse on purpose: harmony rules over ~16 families are
/// explainable; raw RGB triples are not.
enum GarmentColorFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    case black, white, grey, cream, brown, tan, navy, blue, denim
    case green, olive, red, burgundy, pink, purple, yellow, orange

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Neutrals pair with everything — the backbone of the harmony score.
    var isNeutral: Bool {
        switch self {
        case .black, .white, .grey, .cream, .brown, .tan, .navy, .denim: return true
        default: return false
        }
    }

    /// Approximate hue (degrees) for the non-neutral families, for adjacency/complement checks.
    var hueDegrees: Double? {
        switch self {
        case .red: return 0
        case .orange: return 30
        case .yellow: return 55
        case .olive: return 75
        case .green: return 120
        case .blue: return 220
        case .purple: return 275
        case .pink: return 330
        case .burgundy: return 345
        default: return nil
        }
    }

    /// How well two families sit together, 0…1. Neutral ↔ anything is a safe 1.0;
    /// same family reads monochrome (good); adjacent hues blend; complements pop;
    /// everything else is a clash the composer avoids when it has a choice.
    static func harmony(_ a: GarmentColorFamily, _ b: GarmentColorFamily) -> Double {
        if a.isNeutral || b.isNeutral { return 1.0 }
        if a == b { return 0.85 }
        guard let ha = a.hueDegrees, let hb = b.hueDegrees else { return 1.0 }
        var d = abs(ha - hb).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        if d <= 40 { return 0.8 }          // analogous
        if abs(d - 180) <= 30 { return 0.7 } // complementary
        return 0.25                          // clash
    }

    /// Map an average RGB (0…1 components) to the nearest family — the pure half of the
    /// dominant-color pipeline (the pixel averaging lives in `WardrobeVision`).
    static func fromRGB(red: Double, green: Double, blue: Double) -> GarmentColorFamily {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let brightness = maxC
        let delta = maxC - minC
        let saturation = maxC == 0 ? 0 : delta / maxC

        // Near-black first: at very low brightness a slight tint inflates saturation
        // (delta/max), so the saturation gate alone would misread black as navy.
        if brightness < 0.16 { return .black }
        // Low saturation → the achromatic ladder.
        if saturation < 0.14 {
            if brightness < 0.45 { return .grey }
            if brightness < 0.8 { return .grey }
            // warm-tinted near-white reads cream
            return (red > blue + 0.03) ? .cream : .white
        }

        var hue: Double = 0
        if maxC == red { hue = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6)) }
        else if maxC == green { hue = 60 * (((blue - red) / delta) + 2) }
        else { hue = 60 * (((red - green) / delta) + 4) }
        if hue < 0 { hue += 360 }

        switch hue {
        case ..<15, 345...: return brightness < 0.45 ? .burgundy : .red
        case ..<45: return brightness < 0.55 ? .brown : (saturation < 0.45 ? .tan : .orange)
        case ..<70: return brightness < 0.5 ? .olive : .yellow
        case ..<160: return saturation < 0.35 && brightness < 0.6 ? .olive : .green
        case ..<255:
            if brightness < 0.3 { return .navy }
            return saturation < 0.5 ? .denim : .blue
        case ..<300: return .purple
        default: return .pink
        }
    }
}

/// Surface pattern. `solid` is the safe default; the rest come from the optional AI pass.
enum GarmentPattern: String, CaseIterable, Codable, Sendable, Identifiable {
    case solid, plaid, striped, floral, graphic, dotted, textured
    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Style genre → a formality scalar the composer can compare against an occasion.
enum GarmentStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case lounge, athletic, casual, smartCasual, business, formal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lounge: return "Lounge"
        case .athletic: return "Athletic"
        case .casual: return "Casual"
        case .smartCasual: return "Smart casual"
        case .business: return "Business"
        case .formal: return "Formal"
        }
    }

    /// 0 (couch) … 5 (black tie). The single axis occasions are matched on.
    var formality: Int {
        switch self {
        case .lounge: return 0
        case .athletic: return 1
        case .casual: return 2
        case .smartCasual: return 3
        case .business: return 4
        case .formal: return 5
        }
    }

    /// Infer a style from garment words (Vision labels or a user-typed name/material).
    static func inferred(from text: String) -> GarmentStyle {
        let l = text.lowercased()
        if l.contains("blazer") || l.contains("suit") { return .business }
        if ["oxford", "dress shirt", "slack", "loafer", "chino"].contains(where: l.contains) { return .smartCasual }
        if ["gown", "tuxedo", "heel"].contains(where: l.contains) { return .formal }
        if ["jogger", "legging", "running", "athletic", "jersey", "sweatpant", "gym", "trainer", "track"].contains(where: l.contains) { return .athletic }
        if ["pajama", "robe", "slipper", "fleece"].contains(where: l.contains) { return .lounge }
        return .casual
    }
}

/// Wearing season. An empty season set on an item means "all-season".
enum GarmentSeason: String, CaseIterable, Codable, Sendable, Identifiable {
    case spring, summer, fall, winter
    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Northern-hemisphere month default — the v1 weather stand-in (decisions.md: WeatherKit
    /// is a follow-up; the composer only needs a season + temp band, both user-adjustable).
    static func forMonth(_ month: Int) -> GarmentSeason {
        switch month {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .fall
        default: return .winter
        }
    }
}

/// Coarse temperature band — all the composer needs from "weather".
enum TempBand: String, CaseIterable, Codable, Sendable, Identifiable {
    case cold, cool, mild, warm, hot

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cold: return "Cold"
        case .cool: return "Cool"
        case .mild: return "Mild"
        case .warm: return "Warm"
        case .hot: return "Hot"
        }
    }

    var emoji: String {
        switch self {
        case .cold: return "❄️"
        case .cool: return "🌥️"
        case .mild: return "⛅️"
        case .warm: return "☀️"
        case .hot: return "🔥"
        }
    }

    /// Below this line the composer adds an outer layer.
    var needsOuterLayer: Bool { self == .cold || self == .cool }

    /// Seasonal default band (pairs with `GarmentSeason.forMonth`).
    static func forSeason(_ season: GarmentSeason) -> TempBand {
        switch season {
        case .spring: return .mild
        case .summer: return .hot
        case .fall: return .cool
        case .winter: return .cold
        }
    }
}

/// What the outfit is for. Maps to a target formality window.
enum OutfitOccasion: String, CaseIterable, Codable, Sendable, Identifiable {
    case work, dateNight, wedding, vacation, casualWeekend

    var id: String { rawValue }
    var title: String {
        switch self {
        case .work: return "Work"
        case .dateNight: return "Date night"
        case .wedding: return "Wedding"
        case .vacation: return "Vacation"
        case .casualWeekend: return "Casual weekend"
        }
    }

    /// Acceptable formality window (inclusive). Items outside pay a steep score penalty.
    var formalityRange: ClosedRange<Int> {
        switch self {
        case .work: return 3...4
        case .dateNight: return 2...4
        case .wedding: return 4...5
        case .vacation: return 1...3
        case .casualWeekend: return 1...3
        }
    }

    /// Free-text nudges: a phrase like "client meeting" pushes the window up one notch,
    /// "beach" pulls it down. Tiny on purpose — the AI pass can refine, this always works.
    func adjusted(for note: String) -> ClosedRange<Int> {
        let l = note.lowercased()
        let up = ["client", "meeting", "interview", "presentation", "dinner", "rooftop"].contains(where: l.contains)
        let down = ["beach", "hike", "picnic", "errand", "lounge", "park"].contains(where: l.contains)
        var lo = formalityRange.lowerBound, hi = formalityRange.upperBound
        if up { lo = min(5, lo + 1); hi = min(5, hi + 1) }
        if down { lo = max(0, lo - 1); hi = max(0, hi - 1) }
        return lo...max(lo, hi)
    }
}
